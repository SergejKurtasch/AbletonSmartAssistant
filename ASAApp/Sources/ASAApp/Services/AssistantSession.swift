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
    private let langGraphClient = LangGraphClient()
    
    // Text-to-Speech service
    let ttsService: TextToSpeechService
    
    // LangGraph session management
    private var currentLangGraphSessionId: String?
    
    // Store RAG answer for step-by-step mode
    private var lastRAGAnswer: String?

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
        self.ttsService = TextToSpeechService(apiKey: apiKey)
    }

    func handleUserText(
        _ text: String,
        edition: AbletonEdition,
        autoCapture: Bool
    ) async {
        // Always use simple mode first to get full answer
        // Then offer step-by-step mode if needed
        logger.info("📝 Processing user query: \(text.prefix(50))...")
        await handleUserTextSimple(text, edition: edition)
    }
    
    /// Determine if we should use LangGraph for this query
    private func shouldUseLangGraph(for text: String) -> Bool {
        // Simple heuristic: if text mentions Ableton-related terms, use LangGraph
        let abletonKeywords = ["ableton", "live", "daw", "clip", "track", "session", "arrangement", "device", "rack"]
        let lowerText = text.lowercased()
        return abletonKeywords.contains { lowerText.contains($0) }
    }
    
    /// Start step-by-step mode using LangGraph with existing RAG answer
    func startStepByStepMode(
        for query: String,
        edition: AbletonEdition,
        withRAGAnswer: String? = nil
    ) async {
        logger.info("🚀 Starting step-by-step mode with LangGraph for query: \(query.prefix(50))...")
        
        // Use provided answer or last stored RAG answer
        let ragAnswer = withRAGAnswer ?? lastRAGAnswer
        
        if let answer = ragAnswer {
            // Start with existing answer, skip nodes 1-4
            await handleStepByStepWithRAGAnswer(
                query: query,
                ragAnswer: answer,
                edition: edition
            )
        } else {
            // Fallback to full LangGraph flow
            await handleUserTextWithLangGraph(query, edition: edition, autoCapture: false)
        }
    }
    
    /// Handle step-by-step mode starting from generate_answer node with existing RAG answer
    private func handleStepByStepWithRAGAnswer(
        query: String,
        ragAnswer: String,
        edition: AbletonEdition
    ) async {
        do {
            logger.info("📡 Starting step-by-step mode with existing RAG answer")
            logger.info("📝 RAG answer preview (first 300 chars): \(ragAnswer.prefix(300))")
            logger.info("📝 RAG answer length: \(ragAnswer.count) characters")
            
            // Get the last screenshot if available
            let lastScreenshot = conversationStore.entries.last(where: { $0.screenshotURL != nil })?.screenshotURL
            
            // Use new endpoint that starts from generate_answer
            let response = try await langGraphClient.startStepByStepWithAnswer(
                query: query,
                ragAnswer: ragAnswer,
                edition: edition,
                history: conversationStore.entries,
                screenshotURL: lastScreenshot,
                sessionId: currentLangGraphSessionId
            )
            
            logger.info("✅ Step-by-step response received: mode=\(response.mode), actionRequired=\(response.actionRequired ?? "nil"), steps=\(response.steps?.count ?? 0), sessionId=\(response.sessionId)")
            
            // Store session ID - ensure it's not empty
            guard !response.sessionId.isEmpty else {
                logger.error("❌ Received empty sessionId from server")
                let errorEntry = ConversationEntry(
                    role: .assistant,
                    text: "⚠️ Error: server did not return session identifier. Please try again."
                )
                conversationStore.append(errorEntry)
                return
            }
            
            currentLangGraphSessionId = response.sessionId
            conversationStore.langGraphSessionId = response.sessionId
            logger.info("💾 Session ID saved: currentLangGraphSessionId=\(response.sessionId), conversationStore.langGraphSessionId=\(response.sessionId)")
            
            // Add response to conversation
            let entry = ConversationEntry(
                role: .assistant,
                text: response.response
            )
            conversationStore.append(entry)
            
            // Update conversation store state
            conversationStore.actionRequired = response.actionRequired
            if response.mode == "step_by_step" {
                conversationStore.isStepByStepMode = true
                if let steps = response.steps {
                    conversationStore.totalSteps = steps.count
                    conversationStore.currentStepIndex = 0
                    // Check if first step requires click
                    if let firstStep = steps.first {
                        conversationStore.currentStepRequiresClick = firstStep.requiresClick
                    }
                }
            }
            
            // Handle action_required
            if let actionRequired = response.actionRequired {
                handleActionRequired(actionRequired, response: response)
            }
            
        } catch {
            let errorMsg = error.localizedDescription
            logger.error("❌ Failed to start step-by-step mode: \(errorMsg, privacy: .public)")
            print("❌ Step-by-step Error: \(errorMsg)")
            
            // Show error to user
            let errorEntry = ConversationEntry(
                role: .assistant,
                text: "⚠️ Failed to start step-by-step mode. Please check that LangGraph server is running on port 8000."
            )
            conversationStore.append(errorEntry)
        }
    }
    
    /// Handle text using LangGraph agent
    private func handleUserTextWithLangGraph(
        _ text: String,
        edition: AbletonEdition,
        autoCapture: Bool
    ) async {
        do {
            logger.info("📡 Sending request to LangGraph server at http://localhost:8000")
            
            // Get the last screenshot if available
            let lastScreenshot = conversationStore.entries.last(where: { $0.screenshotURL != nil })?.screenshotURL
            
            let response = try await langGraphClient.sendMessage(
                text,
                edition: edition,
                history: conversationStore.entries,
                screenshotURL: lastScreenshot,
                sessionId: currentLangGraphSessionId
            )
            
            logger.info("✅ LangGraph response received: mode=\(response.mode), actionRequired=\(response.actionRequired ?? "nil"), steps=\(response.steps?.count ?? 0)")
            
            // Store session ID
            currentLangGraphSessionId = response.sessionId
            conversationStore.langGraphSessionId = response.sessionId
            
            // Add response to conversation
            let entry = ConversationEntry(
                role: .assistant,
                text: response.response
            )
            conversationStore.append(entry)
            
            // Update conversation store state
            conversationStore.actionRequired = response.actionRequired
            if response.mode == "step_by_step" {
                conversationStore.isStepByStepMode = true
                if let steps = response.steps {
                    conversationStore.totalSteps = steps.count
                    conversationStore.currentStepIndex = 0
                    // Check if first step requires click
                    if let firstStep = steps.first {
                        conversationStore.currentStepRequiresClick = firstStep.requiresClick
                    }
                }
            }
            
            // Handle action_required
            if let actionRequired = response.actionRequired {
                handleActionRequired(actionRequired, response: response)
            }
            
        } catch {
            let errorMsg = error.localizedDescription
            logger.error("❌ Failed to handle text with LangGraph: \(errorMsg, privacy: .public)")
            logger.error("   Error type: \(String(describing: type(of: error)), privacy: .public)")
            print("❌ LangGraph Error: \(errorMsg)")
            if let langGraphError = error as? LangGraphError {
                let details = langGraphError.localizedDescription
                logger.error("   LangGraph error details: \(details, privacy: .public)")
                print("   Details: \(details)")
            }
            
            // Show error to user
            let errorEntry = ConversationEntry(
                role: .assistant,
                text: "⚠️ Failed to connect to step-by-step mode server. Please check that LangGraph server is running on port 8000."
            )
            conversationStore.append(errorEntry)
        }
    }
    
    /// Handle simple text (original implementation)
    private func handleUserTextSimple(
        _ text: String,
        edition: AbletonEdition
    ) async {
        logger.info("📝 Using simple mode (direct OpenAI API)")
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
            
            // Store answer for potential step-by-step mode
            lastRAGAnswer = assistantText
            
            // Check if answer contains step-by-step instructions
            // Look for patterns like "1.", "Step 1", numbered lists, etc.
            let lowerText = assistantText.lowercased()
            let stepPatterns = [
                "step 1", "step 2", "step 3", "step 4", "step 5",
                "first step", "second step", "third step",
                "1. ", "2. ", "3. ", "4. ", "5. "
            ]
            let hasSteps = stepPatterns.contains { lowerText.contains($0) } ||
                          // Check for numbered list pattern (1. 2. 3. etc)
                          (lowerText.components(separatedBy: "\n").filter { line in
                              let trimmed = line.trimmingCharacters(in: .whitespaces)
                              return trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
                          }.count >= 2)
            
            let entry = ConversationEntry(
                role: .assistant,
                text: assistantText
            )
            conversationStore.append(entry)
            
            // Always offer step-by-step mode if answer is long enough
            // (even if it doesn't have explicit step patterns, it might be useful to break down)
            if hasSteps || assistantText.count > 200 {
                logger.info("✅ Answer is suitable for step-by-step mode, will offer LangGraph mode")
                conversationStore.actionRequired = "offer_step_by_step"
            }
        } catch {
            logger.error("Failed to handle text: \(error.localizedDescription)")
            let entry = ConversationEntry(
                role: .assistant,
                text: "Unable to get a response from the assistant. Check the API key in your .env file."
            )
            conversationStore.append(entry)
        }
    }
    
    /// Handle action required from LangGraph response
    private func handleActionRequired(_ action: String, response: LangGraphResponse) {
        switch action {
        case "wait_version_choice":
            // UI will show version choice buttons
            logger.info("Waiting for version choice")
        case "wait_step_choice":
            // UI will show "Show step-by-step" button
            logger.info("Waiting for step choice")
        case "wait_user_action":
            // UI will show step navigation buttons
            logger.info("Waiting for user action in step-by-step mode")
        case "wait_task_completion_choice":
            // UI will show task completion buttons (Yes/No)
            logger.info("Waiting for task completion choice")
        default:
            logger.info("Unknown action required: \(action)")
        }
    }
    
    /// Handle step action in step-by-step mode
    func handleStepAction(_ action: String, screenshotURL: URL?) async {
        // Try to get sessionId from currentLangGraphSessionId or conversationStore
        let sessionId = currentLangGraphSessionId ?? conversationStore.langGraphSessionId
        
        guard let sessionId = sessionId, !sessionId.isEmpty else {
            logger.error("No active LangGraph session - currentLangGraphSessionId=\(self.currentLangGraphSessionId ?? "nil"), conversationStore.langGraphSessionId=\(self.conversationStore.langGraphSessionId ?? "nil")")
            let errorEntry = ConversationEntry(
                role: .assistant,
                text: "Error: no active LangGraph session. Please try starting step-by-step execution again."
            )
            conversationStore.append(errorEntry)
            return
        }
        
        // Ensure both are set for consistency
        if currentLangGraphSessionId == nil || currentLangGraphSessionId!.isEmpty {
            currentLangGraphSessionId = sessionId
            logger.info("Restored sessionId from conversationStore: \(sessionId)")
        }
        if conversationStore.langGraphSessionId != sessionId {
            conversationStore.langGraphSessionId = sessionId
            logger.info("Updated conversationStore.langGraphSessionId: \(sessionId)")
        }
        
        logger.info("🔄 Handling step action: \(action), current step: \(self.conversationStore.currentStepIndex + 1)/\(self.conversationStore.totalSteps)")
        
        do {
            let response = try await langGraphClient.sendStepAction(
                action,
                sessionId: sessionId,
                screenshotURL: screenshotURL
            )
            
            logger.info("✅ Step response received: stepIndex=\(response.stepIndex), totalSteps=\(response.totalSteps), actionRequired=\(response.actionRequired ?? "nil")")
            
            // Update current step index and requires click status
            conversationStore.currentStepIndex = response.stepIndex
            conversationStore.currentStepRequiresClick = response.requiresClick
            conversationStore.totalSteps = response.totalSteps
            
            // Always add new entry for step navigation (even if text is similar, it's a different step)
            // Add step response to conversation
            let entry = ConversationEntry(
                role: .assistant,
                text: response.stepText
            )
            conversationStore.append(entry)
            
            // Update action_required
            conversationStore.actionRequired = response.actionRequired
            
            // If button coords are available, perform click
            if let buttonCoords = response.buttonCoords, response.requiresClick {
                let clickResult = await functionRouter.executeFunction(
                    name: "detect_button_click",
                    arguments: [
                        "x": buttonCoords.x,
                        "y": buttonCoords.y
                    ]
                )
                logger.info("Click result: \(clickResult)")
            }
            
            // Handle action_required
            if let actionRequired = response.actionRequired {
                handleActionRequired(actionRequired, response: LangGraphResponse(
                    response: response.stepText,
                    sessionId: sessionId,
                    mode: "step_by_step",
                    steps: nil,
                    actionRequired: actionRequired
                ))
                
                // If task completion choice, keep step-by-step mode active
                if actionRequired == "wait_task_completion_choice" {
                    // Keep mode active for Yes/No choice
                    logger.info("Waiting for task completion choice")
                }
            } else {
                // If no action required, we're done with all steps
                conversationStore.isStepByStepMode = false
                conversationStore.actionRequired = nil
                logger.info("All steps completed")
            }
            
        } catch {
            let errorMsg = error.localizedDescription
            logger.error("❌ Failed to handle step action: \(errorMsg, privacy: .public)")
            print("❌ Step action error: \(errorMsg)")
            
            // Show detailed error to user
            let entry = ConversationEntry(
                role: .assistant,
                text: "Error moving to next step: \(errorMsg)\n\nPlease try again or cancel the task."
            )
            conversationStore.append(entry)
        }
    }
    
    /// Show button location for current step (capture screenshot, analyze, show overlay)
    func showButtonForCurrentStep() async {
        guard let sessionId = currentLangGraphSessionId else {
            logger.error("No active LangGraph session")
            return
        }
        
        logger.info("📸 Capturing screenshot for button detection")
        
        do {
            // Capture Ableton screenshot
            let screenshotURL = try await AbletonScreenshotService.shared.captureAbletonWindow()
            
            // Get current step info from LangGraph
            let status = try await langGraphClient.getSessionStatus(sessionId)
            
            guard let stepInfo = status.currentStepInfo, stepInfo.requiresClick else {
                logger.warning("Current step does not require click")
                let entry = ConversationEntry(
                    role: .assistant,
                    text: "Current step does not require clicking a button."
                )
                conversationStore.append(entry)
                return
            }
            
            // Add screenshot to conversation
            let screenshotEntry = ConversationEntry(
                role: .system,
                text: "Screenshot taken to find button",
                screenshotURL: screenshotURL
            )
            conversationStore.append(screenshotEntry)
            
            // Send screenshot to LangGraph for button analysis
            // We'll use a special message that triggers analyze_screenshot node
            // The workflow will process the screenshot and return button coordinates
            let response = try await langGraphClient.sendMessage(
                "show_button",  // Special message to trigger analyze_screenshot (lowercase as in Python)
                edition: conversationStore.abletonEdition,
                history: conversationStore.entries,
                screenshotURL: screenshotURL,
                sessionId: sessionId
            )
            
            // Check if response contains button coordinates in steps
            if let steps = response.steps, !steps.isEmpty {
                let currentIndex = conversationStore.currentStepIndex
                if currentIndex < steps.count {
                    let currentStep = steps[currentIndex]
                    if let buttonCoords = currentStep.buttonCoords {
                        // Show overlay with button highlight
                        let rect = CGRect(
                            x: buttonCoords.x,
                            y: buttonCoords.y,
                            width: buttonCoords.width,
                            height: buttonCoords.height
                        )
                        let command = OverlayCommand(
                            type: .highlight(rect: rect),
                            caption: "Click here"
                        )
                        overlayController.render(commands: [command])
                        
                        logger.info("✅ Button found at (\(buttonCoords.x), \(buttonCoords.y))")
                        
                        let entry = ConversationEntry(
                            role: .assistant,
                            text: "Button found! See the highlight on screen."
                        )
                        conversationStore.append(entry)
                        return
                    }
                }
            }
            
            // If no coordinates yet, workflow is still processing
            let entry = ConversationEntry(
                role: .assistant,
                text: response.response
            )
            conversationStore.append(entry)
            
        } catch {
            logger.error("Failed to show button: \(error.localizedDescription)")
            let entry = ConversationEntry(
                role: .assistant,
                text: "Error finding button: \(error.localizedDescription)"
            )
            conversationStore.append(entry)
        }
    }

    /// Generate speech from text using TTS API
    func generateSpeech(from text: String) async {
        do {
            try await ttsService.generateAndPlay(text: text)
        } catch {
            logger.error("Failed to generate speech: \(error.localizedDescription)")
            let entry = ConversationEntry(
                role: .assistant,
                text: "⚠️ Failed to generate audio: \(error.localizedDescription)"
            )
            conversationStore.append(entry)
        }
    }
    
    /// Generate speech and return file URL for player
    func generateSpeechToFile(from text: String) async throws -> URL {
        return try await ttsService.generateSpeechToFile(text: text)
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

