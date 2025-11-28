import Foundation

enum ConversationRole: String, Codable {
    case user
    case assistant
    case system
}

struct ConversationEntry: Identifiable, Codable {
    let id: UUID
    let role: ConversationRole
    let text: String
    let screenshotURL: URL?
    let audioURL: URL?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: ConversationRole,
        text: String,
        screenshotURL: URL? = nil,
        audioURL: URL? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.screenshotURL = screenshotURL
        self.audioURL = audioURL
        self.createdAt = createdAt
    }
}

enum AbletonEdition: String, CaseIterable, Codable, Identifiable {
    case suite = "Ableton Live Suite"
    case standard = "Ableton Live Standard"
    case intro = "Ableton Live Intro"
    case lite = "Ableton Live Lite"

    var id: String { rawValue }
}

