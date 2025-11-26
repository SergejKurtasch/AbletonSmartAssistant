import SwiftUI
import AppKit

@main
struct ASAApp: App {
    @StateObject private var conversationStore = ConversationStore()
    @State private var showOnboarding = false
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    private let ragStore = RAGStore.shared
    private let audioPipeline = AudioPipeline()
    
    init() {
        // Force the app to show up like a regular macOS app
        NSApplication.shared.setActivationPolicy(.regular)
    }

    private var assistantSession: AssistantSession {
        AssistantSession(
            ragStore: ragStore,
            conversationStore: conversationStore,
            audioPipeline: audioPipeline
        )
    }

    var body: some Scene {
        WindowGroup {
            SidebarView(
                store: conversationStore,
                assistantSession: assistantSession,
                audioPipeline: audioPipeline
            )
            .sheet(isPresented: $showOnboarding) {
                OnboardingView(
                    isPresented: $showOnboarding,
                    selectedEdition: $conversationStore.abletonEdition
                )
            }
            .onAppear {
                // Bring the app to the foreground when the first window appears
                NSApplication.shared.activate(ignoringOtherApps: true)
                
                if !hasCompletedOnboarding {
                    showOnboarding = true
                    hasCompletedOnboarding = true
                }
            }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 400, height: 800)
        .commands {
            // Replace the default About panel with a custom entry
            CommandGroup(replacing: .appInfo) {
                Button("About ASAApp") {
                    NSApplication.shared.orderFrontStandardAboutPanel()
                }
            }
        }
    }
}
