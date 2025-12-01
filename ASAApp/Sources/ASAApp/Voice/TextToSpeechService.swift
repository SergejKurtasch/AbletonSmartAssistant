import Foundation
import AVFoundation
import OSLog

@MainActor
final class TextToSpeechService: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "ASAApp", category: "TextToSpeechService")
    private let apiKey: String
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackRate: Float = 1.0
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    /// Generate speech from text and return audio data
    func generateSpeech(from text: String, voice: String = "alloy") async throws -> Data {
        logger.info("Generating speech for text: \(text.prefix(50))...")
        
        guard let apiKey = EnvLoader.loadAPIKey(), !apiKey.isEmpty else {
            throw TextToSpeechError.apiKeyMissing
        }
        
        // Create request body
        let requestBody: [String: Any] = [
            "model": "tts-1",
            "input": text,
            "voice": voice,
            "response_format": "mp3"
        ]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody),
              let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw TextToSpeechError.invalidRequest
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        
        // Send request
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TextToSpeechError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("TTS API error: \(errorMessage)")
            throw TextToSpeechError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        logger.info("Generated speech audio: \(data.count) bytes")
        return data
    }
    
    /// Generate and play speech immediately
    func generateAndPlay(text: String, voice: String = "alloy") async throws {
        let audioData = try await generateSpeech(from: text, voice: voice)
        
        // Save to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let audioFileURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp3")
        
        try audioData.write(to: audioFileURL)
        
        // Load and play audio
        try loadAudio(from: audioFileURL)
        try await play()
    }
    
    /// Generate speech and return file URL (for player)
    func generateSpeechToFile(text: String, voice: String = "alloy") async throws -> URL {
        let audioData = try await generateSpeech(from: text, voice: voice)
        
        // Save to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let audioFileURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp3")
        
        try audioData.write(to: audioFileURL)
        return audioFileURL
    }
    
    /// Play audio from data
    func playAudio(from data: Data) async throws {
        // Save to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let audioFileURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp3")
        
        try data.write(to: audioFileURL)
        defer {
            // Clean up after playback
            Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                try? FileManager.default.removeItem(at: audioFileURL)
            }
        }
        
        try await playAudio(from: audioFileURL)
    }
    
    /// Load audio from file URL (without playing)
    func loadAudio(from url: URL) throws {
        // Stop current playback if any
        stopPlayback()
        
        // Create new player
        audioPlayer = try AVAudioPlayer(contentsOf: url)
        audioPlayer?.prepareToPlay()
        audioPlayer?.delegate = self
        
        guard let player = audioPlayer else {
            throw TextToSpeechError.playbackError
        }
        
        duration = player.duration
        currentTime = 0
        playbackRate = 1.0
        
        logger.info("Audio loaded: duration=\(self.duration)s")
    }
    
    /// Play audio from file URL
    private func playAudio(from url: URL) async throws {
        try loadAudio(from: url)
        try await play()
    }
    
    /// Play loaded audio
    func play() throws {
        guard let player = audioPlayer else {
            throw TextToSpeechError.playbackError
        }
        
        player.enableRate = true
        player.rate = playbackRate
        
        guard player.play() else {
            throw TextToSpeechError.playbackError
        }
        
        isPlaying = true
        startPlaybackTimer()
    }
    
    /// Pause playback
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
        stopPlaybackTimer()
    }
    
    /// Stop current playback
    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopPlaybackTimer()
    }
    
    /// Seek to specific time
    func seek(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        player.currentTime = min(max(time, 0), self.duration)
        currentTime = player.currentTime
    }
    
    /// Set playback rate
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        audioPlayer?.rate = rate
    }
    
    // MARK: - Private
    
    private func startPlaybackTimer() {
        stopPlaybackTimer()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer else { return }
            self.currentTime = player.currentTime
        }
    }
    
    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }
}

// MARK: - AVAudioPlayerDelegate
extension TextToSpeechService: @preconcurrency AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.stopPlaybackTimer()
        }
    }
    
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            self.logger.error("Audio playback error: \(error?.localizedDescription ?? "Unknown")")
            self.stopPlayback()
        }
    }
}

enum TextToSpeechError: LocalizedError {
    case apiKeyMissing
    case invalidRequest
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case playbackError
    
    var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "OpenAI API key not found"
        case .invalidRequest:
            return "Invalid request"
        case .invalidResponse:
            return "Invalid response from API"
        case .apiError(let statusCode, let message):
            return "API error (\(statusCode)): \(message)"
        case .playbackError:
            return "Failed to play audio"
        }
    }
}

