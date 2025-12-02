import Foundation

/// Response from LangGraph /chat endpoint
struct LangGraphResponse: Codable {
    let response: String
    let sessionId: String
    let mode: String  // "simple" | "step_by_step"
    let steps: [Step]?
    let actionRequired: String?  // "wait_version_choice" | "wait_step_choice" | "wait_user_action" | "wait_task_completion_choice"
}

/// Step in step-by-step mode
struct Step: Codable {
    let text: String
    let requiresClick: Bool
    let buttonCoords: ButtonCoords?
}

/// Button coordinates from vision analysis
struct ButtonCoords: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// Response from LangGraph /step endpoint
struct StepResponse: Codable {
    let stepText: String
    let stepIndex: Int
    let totalSteps: Int
    let requiresClick: Bool
    let buttonCoords: ButtonCoords?
    let actionRequired: String?
}

/// Response from LangGraph /step/validate endpoint
struct ValidationResponse: Codable {
    let valid: Bool
    let explanation: String?
}

/// Response from LangGraph /session/{session_id}/status endpoint
struct SessionStatus: Codable {
    let mode: String
    let currentStep: Int?
    let totalSteps: Int?
    let currentStepInfo: Step?
}

/// Request for /chat endpoint
struct ChatRequest: Codable {
    let message: String
    let sessionId: String?
    let history: [ConversationEntryRequest]
    let abletonEdition: String
    let screenshotUrl: String?
}

/// Conversation entry for request
struct ConversationEntryRequest: Codable {
    let role: String
    let text: String
    let screenshotUrl: String?
}

/// Request for /step endpoint
struct StepRequest: Codable {
    let sessionId: String
    let userAction: String
    let screenshotUrl: String?
}

/// Request for /step/validate endpoint
struct ValidateStepRequest: Codable {
    let sessionId: String
    let screenshotUrl: String
    let stepIndex: Int
}

/// Request for /chat/step-by-step endpoint
struct StepByStepRequest: Codable {
    let message: String
    let ragAnswer: String
    let sessionId: String?
    let history: [ConversationEntryRequest]
    let abletonEdition: String
    let screenshotUrl: String?
}

