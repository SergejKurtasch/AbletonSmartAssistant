import Foundation
import AVFoundation

final class AudioPipeline: NSObject {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let vadService = VADService()
    private var audioFileQueue: [URL] = []
    private var captureCallback: ((Data) -> Void)?
    private var audioSessionConfigured = false
    private var isPlayerAttached = false

    func startStreaming(callback: @escaping (Data) -> Void) {
        captureCallback = callback
        
        // On macOS, permissions are requested automatically when we try to access the microphone
        // Just configure and start - system will prompt if needed
        configureSessionIfNeeded()
        installTapIfNeeded()
        
        if !engine.isRunning {
            do {
                try engine.start()
                print("✅ Audio engine started successfully")
            } catch {
                print("❌ Failed to start audio engine: \(error.localizedDescription)")
                // If error is permission-related, macOS will show a dialog
                if let nsError = error as NSError? {
                    print("   Error domain: \(nsError.domain), code: \(nsError.code)")
                }
            }
        }
    }

    func stopStreaming() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        captureCallback = nil
    }

    func enqueuePlayback(_ url: URL?) {
        guard let url else { return }
        audioFileQueue.append(url)
        playNextIfNeeded()
    }

    private func playNextIfNeeded() {
        guard !playerNode.isPlaying else { return }
        guard let url = audioFileQueue.first else { return }

        do {
            let file = try AVAudioFile(forReading: url)
            if !isPlayerAttached {
                engine.attach(playerNode)
                engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
                isPlayerAttached = true
            }
            playerNode.scheduleFile(file, at: nil) { [weak self] in
                guard let self else { return }
                self.audioFileQueue.removeFirst()
                self.playNextIfNeeded()
            }
            if !engine.isRunning {
                try engine.start()
            }
            playerNode.play()
        } catch {
            print("Failed to play assistant audio: \(error)")
        }
    }

    private func configureSessionIfNeeded() {
        guard !audioSessionConfigured else { return }
        // macOS skips AVAudioSession, so mark the engine as configured directly
        // Simply flag it so we do not run the configuration twice
        audioSessionConfigured = true
    }

    private func installTapIfNeeded() {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        print("📊 Audio format: sampleRate=\(format.sampleRate), channels=\(format.channelCount)")
        
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            
            // For now, send all audio (VAD is handled by Realtime API)
            // This ensures we don't miss any speech
            if let data = buffer.toPCMData() {
                self.captureCallback?(data)
            }
        }
        print("✅ Audio tap installed")
    }
}

private extension AVAudioPCMBuffer {
    func toPCMData() -> Data? {
        guard let channelData = floatChannelData?[0] else { return nil }
        let channelDataPointer = UnsafeBufferPointer(start: channelData, count: Int(frameLength))
        var pcm16 = [Int16](repeating: 0, count: Int(frameLength))
        for (index, sample) in channelDataPointer.enumerated() {
            let clipped = max(-1, min(1, sample))
            pcm16[index] = Int16(clipped * Float(Int16.max))
        }
        return pcm16.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }
}

