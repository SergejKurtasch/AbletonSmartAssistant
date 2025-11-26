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
        Task {
            guard !chunk.isEmpty else { return }
            // Placeholder: send chunk into realtime stream
            logger.debug("Received audio chunk length \(chunk.count)")
        }
    }

    func updateAutoCapture(isEnabled: Bool) {
        if isEnabled {
            ClickMonitor.shared.start { [weak self] location in
                guard let self else { return }
                Task.detached {
                    do {
                        let url = try await ScreenshotManager.shared.captureRegion(around: location)
                        await MainActor.run {
                            let entry = ConversationEntry(
                                role: .system,
                                text: "Click captured at (\(Int(location.x)), \(Int(location.y))).",
                                screenshotURL: url
                            )
                            self.conversationStore.append(entry)
                            self.renderPulse(at: location)
                        }
                    } catch {
                        await MainActor.run {
                            self.conversationStore.append(
                                ConversationEntry(role: .assistant, text: "Failed to capture a screenshot for that click.")
                            )
                        }
                    }
                }
            }
        } else {
            ClickMonitor.shared.stop()
        }
    }

    private func renderPulse(at point: CGPoint) {
        let command = OverlayCommand(type: .pulse(center: point, radius: 60), caption: "Click")
        overlayController.render(commands: [command])
    }

    func captureManualScreenshot() {
        ScreenshotManager.shared.captureFullAbletonWindow { result in
            switch result {
            case .success(let url):
                let entry = ConversationEntry(role: .system, text: "Screenshot saved", screenshotURL: url)
                Task { @MainActor in self.conversationStore.append(entry) }
            case .failure(let error):
                Task { @MainActor in
                    self.conversationStore.append(
                        ConversationEntry(role: .assistant, text: "Screenshot error: \(error.localizedDescription)")
                    )
                }
            }
        }
    }

    func importScreenshot() {
        ScreenshotManager.shared.importScreenshot { url in
            guard let url else { return }
            let entry = ConversationEntry(role: .system, text: "Screenshot imported", screenshotURL: url)
            Task { @MainActor in self.conversationStore.append(entry) }
        }
    }
}

