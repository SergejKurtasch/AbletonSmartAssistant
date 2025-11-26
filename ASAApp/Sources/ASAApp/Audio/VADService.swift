import Foundation
import AVFoundation

struct VADResult {
    let isSpeech: Bool
    let confidence: Double
}

final class VADService {
    private let threshold: Float = 0.01
    private let minSpeechFrames: Int = 3
    private var speechFrameCount: Int = 0

    func analyze(buffer: AVAudioPCMBuffer) -> VADResult {
        guard let channelData = buffer.floatChannelData?[0] else {
            return VADResult(isSpeech: false, confidence: 0.0)
        }

        let frameLength = Int(buffer.frameLength)
        var sum: Float = 0.0
        var maxAmplitude: Float = 0.0

        for i in 0..<frameLength {
            let sample = abs(channelData[i])
            sum += sample * sample
            maxAmplitude = max(maxAmplitude, sample)
        }

        let rms = sqrt(sum / Float(frameLength))
        let isSpeech = rms > threshold && maxAmplitude > threshold * 2

        if isSpeech {
            speechFrameCount += 1
        } else {
            speechFrameCount = max(0, speechFrameCount - 1)
        }

        let confidence = Double(min(1.0, Float(speechFrameCount) / Float(minSpeechFrames)))
        let detected = speechFrameCount >= minSpeechFrames

        return VADResult(isSpeech: detected, confidence: confidence)
    }
}

