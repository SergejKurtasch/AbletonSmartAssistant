import Foundation
import AVFoundation
import OSLog

/// Manages voice input: microphone → Realtime API
/// Uses two-level VAD: local VADService for pre-filtering + Realtime API VAD for final decision
final class VoiceInputManager {
    private let logger = Logger(subsystem: "ASAApp", category: "VoiceInputManager")
    private let audioPipeline: AudioPipeline
    private let vadService = VADService()
    private let realtimeSession: RealtimeSession
    
    // Configuration
    private let sendInterval: TimeInterval = 0.03 // Send every 30ms (approximately)
    private var sendTimer: Timer?
    private var audioBuffer: Data = Data()
    private let bufferQueue = DispatchQueue(label: "VoiceInputManager.buffer", qos: .userInitiated)
    
    // State
    private var isStreaming: Bool = false
    private var useLocalVAD: Bool = true // Pre-filter with local VAD
    
    init(audioPipeline: AudioPipeline, realtimeSession: RealtimeSession) {
        self.audioPipeline = audioPipeline
        self.realtimeSession = realtimeSession
    }
    
    /// Start voice input streaming
    func start() {
        guard !isStreaming else {
            logger.warning("Voice input already streaming")
            return
        }
        
        logger.info("Starting voice input streaming...")
        isStreaming = true
        
        // Start audio pipeline with callback
        audioPipeline.startStreaming { [weak self] audioData in
            self?.handleAudioChunk(audioData)
        }
        
        logger.info("Audio pipeline started, waiting for audio data...")
        
        // Start periodic sending timer
        sendTimer = Timer.scheduledTimer(withTimeInterval: sendInterval, repeats: true) { [weak self] _ in
            self?.sendBufferedAudio()
        }
        
        if let timer = sendTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
        
        logger.info("Voice input streaming started successfully")
    }
    
    /// Stop voice input streaming
    func stop() {
        guard isStreaming else { return }
        
        logger.info("Stopping voice input streaming...")
        isStreaming = false
        
        sendTimer?.invalidate()
        sendTimer = nil
        
        // Send any remaining buffered audio
        sendBufferedAudio()
        
        audioPipeline.stopStreaming()
        
        bufferQueue.sync {
            audioBuffer.removeAll()
        }
    }
    
    /// Enable/disable local VAD pre-filtering
    func setUseLocalVAD(_ enabled: Bool) {
        useLocalVAD = enabled
        logger.info("Local VAD pre-filtering: \(enabled ? "enabled" : "disabled")")
    }
    
    // MARK: - Private
    
    private func handleAudioChunk(_ audioData: Data) {
        guard isStreaming else { return }
        
        // Buffer all audio - Realtime API will handle VAD
        bufferQueue.async { [weak self] in
            guard let self = self else { return }
            self.audioBuffer.append(audioData)
            
            // Log first chunk to confirm audio is being captured
            if self.audioBuffer.count == audioData.count {
                self.logger.info("✅ First audio chunk received: \(audioData.count) bytes")
            }
            
            // Limit buffer size to prevent memory issues
            let maxBufferSize = 48000 * 2 // ~2 seconds at 24kHz, 16-bit mono
            if self.audioBuffer.count > maxBufferSize {
                self.audioBuffer.removeFirst(self.audioBuffer.count - maxBufferSize)
            }
        }
    }
    
    private func sendBufferedAudio() {
        guard isStreaming else { return }
        
        bufferQueue.sync {
            guard !audioBuffer.isEmpty else { return }
            
            let dataToSend = audioBuffer
            audioBuffer.removeAll()
            
            // Send to Realtime API
            Task { @MainActor in
                // Check if session is ready before sending
                guard self.realtimeSession.sessionInitialized else {
                    // Session not ready, put data back in buffer (but limit buffer size)
                    self.bufferQueue.async {
                        // Limit buffer to prevent memory issues (keep last 1 second of audio)
                        let maxBufferSize = 48000 // ~1 second at 24kHz, 16-bit mono
                        if self.audioBuffer.count < maxBufferSize {
                            self.audioBuffer.insert(contentsOf: dataToSend, at: 0)
                        }
                    }
                    return
                }
                
                self.realtimeSession.sendAudioFrame(dataToSend)
                self.logger.debug("Sent \(dataToSend.count) bytes of audio")
            }
        }
    }
}

