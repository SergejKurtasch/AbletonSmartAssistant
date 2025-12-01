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
    
    // Text-to-Speech service
    let ttsService: TextToSpeechService

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
        // Use HTTP API
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

