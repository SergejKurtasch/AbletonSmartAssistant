import Foundation
import OSLog

/// WebSocket client for OpenAI Realtime API
final class RealtimeWebSocketClient {
    private let logger = Logger(subsystem: "ASAApp", category: "RealtimeWebSocket")
    private var webSocketTask: URLSessionWebSocketTask?
    private let apiKey: String
    private let model: String
    private var messageHandler: ((Data) -> Void)?
    private var errorHandler: ((Error) -> Void)?
    private var connectionHandler: ((Bool) -> Void)?
    
    init(apiKey: String, model: String = "gpt-4o-realtime-preview-2024-12-17") {
        self.apiKey = apiKey
        self.model = model
    }
    
    /// Connect to Realtime API
    func connect() {
        guard !apiKey.isEmpty else {
            logger.error("API key is empty")
            errorHandler?(NSError(domain: "RealtimeWebSocket", code: 1, userInfo: [NSLocalizedDescriptionKey: "API key is empty"]))
            return
        }
        
        var urlComponents = URLComponents(string: "https://api.openai.com/v1/realtime")!
        urlComponents.queryItems = [URLQueryItem(name: "model", value: model)]
        
        guard let url = urlComponents.url else {
            logger.error("Failed to create URL")
            errorHandler?(NSError(domain: "RealtimeWebSocket", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to create URL"]))
            return
        }
        
        // Convert https to wss
        let wsURL = url.absoluteString.replacingOccurrences(of: "https://", with: "wss://")
        guard let webSocketURL = URL(string: wsURL) else {
            logger.error("Failed to create WebSocket URL")
            errorHandler?(NSError(domain: "RealtimeWebSocket", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create WebSocket URL"]))
            return
        }
        
        var request = URLRequest(url: webSocketURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: request)
        
        logger.info("Connecting to Realtime API...")
        webSocketTask?.resume()
        
        connectionHandler?(true)
        receiveMessages()
    }
    
    /// Disconnect from Realtime API
    func disconnect() {
        logger.info("Disconnecting from Realtime API...")
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        connectionHandler?(false)
    }
    
    /// Send JSON message to Realtime API
    func sendMessage(_ message: [String: Any]) {
        guard let webSocketTask = webSocketTask else {
            logger.warning("WebSocket not connected, cannot send message")
            return
        }
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: message, options: [])
            let messageString = String(data: jsonData, encoding: .utf8) ?? ""
            
            let wsMessage = URLSessionWebSocketTask.Message.string(messageString)
            webSocketTask.send(wsMessage) { [weak self] error in
                if let error = error {
                    self?.logger.error("Failed to send message: \(error.localizedDescription)")
                    self?.errorHandler?(error)
                } else {
                    self?.logger.debug("Message sent successfully")
                }
            }
        } catch {
            logger.error("Failed to serialize message: \(error.localizedDescription)")
            errorHandler?(error)
        }
    }
    
    /// Send audio frame (base64 encoded PCM data)
    func sendAudioFrame(_ audioData: Data) {
        let base64Audio = audioData.base64EncodedString()
        let message: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]
        sendMessage(message)
    }
    
    /// Send text input
    func sendText(_ text: String) {
        let message: [String: Any] = [
            "type": "input_audio_buffer.text.append",
            "text": text
        ]
        sendMessage(message)
    }
    
    /// Set message handler
    func onMessage(_ handler: @escaping (Data) -> Void) {
        messageHandler = handler
    }
    
    /// Set error handler
    func onError(_ handler: @escaping (Error) -> Void) {
        errorHandler = handler
    }
    
    /// Set connection handler
    func onConnectionChange(_ handler: @escaping (Bool) -> Void) {
        connectionHandler = handler
    }
    
    /// Check if connected
    var isConnected: Bool {
        guard let task = webSocketTask else { return false }
        return task.state == .running
    }
    
    // MARK: - Private
    
    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self.messageHandler?(data)
                    }
                case .data(let data):
                    self.messageHandler?(data)
                @unknown default:
                    self.logger.warning("Unknown message type")
                }
                
                // Continue receiving
                self.receiveMessages()
                
            case .failure(let error):
                self.logger.error("WebSocket receive error: \(error.localizedDescription)")
                self.errorHandler?(error)
                // Try to reconnect or stop
                self.disconnect()
            }
        }
    }
}

