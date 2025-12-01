import Foundation
import AVFoundation
import Speech
import OSLog

@MainActor
final class StreamingSpeechRecognizer: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "ASAApp", category: "StreamingSpeechRecognizer")
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioPipeline: AudioPipeline
    
    @Published var recognizedText: String = ""
    @Published var isRecognizing: Bool = false
    @Published var hasError: Bool = false
    @Published var errorMessage: String = ""
    
    var onTextUpdate: ((String) -> Void)?
    
    init(audioPipeline: AudioPipeline) {
        self.audioPipeline = audioPipeline
        // Initialize with English locale (can be changed)
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()
        
        // Request authorization
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                switch status {
                case .authorized:
                    self.logger.info("Speech recognition authorized")
                case .denied, .restricted, .notDetermined:
                    self.logger.warning("Speech recognition not authorized: \(status.rawValue)")
                    self.hasError = true
                    self.errorMessage = "Speech recognition permission denied. Please enable in System Settings → Privacy & Security → Speech Recognition"
                @unknown default:
                    break
                }
            }
        }
    }
    
    /// Start streaming recognition
    func startRecognition(locale: Locale) throws {
        guard !isRecognizing else {
            logger.warning("Already recognizing")
            return
        }
        
        // Stop any existing recognition
        stopRecognition()
        
        // Create recognizer with the specified locale
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            logger.error("Speech recognizer not available for locale: \(locale.identifier)")
            throw StreamingSpeechError.recognizerUnavailable
        }
        
        logger.info("Using speech recognizer for locale: \(locale.identifier)")
        
        logger.info("Starting streaming speech recognition...")
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else {
            throw StreamingSpeechError.requestCreationFailed
        }
        
        request.shouldReportPartialResults = true
        
        // Use existing AudioPipeline instead of creating new engine
        // Start audio pipeline with buffer callback
        audioPipeline.startStreamingWithBuffer { [weak self] buffer in
            self?.recognitionRequest?.append(buffer)
        }
        
        // Start recognition task
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                if let error = error {
                    self.logger.error("Recognition error: \(error.localizedDescription)")
                    self.hasError = true
                    self.errorMessage = error.localizedDescription
                    self.stopRecognition()
                    return
                }
                
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    self.recognizedText = text
                    self.onTextUpdate?(text)
                    
                    if result.isFinal {
                        self.logger.info("Recognition finalized: \(text)")
                        // Don't stop here - continue recognizing
                    }
                }
            }
        }
        
        isRecognizing = true
        hasError = false
        errorMessage = ""
        recognizedText = ""
        
        logger.info("Streaming recognition started")
    }
    
    /// Stop recognition
    func stopRecognition() {
        guard isRecognizing else { return }
        
        logger.info("Stopping recognition...")
        
        isRecognizing = false
        
        recognitionTask?.cancel()
        recognitionTask = nil
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        
        // Stop audio pipeline
        audioPipeline.stopStreaming()
        
        logger.info("Recognition stopped")
    }
    
    /// Get final recognized text
    func getFinalText() -> String {
        return recognizedText
    }
}

enum StreamingSpeechError: LocalizedError {
    case recognizerUnavailable
    case requestCreationFailed
    
    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognizer is not available"
        case .requestCreationFailed:
            return "Failed to create recognition request"
        }
    }
}

