import Foundation

struct RAGContext {
    let systemPrompt: String
    let userContext: String

    func userAugmentedPrompt(with query: String) -> String {
        """
        \(query)

        ---
        Context:
        \(userContext)
        """
    }
}

final class RAGStore {
    static let shared = RAGStore()

    private struct Chunk: Codable {
        let id: String
        let content: String
        let edition: String?
        let embedding: [Double]
        let metadata: ChunkMetadata?
    }
    
    private struct ChunkMetadata: Codable {
        let title: String?
        let page: Int?
        let chapter: String?
        let sections: Int?
    }

    private var fullIndex: [Chunk] = []
    private var liteDiffIndex: [Chunk] = []
    private let queue = DispatchQueue(label: "RAGStore.queue", qos: .userInitiated)

    private init() {
        loadIndexes()
    }

    private func loadIndexes() {
        // Locate the data folder relative to the binary or the project root
        var dataURL: URL?
        
        // 1. Check the environment variable override first
        if let envPath = ProcessInfo.processInfo.environment["ASA_DATA_DIR"] {
            dataURL = URL(fileURLWithPath: envPath)
        }
        
        // 2. Walk up from the current working directory
        if dataURL == nil {
            let currentDir = FileManager.default.currentDirectoryPath
            var searchDir = URL(fileURLWithPath: currentDir)
            // Walk upward toward the supposed project root
            for _ in 0..<10 { // Keep the search bounded
                let candidate = searchDir.appendingPathComponent("data")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    dataURL = candidate
                    break
                }
                let parent = searchDir.deletingLastPathComponent()
                if parent.path == searchDir.path { break }
                searchDir = parent
            }
        }
        
        // 3. As a last resort, try the absolute development path
        if dataURL == nil {
            let fallbackPath = "/Users/sergej/Library/Mobile Documents/com~apple~CloudDocs/DS_AI/python_projects/AI_assistant/data"
            if FileManager.default.fileExists(atPath: fallbackPath) {
                dataURL = URL(fileURLWithPath: fallbackPath)
            }
        }
        
        guard let baseURL = dataURL else {
            print("Warning: RAG data directory not found. Please set ASA_DATA_DIR environment variable or place data/ folder in project root.")
            return
        }
        
        let decoder = JSONDecoder()
        if let fullData = try? Data(contentsOf: baseURL.appendingPathComponent("AbletonFullIndex.json")),
           let chunks = try? decoder.decode([Chunk].self, from: fullData) {
            fullIndex = chunks
            print("Loaded \(chunks.count) chunks from AbletonFullIndex.json")
        }
        if let liteData = try? Data(contentsOf: baseURL.appendingPathComponent("AbletonLiteDiffIndex.json")),
           let chunks = try? decoder.decode([Chunk].self, from: liteData) {
            liteDiffIndex = chunks
            print("Loaded \(chunks.count) chunks from AbletonLiteDiffIndex.json")
        }
    }

    func retrieve(for query: String, edition: AbletonEdition, topK: Int = 3) -> RAGContext {
        let queryEmbedding = EmbeddingHelper.embed(text: query)
        let full = topMatches(in: fullIndex, queryEmbedding: queryEmbedding, topK: topK)

        var liteContext = ""
        if edition == .lite {
            let lite = topMatches(in: liteDiffIndex, queryEmbedding: queryEmbedding, topK: 2)
            liteContext = lite.map(\.content).joined(separator: "\n---\n")
        }

        // Build the context string with metadata annotations
        let baseChunks = full.map { chunk -> String in
            var text = chunk.content
            if let metadata = chunk.metadata {
                var metaParts: [String] = []
                if let title = metadata.title {
                    metaParts.append("Section: \(title)")
                }
                if let page = metadata.page {
                    metaParts.append("Page: \(page)")
                }
                if let chapter = metadata.chapter {
                    metaParts.append("Chapter: \(chapter)")
                }
                if !metaParts.isEmpty {
                    text = "[\(metaParts.joined(separator: ", "))]\n\n\(text)"
                }
            }
            return text
        }
        
        let base = baseChunks.joined(separator: "\n\n---\n\n")
        
        let systemPrompt = """
        You are Ableton Smart Assistant. Reference Ableton documentation snippets when answering.
        If the snippet mentions that a feature is unavailable for the user's edition, provide a workaround.
        When referencing documentation, you can mention the section name and page number if available.
        User's edition: \(edition.rawValue)
        """

        let userContext: String
        if liteContext.isEmpty {
            userContext = base
        } else {
            userContext = """
            Documentation:
            \(base)

            Lite Restrictions:
            \(liteContext)
            """
        }

        return RAGContext(systemPrompt: systemPrompt, userContext: userContext)
    }

    private func topMatches(in chunks: [Chunk], queryEmbedding: [Double], topK: Int) -> [Chunk] {
        let scored = chunks.map { chunk -> (Chunk, Double) in
            let similarity = cosineSimilarity(queryEmbedding, chunk.embedding)
            return (chunk, similarity)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(topK).map(\.0)
    }

    private func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let dot = zip(lhs, rhs).map(*).reduce(0, +)
        let leftMagnitude = sqrt(lhs.map { $0 * $0 }.reduce(0, +))
        let rightMagnitude = sqrt(rhs.map { $0 * $0 }.reduce(0, +))
        guard leftMagnitude > 0, rightMagnitude > 0 else { return 0 }
        return dot / (leftMagnitude * rightMagnitude)
    }
}

