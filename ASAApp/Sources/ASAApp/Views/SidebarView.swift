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
            TextEditor(text: $userInput)
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary, lineWidth: 1))
                .disabled(isTranscribing)

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
                .disabled(isTranscribing || isSending)
                .help(store.isRecording ? "Stop recording" : "Start voice input")
                
                Spacer()
                
                Button(action: sendMessage) {
                    if isSending {
                        ProgressView()
                    } else {
                        Text("Send")
                    }
                }
                .disabled(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || isTranscribing)
            }
        }
    }

    private func sendMessage() {
        guard !userInput.isEmpty else { return }
        
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

