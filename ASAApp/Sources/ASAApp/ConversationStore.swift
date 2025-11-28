import Foundation
import SwiftUI

@MainActor
final class ConversationStore: ObservableObject {
    @Published var entries: [ConversationEntry] = []
    @Published var isListening: Bool = false
    @Published var isAutoCaptureEnabled: Bool = false
    @Published var selectedScreenshot: URL?
    @Published var isRealtimeActive: Bool = false
    @AppStorage("abletonEdition") var abletonEdition: AbletonEdition = .suite

    func append(_ entry: ConversationEntry) {
        entries.append(entry)
    }

    func clear() {
        entries = []
    }
}

