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

