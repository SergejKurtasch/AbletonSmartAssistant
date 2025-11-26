import Foundation
import OpenAI

final class EmbeddingHelper {
    private static let embeddingModel = "text-embedding-3-large"
    private static let embeddingDimension = 3072
    
    // Cache embeddings to avoid duplicate network calls
    private static var cache: [String: [Double]] = [:]
    private static let cacheQueue = DispatchQueue(label: "EmbeddingHelper.cache")
    
    static func embed(text: String) -> [Double] {
        // Return cached value if we already embedded this text
        if let cached = cacheQueue.sync(execute: { cache[text] }) {
            return cached
        }
        
        // Fall back to a deterministic stub when no API key is available
        guard let apiKey = EnvLoader.loadAPIKey(), !apiKey.isEmpty else {
            return createFallbackEmbedding(text: text)
        }
        
        // Create the embedding via the OpenAI API
        let client = OpenAI(apiToken: apiKey)
        
        // Use a semaphore to keep this API call synchronous
        let semaphore = DispatchSemaphore(value: 0)
        var result: [Double] = []
        
        Task {
            do {
                let embeddingsQuery = EmbeddingsQuery(
                    input: .string(text),
                    model: .textEmbedding3Large
                )
                let response = try await client.embeddings(query: embeddingsQuery)
                result = response.data.first?.embedding.map { Double($0) } ?? []
            } catch {
                result = createFallbackEmbedding(text: text)
            }
            semaphore.signal()
        }
        
        semaphore.wait()
        
        // Store the result in the cache
        if !result.isEmpty {
            cacheQueue.async {
                cache[text] = result
            }
        }
        
        return result
    }
    
    private static func createFallbackEmbedding(text: String) -> [Double] {
        // Stub implementation used when there is no API key configured
        // Match the dimensionality of text-embedding-3-large (3072)
        let words = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        
        var embedding = Array(repeating: 0.0, count: embeddingDimension)
        
        for word in words {
            let hash = abs(word.hashValue)
            let dim = hash % embeddingDimension
            embedding[dim] += 1.0 / Double(words.count)
        }
        
        // Normalize to unit length
        let magnitude = sqrt(embedding.map { $0 * $0 }.reduce(0, +))
        if magnitude > 0 {
            embedding = embedding.map { $0 / magnitude }
        }
        
        return embedding
    }
    
    static func clearCache() {
        cacheQueue.async {
            cache.removeAll()
        }
    }
}
