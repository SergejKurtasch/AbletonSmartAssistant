import Foundation
import OSLog

/// Parser for Realtime API events
struct RealtimeEventParser {
    private static let logger = Logger(subsystem: "ASAApp", category: "RealtimeEventParser")
    
    enum EventType: String {
        case responseTextDelta = "response.text.delta"
        case responseAudioDelta = "response.audio.delta"
        case responseDone = "response.done"
        case inputAudioBufferSpeechStarted = "input_audio_buffer.speech_started"
        case inputAudioBufferSpeechStopped = "input_audio_buffer.speech_stopped"
        case conversationItemCreated = "conversation.item.created"
        case conversationItemInputAudioTranscriptionCompleted = "conversation.item.input_audio_transcription.completed"
        case responseFunctionCall = "response.function_call"
        case responseFunctionCallArgumentsDelta = "response.function_call_arguments.delta"
        case error = "error"
        case sessionUpdated = "session.updated"
        case unknown
    }
    
    struct ParsedEvent {
        let type: EventType
        let data: [String: Any]
        let rawData: Data
    }
    
    static func parse(_ data: Data) -> ParsedEvent? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logger.warning("Failed to parse JSON")
            return nil
        }
        
        let eventTypeString = json["type"] as? String ?? "unknown"
        let eventType = EventType(rawValue: eventTypeString) ?? .unknown
        
        return ParsedEvent(type: eventType, data: json, rawData: data)
    }
    
    /// Extract text delta from response.text.delta event
    static func extractTextDelta(_ event: ParsedEvent) -> String? {
        guard event.type == .responseTextDelta else { return nil }
        return event.data["delta"] as? String
    }
    
    /// Extract audio delta from response.audio.delta event
    static func extractAudioDelta(_ event: ParsedEvent) -> Data? {
        guard event.type == .responseAudioDelta else { return nil }
        guard let base64Audio = event.data["delta"] as? String else { return nil }
        return Data(base64Encoded: base64Audio)
    }
    
    /// Extract function call from response.function_call event
    static func extractFunctionCall(_ event: ParsedEvent) -> (name: String, arguments: String)? {
        guard event.type == .responseFunctionCall else { return nil }
        guard let name = event.data["name"] as? String,
              let arguments = event.data["arguments"] as? String else {
            return nil
        }
        return (name: name, arguments: arguments)
    }
    
    /// Extract function call arguments delta
    static func extractFunctionCallArgumentsDelta(_ event: ParsedEvent) -> String? {
        guard event.type == .responseFunctionCallArgumentsDelta else { return nil }
        return event.data["delta"] as? String
    }
    
    /// Extract error from error event
    static func extractError(_ event: ParsedEvent) -> (code: String?, message: String?) {
        guard event.type == .error else { return (nil, nil) }
        let code = event.data["code"] as? String
        let message = event.data["message"] as? String
        return (code: code, message: message)
    }
}

