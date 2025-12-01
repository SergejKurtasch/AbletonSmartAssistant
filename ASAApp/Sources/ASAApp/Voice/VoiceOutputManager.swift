import Foundation
import AVFoundation
import OSLog

/// Manages voice output: Realtime API → audio playback
/// Real-time playback without delays using AVAudioPlayerNode
final class VoiceOutputManager {
    private let logger = Logger(subsystem: "ASAApp", category: "VoiceOutputManager")
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioFormat: AVAudioFormat?
    private var isPlayerAttached = false
    private var isPlaying = false
    
    // Audio buffer for streaming
    private var audioBuffer: Data = Data()
    private let bufferQueue = DispatchQueue(label: "VoiceOutputManager.buffer", qos: .userInitiated)
    private var playbackTimer: Timer?
    
    init() {
        setupAudioEngine()
    }
    
    /// Start audio playback
    func start() {
        guard !isPlaying else { return }
        
        logger.info("Starting voice output...")
        
        // Ensure player is attached
        if !isPlayerAttached {
            attachPlayerNode()
        }
        
        // Start engine if not running
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                logger.error("Failed to start audio engine: \(error.localizedDescription)")
                return
            }
        }
        
        isPlaying = true
        
        // Start playback timer to process buffered audio
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            self?.processAudioBuffer()
        }
        
        if let timer = playbackTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    /// Stop audio playback
    func stop() {
        guard isPlaying else { return }
        
        logger.info("Stopping voice output...")
        isPlaying = false
        
        playbackTimer?.invalidate()
        playbackTimer = nil
        
        playerNode.stop()
        
        bufferQueue.sync {
            audioBuffer.removeAll()
        }
    }
    
    /// Add audio data to playback buffer
    func addAudioData(_ data: Data) {
        guard isPlaying else {
            logger.warning("Received audio data but playback is not active")
            return
        }
        
        logger.debug("Received \(data.count) bytes of audio for playback")
        
        bufferQueue.async { [weak self] in
            guard let self = self else { return }
            self.audioBuffer.append(data)
        }
    }
    
    // MARK: - Private
    
    private func setupAudioEngine() {
        // Create audio format for PCM16 (16-bit, mono, 24kHz - typical for Realtime API)
        // Realtime API uses PCM16, but we need to check the actual format
        // Default to 24kHz mono PCM16
        audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        )
    }
    
    private func attachPlayerNode() {
        guard let format = audioFormat else {
            logger.error("Audio format not set")
            return
        }
        
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
        isPlayerAttached = true
    }
    
    private func processAudioBuffer() {
        guard isPlaying, let format = audioFormat else { return }
        
        bufferQueue.sync {
            guard !audioBuffer.isEmpty else { return }
            
            // Take a chunk of audio (enough for ~20ms at 24kHz = 480 samples = 960 bytes for 16-bit)
            let chunkSize = 960 // ~20ms of audio
            let dataToPlay = audioBuffer.prefix(chunkSize)
            audioBuffer.removeFirst(min(chunkSize, audioBuffer.count))
            
            guard !dataToPlay.isEmpty else { return }
            
            // Convert Data to AVAudioPCMBuffer
            guard let buffer = createPCMBuffer(from: dataToPlay, format: format) else {
                logger.warning("Failed to create PCM buffer from audio data")
                return
            }
            
            // Schedule buffer for playback
            playerNode.scheduleBuffer(buffer) {
                // Buffer completed, continue processing
            }
            
            // Start playing if not already
            if !playerNode.isPlaying {
                playerNode.play()
                logger.debug("Started audio playback")
            }
        }
    }
    
    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(data.count / 2)) else {
            return nil
        }
        
        // Convert Int16 PCM data to Float32
        let int16Samples = data.withUnsafeBytes { Array(UnsafeBufferPointer<Int16>(start: $0.baseAddress?.assumingMemoryBound(to: Int16.self), count: data.count / 2)) }
        
        guard let channelData = buffer.floatChannelData?[0] else {
            return nil
        }
        
        buffer.frameLength = UInt32(int16Samples.count)
        
        for (index, sample) in int16Samples.enumerated() {
            // Convert Int16 (-32768 to 32767) to Float (-1.0 to 1.0)
            channelData[index] = Float(sample) / Float(Int16.max)
        }
        
        return buffer
    }
}

