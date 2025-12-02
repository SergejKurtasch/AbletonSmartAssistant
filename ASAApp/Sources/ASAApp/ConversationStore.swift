import Foundation
import SwiftUI

@MainActor
final class ConversationStore: ObservableObject {
    @Published var entries: [ConversationEntry] = []
    @Published var isListening: Bool = false
    @Published var isAutoCaptureEnabled: Bool = false
    @Published var selectedScreenshot: URL?
    @Published var isRealtimeActive: Bool = false
    @Published var isRecording: Bool = false
    @AppStorage("abletonEdition") var abletonEdition: AbletonEdition = .suite
    @AppStorage("speechRecognitionLanguage") var speechRecognitionLanguage: SpeechRecognitionLanguage = .auto
    
    // LangGraph step-by-step mode state
    @Published var isStepByStepMode: Bool = false
    @Published var currentStepIndex: Int = 0
    @Published var totalSteps: Int = 0
    @Published var actionRequired: String? = nil  // "wait_version_choice" | "wait_step_choice" | "wait_user_action" | "wait_task_completion_choice" | "offer_step_by_step"
    @Published var langGraphSessionId: String? = nil
    @Published var lastUserQuery: String? = nil  // Store last query for step-by-step mode
    @Published var currentStepRequiresClick: Bool = false  // Whether current step requires click

    func append(_ entry: ConversationEntry) {
        entries.append(entry)
    }

    func clear() {
        entries = []
    }
}

enum SpeechRecognitionLanguage: String, CaseIterable, Codable, Identifiable {
    case auto = "Auto"
    case english = "English"
    
    var id: String { rawValue }
    
    var whisperLanguageCode: String? {
        switch self {
        case .auto:
            return nil // Auto-detect
        case .english:
            return "en"
        }
    }
}

