import Foundation
import OSLog

/// Manages Realtime API session with RAG context and conversation history
@MainActor
final class RealtimeSession {
    private let logger = Logger(subsystem: "ASAApp", category: "RealtimeSession")
    private let webSocketClient: RealtimeWebSocketClient
    private let ragStore: RAGStore
    private let conversationStore: ConversationStore
    private let edition: AbletonEdition
    
    // State
    private var currentResponseText: String = ""
    private var currentResponseItemID: String?
    private var isProcessingFunctionCall: Bool = false
    private var functionCallName: String?
    private var functionCallArguments: String = ""
    
    // Callbacks
    var onTextDelta: ((String) -> Void)?
    var onAudioDelta: ((Data) -> Void)?
    var onResponseCompleted: (() -> Void)?
    var onSpeechStarted: (() -> Void)?
    var onSpeechStopped: (() -> Void)?
    var onError: ((Error) -> Void)?
    var onStatusChange: ((String) -> Void)?
    var onFunctionCall: ((String, String, String) async -> [String: Any])? // name, arguments, callID
    
    init(
        apiKey: String,
        ragStore: RAGStore,
        conversationStore: ConversationStore,
        edition: AbletonEdition
    ) {
        self.webSocketClient = RealtimeWebSocketClient(apiKey: apiKey)
        self.ragStore = ragStore
        self.conversationStore = conversationStore
        self.edition = edition
        
        setupWebSocketHandlers()
    }
    
    /// Start Realtime session with RAG context and conversation history
    func start() {
        logger.info("Starting Realtime session...")
        webSocketClient.connect()
    }
    
    /// Stop Realtime session
    func stop() {
        logger.info("Stopping Realtime session...")
        webSocketClient.disconnect()
    }
    
    /// Send text message
    func sendText(_ text: String) {
        logger.debug("Sending text: \(text)")
        webSocketClient.sendText(text)
        
        // Add to conversation store
        let entry = ConversationEntry(role: .user, text: text)
        conversationStore.append(entry)
    }
    
    /// Send audio frame
    func sendAudioFrame(_ audioData: Data) {
        webSocketClient.sendAudioFrame(audioData)
    }
    
    /// Send function call result
    func sendFunctionCallResult(callID: String, result: [String: Any]) {
        let message: [String: Any] = [
            "type": "function_call.output",
            "function_call_id": callID,
            "output": result
        ]
        webSocketClient.sendMessage(message)
    }
    
    var isConnected: Bool {
        webSocketClient.isConnected
    }
    
    // MARK: - Private
    
    private func setupWebSocketHandlers() {
        webSocketClient.onMessage { [weak self] data in
            Task { @MainActor in
                self?.handleMessage(data)
            }
        }
        
        webSocketClient.onError { [weak self] error in
            Task { @MainActor in
                guard let self = self else { return }
                self.logger.error("WebSocket error: \(error.localizedDescription)")
                self.onError?(error)
                // Error handler in AssistantSession will stop the session
            }
        }
        
        webSocketClient.onConnectionChange { [weak self] connected in
            Task { @MainActor in
                if connected {
                    self?.initializeSession()
                } else {
                    self?.onStatusChange?("Disconnected")
                }
            }
        }
    }
    
    private func handleMessage(_ data: Data) {
        guard let event = RealtimeEventParser.parse(data) else {
            logger.warning("Failed to parse event")
            return
        }
        
        logger.debug("Received event: \(event.type.rawValue)")
        
        switch event.type {
        case .responseTextDelta:
            if let delta = RealtimeEventParser.extractTextDelta(event) {
                currentResponseText += delta
                onTextDelta?(delta)
            }
            
        case .responseAudioDelta:
            if let audioData = RealtimeEventParser.extractAudioDelta(event) {
                onAudioDelta?(audioData)
            }
            
        case .responseDone:
            handleResponseDone(event)
            
        case .inputAudioBufferSpeechStarted:
            onSpeechStarted?()
            onStatusChange?("Listening...")
            
        case .inputAudioBufferSpeechStopped:
            onSpeechStopped?()
            onStatusChange?("Processing...")
            
        case .conversationItemCreated:
            handleConversationItemCreated(event)
            
        case .conversationItemInputAudioTranscriptionCompleted:
            handleTranscriptionCompleted(event)
            
        case .responseFunctionCall:
            if let (name, arguments) = RealtimeEventParser.extractFunctionCall(event) {
                handleFunctionCall(name: name, arguments: arguments, event: event)
            }
            
        case .responseFunctionCallArgumentsDelta:
            if let delta = RealtimeEventParser.extractFunctionCallArgumentsDelta(event) {
                functionCallArguments += delta
            }
            
        case .error:
            let (code, message) = RealtimeEventParser.extractError(event)
            let error = NSError(
                domain: "RealtimeSession",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: message ?? "Unknown error",
                    "code": code ?? "unknown"
                ]
            )
            onError?(error)
            
        case .sessionUpdated:
            logger.info("Session updated")
            
        case .unknown:
            logger.warning("Unknown event type: \(event.data)")
        }
    }
    
    private func initializeSession() {
        logger.info("Initializing Realtime session with RAG context...")
        
        // Get RAG context (use empty query for initial context)
        let ragContext = ragStore.retrieve(for: "", edition: edition)
        
        // Build conversation history from ConversationStore
        var conversationItems: [[String: Any]] = []
        for entry in conversationStore.entries {
            var item: [String: Any] = [
                "type": entry.role == .user ? "message" : "message",
                "role": entry.role == .user ? "user" : "assistant"
            ]
            
            var content: [[String: Any]] = []
            if !entry.text.isEmpty {
                content.append([
                    "type": "input_text",
                    "text": entry.text
                ])
            }
            if let screenshotURL = entry.screenshotURL {
                // Note: Realtime API might need base64 encoded image
                // For now, we'll include the URL in text
                content.append([
                    "type": "input_text",
                    "text": "[Screenshot: \(screenshotURL.lastPathComponent)]"
                ])
            }
            
            item["content"] = content
            conversationItems.append(item)
        }
        
        // Create session update with system prompt and history
        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": ragContext.systemPrompt,
                "voice": "alloy",
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": "whisper-1"
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500
                ],
                "tools": [
                    [
                        "type": "function",
                        "name": "make_screenshot",
                        "description": "Capture a screenshot of the Ableton Live window",
                        "parameters": [
                            "type": "object",
                            "properties": [:]
                        ]
                    ],
                    [
                        "type": "function",
                        "name": "make_screenshot_of_window",
                        "description": "Capture a screenshot of a specific window by name",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "windowName": [
                                    "type": "string",
                                    "description": "Name of the window to capture"
                                ]
                            ],
                            "required": ["windowName"]
                        ]
                    ],
                    [
                        "type": "function",
                        "name": "make_screenshot_around_point",
                        "description": "Capture a screenshot of a region around a specific point",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "x": ["type": "number", "description": "X coordinate"],
                                "y": ["type": "number", "description": "Y coordinate"],
                                "width": ["type": "number", "description": "Width of the region"],
                                "height": ["type": "number", "description": "Height of the region"]
                            ],
                            "required": ["x", "y", "width", "height"]
                        ]
                    ],
                    [
                        "type": "function",
                        "name": "detect_button_click",
                        "description": "Simulate a mouse click at specific coordinates",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "x": ["type": "number", "description": "X coordinate"],
                                "y": ["type": "number", "description": "Y coordinate"]
                            ],
                            "required": ["x", "y"]
                        ]
                    ],
                    [
                        "type": "function",
                        "name": "draw_arrow",
                        "description": "Draw an arrow on the overlay from one point to another",
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "x1": ["type": "number", "description": "Start X coordinate"],
                                "y1": ["type": "number", "description": "Start Y coordinate"],
                                "x2": ["type": "number", "description": "End X coordinate"],
                                "y2": ["type": "number", "description": "End Y coordinate"]
                            ],
                            "required": ["x1", "y1", "x2", "y2"]
                        ]
                    ],
                    [
                        "type": "function",
                        "name": "clear_arrows",
                        "description": "Clear all arrows from the overlay",
                        "parameters": [
                            "type": "object",
                            "properties": [:]
                        ]
                    ]
                ]
            ]
        ]
        
        webSocketClient.sendMessage(sessionUpdate)
        
        // Add conversation history if available
        if !conversationItems.isEmpty {
            // Note: Realtime API might need items added differently
            // This is a simplified version
            logger.info("Adding \(conversationItems.count) conversation items to history")
        }
        
        onStatusChange?("Connected")
    }
    
    private func handleResponseDone(_ event: RealtimeEventParser.ParsedEvent) {
        logger.info("Response completed")
        
        // Save completed response to conversation store
        if !currentResponseText.isEmpty {
            let entry = ConversationEntry(role: .assistant, text: currentResponseText)
            conversationStore.append(entry)
            currentResponseText = ""
        }
        
        onResponseCompleted?()
        onStatusChange?("Ready")
    }
    
    private func handleConversationItemCreated(_ event: RealtimeEventParser.ParsedEvent) {
        if let itemID = event.data["item_id"] as? String {
            currentResponseItemID = itemID
            logger.debug("Created conversation item: \(itemID)")
        }
    }
    
    private func handleTranscriptionCompleted(_ event: RealtimeEventParser.ParsedEvent) {
        if let transcript = event.data["transcript"] as? String {
            logger.debug("Transcription: \(transcript)")
            // User's speech was transcribed, could add to conversation if needed
        }
    }
    
    private func handleFunctionCall(name: String, arguments: String, event: RealtimeEventParser.ParsedEvent) {
        logger.info("Function call: \(name) with arguments: \(arguments)")
        
        guard let callID = event.data["call_id"] as? String else {
            logger.error("Function call missing call_id")
            return
        }
        
        isProcessingFunctionCall = true
        functionCallName = name
        functionCallArguments = arguments
        
        onStatusChange?("Executing function: \(name)")
        
        // Execute function call asynchronously
        Task {
            guard let functionHandler = onFunctionCall else {
                logger.error("No function call handler set")
                completeFunctionCall(callID: callID, result: ["success": false, "error": "No handler"])
                return
            }
            
            let result = await functionHandler(name, arguments, callID)
            completeFunctionCall(callID: callID, result: result)
        }
    }
    
    /// Get current function call info (for AssistantFunctionRouter)
    func getCurrentFunctionCall() -> (name: String, arguments: String)? {
        guard isProcessingFunctionCall,
              let name = functionCallName else {
            return nil
        }
        return (name: name, arguments: functionCallArguments)
    }
    
    /// Mark function call as completed
    func completeFunctionCall(callID: String, result: [String: Any]) {
        isProcessingFunctionCall = false
        functionCallName = nil
        functionCallArguments = ""
        sendFunctionCallResult(callID: callID, result: result)
    }
}

