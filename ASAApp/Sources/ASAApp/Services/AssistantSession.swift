import Foundation
import OpenAI
import OSLog

@MainActor
final class AssistantSession {
    private let logger = Logger(subsystem: "ASAApp", category: "AssistantSession")
    private let ragStore: RAGStore
    private let openAIClient: OpenAI
    private let conversationStore: ConversationStore
    private let audioPipeline: AudioPipeline
    private let overlayController = OverlayWindowController()
    private let functionRouter = AssistantFunctionRouter()
    
    // Realtime API components
    private var realtimeSession: RealtimeSession?
    private var voiceInputManager: VoiceInputManager?
    private var voiceOutputManager: VoiceOutputManager?
    
    // State
    private var isRealtimeActive: Bool = false
    private var connectionTimeoutTask: Task<Void, Never>?

    init(
        ragStore: RAGStore,
        conversationStore: ConversationStore,
        audioPipeline: AudioPipeline
    ) {
        self.ragStore = ragStore
        self.conversationStore = conversationStore
        self.audioPipeline = audioPipeline

        // Load the API key from .env or environment variables
        let apiKey = EnvLoader.loadAPIKey() ?? ""
        if apiKey.isEmpty {
            logger.warning("OPENAI_API_KEY not found. Please set it in .env file or environment variables.")
        }
        self.openAIClient = OpenAI(apiToken: apiKey)
    }

    func handleUserText(
        _ text: String,
        edition: AbletonEdition,
        autoCapture: Bool
    ) async {
        // If Realtime session is active, send text through it
        if isRealtimeActive, let realtimeSession = realtimeSession {
            realtimeSession.sendText(text)
            return
        }
        
        // Otherwise, use HTTP API (original behavior)
        let ragContext = ragStore.retrieve(for: text, edition: edition)
        do {
            let chatQuery = ChatQuery(
                messages: [
                    .system(.init(content: .textContent(ragContext.systemPrompt))),
                    .user(.init(content: .string(ragContext.userAugmentedPrompt(with: text))))
                ],
                model: .gpt4_o
            )
            let response = try await openAIClient.chats(query: chatQuery)

            let assistantText = response.choices.first?.message.content ?? "…"
            let entry = ConversationEntry(
                role: .assistant,
                text: assistantText
            )
            conversationStore.append(entry)
        } catch {
            logger.error("Failed to handle text: \(error.localizedDescription)")
            let entry = ConversationEntry(
                role: .assistant,
                text: "Unable to get a response from the assistant. Check the API key in your .env file."
            )
            conversationStore.append(entry)
        }
    }

    func handleAudioChunk(_ chunk: Data) {
        // Audio chunks are now handled by VoiceInputManager
        // This method is kept for backward compatibility
        if isRealtimeActive {
            realtimeSession?.sendAudioFrame(chunk)
        }
    }
    
    /// Start Realtime voice assistant session
    func startRealtimeSession() {
        guard !isRealtimeActive else {
            logger.warning("Realtime session already active")
            let entry = ConversationEntry(
                role: .assistant,
                text: "Voice assistant is already running."
            )
            conversationStore.append(entry)
            return
        }
        
        logger.info("Starting Realtime voice assistant session...")
        
        guard let apiKey = EnvLoader.loadAPIKey(), !apiKey.isEmpty else {
            logger.error("API key not found")
            let entry = ConversationEntry(
                role: .assistant,
                text: """
                ⚠️ Cannot start voice assistant: API key not found.
                
                Please set OPENAI_API_KEY in your .env file or environment variables.
                """
            )
            conversationStore.append(entry)
            return
        }
        
        // Create Realtime session
        let session = RealtimeSession(
            apiKey: apiKey,
            ragStore: ragStore,
            conversationStore: conversationStore,
            edition: conversationStore.abletonEdition
        )
        
        // Setup callbacks BEFORE starting (so errors are handled)
        setupRealtimeCallbacks(session)
        
        // Create voice managers
        let inputManager = VoiceInputManager(audioPipeline: audioPipeline, realtimeSession: session)
        let outputManager = VoiceOutputManager()
        
        // Setup voice output callback
        session.onAudioDelta = { [weak outputManager] audioData in
            outputManager?.addAudioData(audioData)
        }
        
        // Store references
        self.realtimeSession = session
        self.voiceInputManager = inputManager
        self.voiceOutputManager = outputManager
        
        // Start WebSocket connection first
        session.start()
        
        // Voice managers will be started after connection is established
        // (see setupRealtimeCallbacks - onStatusChange when status becomes "Ready")
        
        // Set connection timeout (10 seconds)
        connectionTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            
            // Check if connection was established
            if !isRealtimeActive {
                logger.error("Connection timeout - session not established")
                let entry = ConversationEntry(
                    role: .assistant,
                    text: """
                    ⚠️ Connection timeout: Failed to establish connection to voice assistant.
                    
                    Please check your internet connection and try again.
                    """
                )
                conversationStore.append(entry)
                stopRealtimeSession()
            }
        }
        
        // Note: isRealtimeActive will be set to true only after successful connection
        // This happens in setupRealtimeCallbacks when session is ready
    }
    
    /// Stop Realtime voice assistant session
    func stopRealtimeSession() {
        // Allow stopping even if not fully active (e.g., if connection failed)
        if !isRealtimeActive && realtimeSession == nil {
            logger.warning("Realtime session not active")
            return
        }
        
        logger.info("Stopping Realtime voice assistant session...")
        
        // Cancel connection timeout
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        
        voiceInputManager?.stop()
        voiceOutputManager?.stop()
        realtimeSession?.stop()
        
        voiceInputManager = nil
        voiceOutputManager = nil
        realtimeSession = nil
        
        isRealtimeActive = false
        conversationStore.isRealtimeActive = false
    }
    
    private func setupRealtimeCallbacks(_ session: RealtimeSession) {
        // Text delta
        session.onTextDelta = { [weak self] delta in
            // Text is being streamed, could update UI in real-time if needed
            self?.logger.debug("Text delta: \(delta)")
        }
        
        // Response completed
        session.onResponseCompleted = { [weak self] in
            self?.logger.info("Response completed")
        }
        
        // Speech events
        session.onSpeechStarted = { [weak self] in
            self?.logger.info("Speech started")
            self?.conversationStore.isListening = true
        }
        
        session.onSpeechStopped = { [weak self] in
            self?.logger.info("Speech stopped")
            self?.conversationStore.isListening = false
        }
        
        // Status changes
        session.onStatusChange = { [weak self] status in
            guard let self = self else { return }
            self.logger.info("Status: \(status)")
            
            // When status becomes "Ready", connection is fully established
            if status == "Ready" && !self.isRealtimeActive {
                self.logger.info("Voice assistant session fully established")
                self.isRealtimeActive = true
                self.conversationStore.isRealtimeActive = true
                
                // Cancel connection timeout
                self.connectionTimeoutTask?.cancel()
                self.connectionTimeoutTask = nil
                
                // Now start voice managers since connection is ready
                self.voiceInputManager?.start()
                self.voiceOutputManager?.start()
            }
        }
        
        // Function calls
        session.onFunctionCall = { [weak self] name, arguments, callID in
            guard let self = self else {
                return ["success": false, "error": "Session deallocated"]
            }
            
            // Parse arguments
            let parsedArgs = self.functionRouter.parseArguments(arguments)
            
            // Execute function
            return await self.functionRouter.executeFunction(name: name, arguments: parsedArgs)
        }
        
        // Errors
        session.onError = { [weak self] error in
            guard let self = self else { return }
            self.logger.error("Realtime session error: \(error.localizedDescription)")
            
            // Cancel connection timeout
            self.connectionTimeoutTask?.cancel()
            self.connectionTimeoutTask = nil
            
            // Add error message to conversation
            var errorMessage = "⚠️ Voice assistant error: \(error.localizedDescription)"
            
            // Provide more helpful error messages for common issues
            if let nsError = error as NSError? {
                if nsError.domain == "RealtimeWebSocket" {
                    switch nsError.code {
                    case 1:
                        errorMessage = "⚠️ Cannot connect: API key is empty. Please check your .env file."
                    case 4:
                        errorMessage = "⚠️ Connection failed: Could not establish connection to OpenAI Realtime API. Please check your internet connection."
                    case 5, 6, 7:
                        errorMessage = "⚠️ Connection error: Socket is not connected. The connection may have been lost or not yet established."
                    default:
                        break
                    }
                }
                
                // Check for common socket errors
                let errorDesc = error.localizedDescription.lowercased()
                if errorDesc.contains("socket is not connected") || 
                   errorDesc.contains("socket") && errorDesc.contains("not connected") {
                    errorMessage = "⚠️ Connection error: Socket is not connected. Please try starting the voice assistant again."
                }
            }
            
            let entry = ConversationEntry(
                role: .assistant,
                text: errorMessage
            )
            self.conversationStore.append(entry)
            
            // Stop the session and reset state to unblock input
            self.stopRealtimeSession()
        }
    }

    func updateAutoCapture(isEnabled: Bool) {
        let logger = Logger(subsystem: "ASAApp", category: "AssistantSession")
        
        if isEnabled {
            logger.info("Enabling automatic click capture")
            
            // Check permissions before starting
            if !ClickMonitor.shared.hasAccessibilityPermissions {
                logger.warning("Accessibility permissions not granted")
                
                // Show permission request dialog (only once)
                ClickMonitor.shared.requestAccessibilityPermissions()
                
                // Add message to chat with instructions
                conversationStore.append(
                    ConversationEntry(
                        role: .assistant,
                        text: """
                        ⚠️ Accessibility permissions are required for automatic click capture to work.
                        
                        Instructions:
                        1. If a macOS dialog appears, click "Open Settings"
                        2. Or open manually: Settings → Privacy & Security → Accessibility
                        3. Add ASAApp to the list of allowed applications (click "+")
                        4. IMPORTANT: Fully close and restart the ASAApp application
                        5. After restart, enable the "Auto-click Capture" toggle again
                        
                        After this, automatic click capture will work.
                        """
                    )
                )
                return
            }
            
            // Keep references to necessary objects so they are not deallocated
            let store = conversationStore
            let overlay = overlayController
            
            ClickMonitor.shared.start { location in
                logger.info("Received click callback at point: (\(location.x), \(location.y))")
                
                Task { @MainActor in
                    logger.info("Starting screenshot capture for click at point: (\(location.x), \(location.y))")
                    do {
                        let url = try await AbletonScreenshotService.shared.captureRegionAround(point: location)
                        logger.info("Screenshot successfully captured: \(url.path)")
                        let entry = ConversationEntry(
                            role: .system,
                            text: "Click captured at (\(Int(location.x)), \(Int(location.y))).",
                            screenshotURL: url
                        )
                        store.append(entry)
                        
                        // Render pulse on overlay
                        let command = OverlayCommand(type: .pulse(center: location, radius: 60), caption: "Click")
                        overlay.render(commands: [command])
                    } catch {
                        logger.error("Error capturing screenshot: \(error.localizedDescription)")
                        let errorMessage = error.localizedDescription
                        store.append(
                            ConversationEntry(role: .assistant, text: "Failed to capture screenshot for this click: \(errorMessage)")
                        )
                    }
                }
            }
        } else {
            logger.info("Disabling automatic click capture")
            ClickMonitor.shared.stop()
        }
    }

    private func renderPulse(at point: CGPoint) {
        let command = OverlayCommand(type: .pulse(center: point, radius: 60), caption: "Click")
        overlayController.render(commands: [command])
    }

    func captureManualScreenshot() {
        Task { @MainActor in
            do {
                let url = try await AbletonScreenshotService.shared.captureAbletonWindow()
                let entry = ConversationEntry(role: .system, text: "Screenshot saved", screenshotURL: url)
                self.conversationStore.append(entry)
            } catch {
                self.conversationStore.append(
                    ConversationEntry(role: .assistant, text: "Screenshot error: \(error.localizedDescription)")
                )
            }
        }
    }

    func importScreenshot() {
        Task { @MainActor in
            AbletonScreenshotService.shared.importScreenshot { url in
                guard let url else { return }
                Task { @MainActor in
                    let entry = ConversationEntry(role: .system, text: "Screenshot imported", screenshotURL: url)
                    self.conversationStore.append(entry)
                }
            }
        }
    }
}

