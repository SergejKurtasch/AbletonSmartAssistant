import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: ConversationStore
    let assistantSession: AssistantSession
    let audioPipeline: AudioPipeline
    @AppStorage("abletonEdition") private var editionRaw: String = AbletonEdition.suite.rawValue

    @State private var userInput: String = ""
    @State private var isSending: Bool = false
    @State private var statusMessage: String = ""
    @State private var voiceToTextService: VoiceToTextService?
    @State private var isTranscribing: Bool = false
    @State private var activePlayerEntryId: UUID? = nil
    @State private var playerAudioURL: URL? = nil

    var body: some View {
        VStack(spacing: 12) {
            header
            conversationList
            inputArea
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor))
        .frame(minWidth: 360)
        .onAppear {
            assistantSession.updateAutoCapture(isEnabled: store.isAutoCaptureEnabled)
            // Initialize VoiceToTextService
            if let apiKey = EnvLoader.loadAPIKey(), !apiKey.isEmpty {
                voiceToTextService = VoiceToTextService(apiKey: apiKey, audioPipeline: audioPipeline)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ableton Smart Assistant")
                .font(.title3)
                .fontWeight(.semibold)

            Picker("Live edition", selection: $store.abletonEdition) {
                ForEach(AbletonEdition.allCases) { edition in
                    Text(edition.rawValue).tag(edition)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: store.abletonEdition) { newValue in
                editionRaw = newValue.rawValue
            }
            
            Picker("Speech Recognition", selection: $store.speechRecognitionLanguage) {
                ForEach(SpeechRecognitionLanguage.allCases) { language in
                    Text(language.rawValue).tag(language)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 12) {
                Button("Take Screenshot") {
                    assistantSession.captureManualScreenshot()
                }

                Toggle("Auto-click Capture", isOn: $store.isAutoCaptureEnabled)
                    .toggleStyle(.switch)
                    .onChange(of: store.isAutoCaptureEnabled) { enabled in
                        assistantSession.updateAutoCapture(isEnabled: enabled)
                    }
            }
            
            // Status message
            if !statusMessage.isEmpty {
                HStack {
                    if store.isRecording {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                    }
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var conversationList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.entries) { entry in
                        conversationRow(entry)
                            .id(entry.id)
                    }
                }
                .onChange(of: store.entries.count) { _ in
                    if let lastID = store.entries.last?.id {
                        withAnimation {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func conversationRow(_ entry: ConversationEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.role == .user ? "You" : "ASA")
                    .fontWeight(.medium)
                Spacer()
                Text(entry.createdAt, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(entry.text)
                .font(.body)

            if let screenshotURL = entry.screenshotURL {
                ScreenshotThumbnail(url: screenshotURL) {
                    store.selectedScreenshot = screenshotURL
                }
            }
            
            // Audio player for assistant responses
            if entry.role == .assistant {
                if activePlayerEntryId == entry.id {
                    // Show player
                    AudioPlayerView(ttsService: assistantSession.ttsService)
                        .onChange(of: assistantSession.ttsService.isPlaying) { isPlaying in
                            if !isPlaying && assistantSession.ttsService.currentTime == 0 {
                                // Playback finished or stopped, hide player
                                if let url = playerAudioURL {
                                    try? FileManager.default.removeItem(at: url)
                                }
                                activePlayerEntryId = nil
                                playerAudioURL = nil
                            }
                        }
                        .onDisappear {
                            // Clean up when view disappears
                            if let url = playerAudioURL {
                                try? FileManager.default.removeItem(at: url)
                            }
                        }
                } else {
                    // Show play button at the end
                    HStack {
                        Spacer()
                        Button(action: {
                            Task {
                                await loadAndShowPlayer(for: entry)
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "speaker.wave.2.fill")
                                Text("Play audio")
                            }
                            .font(.caption)
                            .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                // Show step-by-step controls if needed
                // Only show buttons on the last assistant entry to avoid showing buttons in old messages
                let isLastAssistantEntry = entry.id == store.entries.last(where: { $0.role == .assistant })?.id
                
                if store.actionRequired == "offer_step_by_step" && isLastAssistantEntry {
                    offerStepByStepButton
                } else if store.actionRequired == "wait_step_choice" && isLastAssistantEntry {
                    stepChoiceButtons
                } else if store.actionRequired == "wait_user_action" && store.isStepByStepMode && isLastAssistantEntry {
                    stepNavigationButtons
                } else if store.actionRequired == "wait_task_completion_choice" && store.isStepByStepMode && isLastAssistantEntry {
                    taskCompletionButtons
                } else if store.actionRequired == "wait_version_choice" && isLastAssistantEntry {
                    versionChoiceButtons
                }
            }
        }
        .padding(12)
        .background(entry.role == .user ? Color.accentColor.opacity(0.08) : Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
    
    private func loadAndShowPlayer(for entry: ConversationEntry) async {
        // Stop any current playback
        if activePlayerEntryId != nil {
            assistantSession.ttsService.stopPlayback()
        }
        
        // Generate audio and load into player
        do {
            let audioURL = try await assistantSession.generateSpeechToFile(from: entry.text)
            try assistantSession.ttsService.loadAudio(from: audioURL)
            activePlayerEntryId = entry.id
            playerAudioURL = audioURL
        } catch {
            statusMessage = "⚠️ Failed to generate audio: \(error.localizedDescription)"
        }
    }

    private var inputArea: some View {
        VStack(spacing: 8) {
            // Step progress indicator
            if store.isStepByStepMode && store.totalSteps > 0 {
                HStack {
                    Text("Step \(store.currentStepIndex + 1) of \(store.totalSteps)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    ProgressView(value: Double(store.currentStepIndex + 1), total: Double(store.totalSteps))
                        .frame(width: 100)
                }
                .padding(.horizontal, 4)
            }
            
            TextEditor(text: $userInput)
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary, lineWidth: 1))
                .disabled(isTranscribing || (store.isStepByStepMode && store.actionRequired == "wait_user_action"))

            HStack {
                Button("Attach Screenshot") {
                    assistantSession.importScreenshot()
                }
                
                // Microphone button
                Button(action: toggleRecording) {
                    Image(systemName: "mic.fill")
                        .foregroundColor(store.isRecording ? .red : .blue)
                        .font(.system(size: 18))
                }
                .buttonStyle(.bordered)
                .disabled(isTranscribing || isSending || (store.isStepByStepMode && store.actionRequired == "wait_user_action"))
                .help(store.isRecording ? "Stop recording" : "Start voice input")
                
                Spacer()
                
                Button(action: sendMessage) {
                    if isSending {
                        ProgressView()
                    } else {
                        Text("Send")
                    }
                }
                .disabled(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || isTranscribing || (store.isStepByStepMode && store.actionRequired == "wait_user_action"))
            }
        }
    }
    
    private var offerStepByStepButton: some View {
        HStack {
            Spacer()
            Button(action: {
                Task {
                    await startStepByStepMode()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "list.number")
                    Text("Start step-by-step execution")
                }
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(.top, 8)
    }
    
    private var stepChoiceButtons: some View {
        HStack(spacing: 8) {
            Button("Show step-by-step") {
                Task {
                    await handleStepChoice(choice: "yes")
                }
            }
            .buttonStyle(.borderedProminent)
            
            Button("No, thanks") {
                Task {
                    await handleStepChoice(choice: "no")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 8)
    }
    
    private func startStepByStepMode() async {
        // Add text message to chat indicating step-by-step mode is starting
        let startingEntry = ConversationEntry(
            role: .user,
            text: "Start step-by-step execution"
        )
        store.append(startingEntry)
        
        // Remove the button from the previous message by clearing actionRequired
        store.actionRequired = nil
        
        guard let lastQuery = store.lastUserQuery else {
            // Try to get query from last user message (excluding our new "Start step-by-step execution" message)
            if let lastUserEntry = store.entries.filter({ $0.role == .user }).dropLast().last {
                store.lastUserQuery = lastUserEntry.text
                // Get the last assistant answer (RAG answer) - the one with full instructions
                // Find the assistant message that is long enough and doesn't contain the step choice question
                let lastRAGAnswer = store.entries.last(where: { 
                    $0.role == .assistant && 
                    $0.text.count > 200 && 
                    !$0.text.contains("Would you like me to show this step-by-step")
                })?.text
                
                print("DEBUG: Starting step-by-step with query: \(lastUserEntry.text.prefix(50))")
                print("DEBUG: RAG answer length: \(lastRAGAnswer?.count ?? 0)")
                
                await assistantSession.startStepByStepMode(
                    for: lastUserEntry.text,
                    edition: store.abletonEdition,
                    withRAGAnswer: lastRAGAnswer
                )
            }
            return
        }
        
        // Get the last assistant answer (RAG answer) - the one with full instructions
        // Find the assistant message that is long enough and doesn't contain the step choice question
        let lastRAGAnswer = store.entries.last(where: { 
            $0.role == .assistant && 
            $0.text.count > 200 && 
            !$0.text.contains("Would you like me to show this step-by-step")
        })?.text
        
        print("DEBUG: Starting step-by-step with query: \(lastQuery.prefix(50))")
        print("DEBUG: RAG answer length: \(lastRAGAnswer?.count ?? 0)")
        
        await assistantSession.startStepByStepMode(
            for: lastQuery,
            edition: store.abletonEdition,
            withRAGAnswer: lastRAGAnswer
        )
    }
    
    private var stepNavigationButtons: some View {
        VStack(spacing: 8) {
            // Show "Show the button" button if current step requires click
            if store.currentStepRequiresClick {
                Button(action: {
                    Task {
                        await assistantSession.showButtonForCurrentStep()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.point.up.left.fill")
                        Text("Show the button")
                    }
                }
                .buttonStyle(.bordered)
                .foregroundColor(.blue)
            }
            
            HStack(spacing: 8) {
                Button("Next step") {
                    Task {
                        await handleStepAction("next")
                    }
                }
                .buttonStyle(.borderedProminent)
                
                Button("Cancel task") {
                    Task {
                        await handleStepAction("cancel")
                    }
                }
                .buttonStyle(.bordered)
                .foregroundColor(.red)
            }
        }
        .padding(.top, 8)
    }
    
    private var taskCompletionButtons: some View {
        HStack(spacing: 8) {
            Button("Yes") {
                Task {
                    await handleStepAction("yes")
                }
            }
            .buttonStyle(.borderedProminent)
            
            Button("No") {
                Task {
                    await handleStepAction("no")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 8)
    }
    
    private var versionChoiceButtons: some View {
        HStack(spacing: 8) {
            Button("Try anyway") {
                Task {
                    await handleVersionChoice(choice: "Try anyway")
                }
            }
            .buttonStyle(.borderedProminent)
            
            Button("Formulate new task") {
                Task {
                    await handleVersionChoice(choice: "Formulate a new task")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.top, 8)
    }
    
    private func handleStepChoice(choice: String) async {
        let choiceLower = choice.lowercased()
        
        // If user chose "no", just clear the action and don't start step-by-step mode
        if choiceLower.contains("no") || choiceLower.contains("thanks") || choiceLower.contains("thank you") {
            store.actionRequired = nil
            // Add a simple acknowledgment message
            let entry = ConversationEntry(
                role: .assistant,
                text: "Okay, feel free to ask if you need help!"
            )
            store.append(entry)
            return
        }
        
        // User chose "yes" - start step-by-step mode with existing RAG answer
        guard let lastQuery = store.lastUserQuery else {
            // Try to get query from last user message
            if let lastUserEntry = store.entries.last(where: { $0.role == .user && $0.text != "Start step-by-step execution" && !$0.text.lowercased().contains("yes") && !$0.text.lowercased().contains("show") }) {
                store.lastUserQuery = lastUserEntry.text
                // Get the last assistant answer (RAG answer) - the one with the full instructions
                let lastRAGAnswer = store.entries.last(where: { $0.role == .assistant && $0.text.count > 100 })?.text
                await assistantSession.startStepByStepMode(
                    for: lastUserEntry.text,
                    edition: store.abletonEdition,
                    withRAGAnswer: lastRAGAnswer
                )
            }
            return
        }
        
        // Get the last assistant answer (RAG answer) - the one with the full instructions
        // Find the assistant message that has the full answer (not the "wait_step_choice" message)
        let lastRAGAnswer = store.entries.last(where: { 
            $0.role == .assistant && 
            $0.text.count > 100 && 
            !$0.text.contains("Would you like me to show this step-by-step")
        })?.text
        
        await assistantSession.startStepByStepMode(
            for: lastQuery,
            edition: store.abletonEdition,
            withRAGAnswer: lastRAGAnswer
        )
    }
    
    private func handleStepAction(_ action: String) async {
        guard let sessionId = store.langGraphSessionId else { return }
        
        let lastScreenshot = store.entries.last(where: { $0.screenshotURL != nil })?.screenshotURL
        
        await assistantSession.handleStepAction(action, screenshotURL: lastScreenshot)
        
        // State is already updated in handleStepAction, but we need to handle cancel case
        if action == "cancel" {
            store.isStepByStepMode = false
            store.actionRequired = nil
        }
    }
    
    private func handleVersionChoice(choice: String) async {
        guard let sessionId = store.langGraphSessionId else { return }
        
        let lastScreenshot = store.entries.last(where: { $0.screenshotURL != nil })?.screenshotURL
        
        do {
            // Use /chat endpoint to continue workflow, not /step
            // The workflow will process the choice and continue to retrieve if needed
            let response = try await LangGraphClient().sendMessage(
                choice,
                edition: store.abletonEdition,
                history: store.entries,
                screenshotURL: lastScreenshot,
                sessionId: sessionId
            )
            
            // Update store state
            store.actionRequired = response.actionRequired
            if response.mode == "step_by_step" {
                store.isStepByStepMode = true
                if let steps = response.steps {
                    store.totalSteps = steps.count
                    store.currentStepIndex = 0
                }
            }
            
            // Add response to conversation
            let entry = ConversationEntry(
                role: .assistant,
                text: response.response
            )
            store.append(entry)
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func sendMessage() {
        guard !userInput.isEmpty else { return }
        
        // Store query for potential step-by-step mode
        store.lastUserQuery = userInput
        
        // Use HTTP API
        let entry = ConversationEntry(role: .user, text: userInput)
        store.append(entry)
        isSending = true

        Task {
            defer { Task { @MainActor in
                self.isSending = false
                self.userInput = ""
            }}

            await assistantSession.handleUserText(
                userInput,
                edition: store.abletonEdition,
                autoCapture: store.isAutoCaptureEnabled
            )
        }
    }
    
    private func toggleRecording() {
        if store.isRecording {
            // Stop recording and transcribe
            stopRecordingAndTranscribe()
        } else {
            // Start recording
            startRecording()
        }
    }
    
    private func startRecording() {
        guard let service = voiceToTextService else {
            statusMessage = "⚠️ Voice input not available. Check API key."
            return
        }
        
        do {
            try service.startRecording()
            statusMessage = "Recording... Tap microphone to stop"
            store.isRecording = true
        } catch {
            statusMessage = "⚠️ Failed to start recording: \(error.localizedDescription)"
            store.isRecording = false
        }
    }
    
    private func stopRecordingAndTranscribe() {
        guard let service = voiceToTextService else { return }
        
        store.isRecording = false
        statusMessage = "Transcribing..."
        isTranscribing = true
        
        Task {
            do {
                let transcribedText = try await service.stopAndTranscribe(language: store.speechRecognitionLanguage)
                await MainActor.run {
                    userInput = transcribedText
                    statusMessage = ""
                    isTranscribing = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = "⚠️ Transcription failed: \(error.localizedDescription)"
                    isTranscribing = false
                }
            }
        }
    }
}

struct ScreenshotThumbnail: View {
    let url: URL
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .overlay(Text("Preview unavailable").font(.caption))
            }
        }
        .buttonStyle(.plain)
    }
}

