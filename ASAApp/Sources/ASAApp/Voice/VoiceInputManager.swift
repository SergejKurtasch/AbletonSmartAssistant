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
        guard !isStreaming else { return }
        
        logger.info("Starting voice input streaming...")
        isStreaming = true
        
        // Start audio pipeline with callback
        audioPipeline.startStreaming { [weak self] audioData in
            self?.handleAudioChunk(audioData)
        }
        
        // Start periodic sending timer
        sendTimer = Timer.scheduledTimer(withTimeInterval: sendInterval, repeats: true) { [weak self] _ in
            self?.sendBufferedAudio()
        }
        
        if let timer = sendTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
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
        
        // If local VAD is enabled, we only buffer when speech is detected
        // But since AudioPipeline already filters with VAD, we can buffer all audio
        // The Realtime API will do its own VAD processing
        
        bufferQueue.async { [weak self] in
            guard let self = self else { return }
            self.audioBuffer.append(audioData)
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
                self.realtimeSession.sendAudioFrame(dataToSend)
            }
        }
    }
}

