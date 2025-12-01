import Foundation
import AVFoundation
import OSLog

@MainActor
final class VoiceToTextService {
    private let logger = Logger(subsystem: "ASAApp", category: "VoiceToTextService")
    private let apiKey: String
    private let audioPipeline: AudioPipeline
    
    // Recording state
    private var isRecording: Bool = false
    private var audioFileURL: URL?
    private let audioDataActor = AudioDataActor()
    private var actualSampleRate: Double = 16000.0
    private var actualChannels: UInt32 = 1
    
    init(apiKey: String, audioPipeline: AudioPipeline) {
        self.apiKey = apiKey
        self.audioPipeline = audioPipeline
    }
    
    /// Start recording audio
    func startRecording() throws {
        guard !isRecording else {
            logger.warning("Already recording")
            return
        }
        
        logger.info("Starting audio recording...")
        
        // Get audio format from pipeline
        guard let format = audioPipeline.getInputFormat() else {
            logger.error("Failed to get audio format from pipeline")
            throw VoiceToTextError.fileCreationFailed
        }
        
        actualSampleRate = format.sampleRate
        actualChannels = format.channelCount
        logger.info("Using audio format: sampleRate=\(self.actualSampleRate), channels=\(self.actualChannels)")
        
        // Create temporary file for recording
        let tempDir = FileManager.default.temporaryDirectory
        audioFileURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        
        guard audioFileURL != nil else {
            throw VoiceToTextError.fileCreationFailed
        }
        
        // Initialize audio data buffer
        Task {
            await audioDataActor.clear()
        }
        isRecording = true
        
        // Start audio pipeline with callback - get PCM16 data directly
        audioPipeline.startStreaming { [weak self] audioData in
            self?.handleAudioChunk(audioData)
        }
        
        logger.info("Recording started")
    }
    
    /// Stop recording and transcribe
    func stopAndTranscribe() async throws -> String {
        guard isRecording else {
            throw VoiceToTextError.notRecording
        }
        
        logger.info("Stopping recording and transcribing...")
        
        // Stop audio pipeline
        audioPipeline.stopStreaming()
        isRecording = false
        
        // Wait a bit for any pending audio chunks
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
        
        guard let fileURL = audioFileURL else {
            throw VoiceToTextError.fileCreationFailed
        }
        
        // Get recorded audio data
        let audioData = await audioDataActor.getData()
        
        guard !audioData.isEmpty else {
            throw VoiceToTextError.noAudioRecorded
        }
        
        logger.info("Recorded \(audioData.count) bytes of PCM16 audio")
        
        // Write WAV file with correct format
        try writeWAVFile(data: audioData, sampleRate: self.actualSampleRate, channels: self.actualChannels, to: fileURL)
        
        // Verify file was created
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.error("WAV file was not created at: \(fileURL.path)")
            throw VoiceToTextError.fileCreationFailed
        }
        
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = fileAttributes?[.size] as? Int64 ?? 0
        logger.info("WAV file exists, size: \(fileSize) bytes")
        
        guard fileSize > 0 else {
            throw VoiceToTextError.noAudioRecorded
        }
        
        // Transcribe audio file
        let transcription = try await transcribeAudioFile(fileURL)
        
        // Clean up temporary file
        try? FileManager.default.removeItem(at: fileURL)
        audioFileURL = nil
        await audioDataActor.clear()
        
        logger.info("Transcription completed: \(transcription.prefix(50))...")
        return transcription
    }
    
    /// Cancel recording without transcribing
    func cancelRecording() {
        guard isRecording else { return }
        
        logger.info("Cancelling recording...")
        
        audioPipeline.stopStreaming()
        
        if let fileURL = audioFileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        audioFileURL = nil
        Task {
            await audioDataActor.clear()
        }
        isRecording = false
    }
    
    /// Get current recording state
    var recording: Bool {
        return isRecording
    }
    
    // MARK: - Private
    
    private func handleAudioChunk(_ audioData: Data) {
        guard isRecording else { return }
        
        Task {
            await audioDataActor.append(audioData)
        }
    }
    
    private func writeWAVFile(data: Data, sampleRate: Double, channels: UInt32, to url: URL) throws {
        // Create the file if it doesn't exist
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        }
        
        let fileHandle = try FileHandle(forWritingTo: url)
        defer { try? fileHandle.close() }
        
        // Truncate file to start fresh
        try fileHandle.truncate(atOffset: 0)
        
        let dataSize = UInt32(data.count)
        let fileSize = UInt32(36 + dataSize) // Header size + data size
        let bitsPerSample: UInt32 = 16
        
        // WAV header
        var header = Data()
        
        // RIFF header
        header.append("RIFF".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        header.append("WAVE".data(using: .ascii)!)
        
        // fmt chunk
        header.append("fmt ".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) }) // fmt chunk size
        header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) }) // audio format (PCM)
        header.append(contentsOf: withUnsafeBytes(of: UInt16(channels).littleEndian) { Data($0) }) // channels
        header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) }) // sample rate
        let byteRate = UInt32(sampleRate * Double(channels * bitsPerSample / 8))
        header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        let blockAlign = UInt16(channels * bitsPerSample / 8)
        header.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        header.append(contentsOf: withUnsafeBytes(of: UInt16(bitsPerSample).littleEndian) { Data($0) })
        
        // data chunk
        header.append("data".data(using: .ascii)!)
        header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        
        // Write header and data
        try fileHandle.write(contentsOf: header)
        try fileHandle.write(contentsOf: data)
        
        // Ensure data is written to disk
        try fileHandle.synchronize()
        
        logger.info("WAV file written: \(url.path), size: \(header.count + data.count) bytes, sampleRate: \(sampleRate), channels: \(channels)")
    }
    
    private func transcribeAudioFile(_ fileURL: URL) async throws -> String {
        guard !apiKey.isEmpty else {
            throw VoiceToTextError.apiKeyMissing
        }
        
        logger.info("Transcribing audio file: \(fileURL.lastPathComponent)")
        logger.info("File path: \(fileURL.path)")
        logger.info("File exists: \(FileManager.default.fileExists(atPath: fileURL.path))")
        
        // Read audio file data
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.error("Audio file does not exist at path: \(fileURL.path)")
            throw VoiceToTextError.fileCreationFailed
        }
        
        let audioData = try Data(contentsOf: fileURL)
        logger.info("Read \(audioData.count) bytes from audio file")
        
        // Create multipart form data
        let boundary = UUID().uuidString
        var body = Data()
        
        // Add model parameter
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)
        
        // Add language parameter (auto-detect)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!) // Empty for auto-detect
        
        // Add file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        
        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        
        // Create request
        guard let url = URL(string: "https://api.openai.com/v1/audio/transcriptions") else {
            throw VoiceToTextError.invalidRequest
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        
        // Send request
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceToTextError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Whisper API error: \(errorMessage)")
            throw VoiceToTextError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw VoiceToTextError.invalidResponse
        }
        
        logger.info("Transcription successful: \(text.prefix(50))...")
        return text
    }
}

// Actor for thread-safe audio data storage
actor AudioDataActor {
    private var data: Data = Data()
    
    func append(_ newData: Data) {
        data.append(newData)
    }
    
    func getData() -> Data {
        return data
    }
    
    func clear() {
        data.removeAll()
    }
}

enum VoiceToTextError: LocalizedError {
    case apiKeyMissing
    case invalidRequest
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case fileCreationFailed
    case notRecording
    case noAudioRecorded
    
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
        case .fileCreationFailed:
            return "Failed to create audio file"
        case .notRecording:
            return "Not currently recording"
        case .noAudioRecorded:
            return "No audio was recorded"
        }
    }
}
