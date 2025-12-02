import Foundation
import OSLog

/// HTTP client for interacting with LangGraph Python server
@MainActor
final class LangGraphClient {
    private let logger = Logger(subsystem: "ASAApp", category: "LangGraphClient")
    private let baseURL: String
    private let session: URLSession
    
    init(baseURL: String = "http://localhost:8000") {
        self.baseURL = baseURL
        self.session = URLSession.shared
    }
    
    /// Send a chat message to LangGraph server
    func sendMessage(
        _ text: String,
        edition: AbletonEdition,
        history: [ConversationEntry],
        screenshotURL: URL?,
        sessionId: String?
    ) async throws -> LangGraphResponse {
        let url = URL(string: "\(baseURL)/chat")!
        
            // Convert conversation history to request format
            let historyEntries = history.map { entry in
                ConversationEntryRequest(
                    role: entry.role.rawValue,
                    text: entry.text,
                    screenshotUrl: entry.screenshotURL?.path
                )
            }
            
            logger.info("📤 Request: message='\(text.prefix(50))', edition=\(edition.rawValue), history_count=\(historyEntries.count), sessionId=\(sessionId ?? "nil")")
        
        let request = ChatRequest(
            message: text,
            sessionId: sessionId,
            history: historyEntries,
            abletonEdition: edition.rawValue,
            screenshotUrl: screenshotURL?.path
        )
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        urlRequest.httpBody = try encoder.encode(request)
        
        logger.info("Sending chat request to LangGraph server")
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LangGraphError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("LangGraph server error: \(errorMessage)")
            throw LangGraphError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LangGraphResponse.self, from: data)
    }
    
    /// Send step action in step-by-step mode
    func sendStepAction(
        _ action: String,
        sessionId: String,
        screenshotURL: URL?
    ) async throws -> StepResponse {
        let url = URL(string: "\(baseURL)/step")!
        
        let request = StepRequest(
            sessionId: sessionId,
            userAction: action,
            screenshotUrl: screenshotURL?.path
        )
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        urlRequest.httpBody = try encoder.encode(request)
        
        logger.info("📤 Sending step action: action=\(action), sessionId=\(sessionId)")
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            logger.error("❌ Invalid response type")
            throw LangGraphError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("❌ LangGraph server error (\(httpResponse.statusCode)): \(errorMessage)")
            throw LangGraphError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        let stepResponse = try decoder.decode(StepResponse.self, from: data)
        logger.info("✅ Step response decoded: stepIndex=\(stepResponse.stepIndex), totalSteps=\(stepResponse.totalSteps), stepText length=\(stepResponse.stepText.count)")
        
        return stepResponse
    }
    
    /// Validate a step completion
    func validateStep(
        sessionId: String,
        screenshotURL: URL,
        stepIndex: Int
    ) async throws -> ValidationResponse {
        let url = URL(string: "\(baseURL)/step/validate")!
        
        let request = ValidateStepRequest(
            sessionId: sessionId,
            screenshotUrl: screenshotURL.path,
            stepIndex: stepIndex
        )
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        urlRequest.httpBody = try encoder.encode(request)
        
        logger.info("Validating step with LangGraph server")
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LangGraphError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("LangGraph server error: \(errorMessage)")
            throw LangGraphError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ValidationResponse.self, from: data)
    }
    
    /// Start step-by-step mode with existing RAG answer (skips nodes 1-4)
    func startStepByStepWithAnswer(
        query: String,
        ragAnswer: String,
        edition: AbletonEdition,
        history: [ConversationEntry],
        screenshotURL: URL?,
        sessionId: String?
    ) async throws -> LangGraphResponse {
        let url = URL(string: "\(baseURL)/chat/step-by-step")!
        
        // Convert conversation history to request format
        let historyEntries = history.map { entry in
            ConversationEntryRequest(
                role: entry.role.rawValue,
                text: entry.text,
                screenshotUrl: entry.screenshotURL?.path
            )
        }
        
        logger.info("📤 Step-by-step request: query='\(query.prefix(50))', ragAnswer_length=\(ragAnswer.count), edition=\(edition.rawValue), sessionId=\(sessionId ?? "nil")")
        
        let request = StepByStepRequest(
            message: query,
            ragAnswer: ragAnswer,
            sessionId: sessionId,
            history: historyEntries,
            abletonEdition: edition.rawValue,
            screenshotUrl: screenshotURL?.path
        )
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        urlRequest.httpBody = try encoder.encode(request)
        
        logger.info("Sending step-by-step request to LangGraph server")
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LangGraphError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("LangGraph server error: \(errorMessage)")
            throw LangGraphError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        // Log raw response for debugging
        if let responseString = String(data: data, encoding: .utf8) {
            logger.info("📥 Raw response from /chat/step-by-step: \(responseString.prefix(500))")
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decodedResponse = try decoder.decode(LangGraphResponse.self, from: data)
        logger.info("✅ Decoded response: sessionId=\(decodedResponse.sessionId), mode=\(decodedResponse.mode), steps_count=\(decodedResponse.steps?.count ?? 0)")
        return decodedResponse
    }
    
    /// Get session status
    func getSessionStatus(_ sessionId: String) async throws -> SessionStatus {
        let url = URL(string: "\(baseURL)/session/\(sessionId)/status")!
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        
        logger.info("Getting session status from LangGraph server")
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LangGraphError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("LangGraph server error: \(errorMessage)")
            throw LangGraphError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(SessionStatus.self, from: data)
    }
}

enum LangGraphError: LocalizedError {
    case invalidResponse
    case serverError(statusCode: Int, message: String)
    case decodingError
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from LangGraph server"
        case .serverError(let statusCode, let message):
            return "LangGraph server error (\(statusCode)): \(message)"
        case .decodingError:
            return "Failed to decode response from LangGraph server"
        }
    }
}

