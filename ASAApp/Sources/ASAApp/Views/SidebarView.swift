import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: ConversationStore
    let assistantSession: AssistantSession
    let audioPipeline: AudioPipeline
    @AppStorage("abletonEdition") private var editionRaw: String = AbletonEdition.suite.rawValue

    @State private var userInput: String = ""
    @State private var isSending: Bool = false
    @State private var statusMessage: String = ""

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
        }
        .onChange(of: store.isListening) { _ in
            updateStatusMessage()
        }
        .onChange(of: store.isRealtimeActive) { _ in
            updateStatusMessage()
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

            HStack(spacing: 12) {
                Button(store.isRealtimeActive ? "🎙 Stop Voice Assistant" : "🎙 Start Voice Assistant") {
                    toggleVoiceAssistant()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSending)

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
                    if store.isListening {
                        Circle()
                            .fill(Color.green)
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
        }
        .padding(12)
        .background(entry.role == .user ? Color.accentColor.opacity(0.08) : Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var inputArea: some View {
        VStack(spacing: 8) {
            TextEditor(text: $userInput)
                .frame(minHeight: 80)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary, lineWidth: 1))

            HStack {
                Button("Attach Screenshot") {
                    assistantSession.importScreenshot()
                }
                Spacer()
                Button(action: sendMessage) {
                    if isSending {
                        ProgressView()
                    } else {
                        Text("Send")
                    }
                }
                .disabled(userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
    }

    private func sendMessage() {
        guard !userInput.isEmpty else { return }
        
        // If Realtime is active, send through it
        if store.isRealtimeActive {
            Task {
                await assistantSession.handleUserText(
                    userInput,
                    edition: store.abletonEdition,
                    autoCapture: store.isAutoCaptureEnabled
                )
                await MainActor.run {
                    userInput = ""
                }
            }
            return
        }
        
        // Otherwise, use HTTP API
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

    private func toggleVoiceAssistant() {
        if store.isRealtimeActive {
            assistantSession.stopRealtimeSession()
            statusMessage = ""
        } else {
            assistantSession.startRealtimeSession()
            updateStatusMessage()
        }
    }
    
    private func updateStatusMessage() {
        if store.isRealtimeActive {
            if store.isListening {
                statusMessage = "Assistant is listening..."
            } else {
                statusMessage = "Processing..."
            }
        } else {
            statusMessage = ""
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

