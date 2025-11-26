import Foundation

final class EnvLoader {
    static func loadAPIKey() -> String? {
        // Start with environment variables that may already be exported
        if let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty {
            return key
        }

        // If nothing is set, look for a .env file in several locations
        var searchPaths: [String] = []
        
        // 1. Current working directory
        let currentDir = FileManager.default.currentDirectoryPath
        searchPaths.append((currentDir as NSString).appendingPathComponent(".env"))
        
        // 2. Walk up toward the project root
        var searchDir = currentDir
        for _ in 0..<10 { // Keep the search bounded
            let candidate = (searchDir as NSString).appendingPathComponent(".env")
            if FileManager.default.fileExists(atPath: candidate) {
                searchPaths.append(candidate)
            }
            // Move one directory up
            let parent = (searchDir as NSString).deletingLastPathComponent
            if parent == searchDir || parent.isEmpty { break }
            searchDir = parent
        }
        
        // 3. Home directory as a last resort
        if let homeDir = FileManager.default.homeDirectoryForCurrentUser.path as String? {
            searchPaths.append((homeDir as NSString).appendingPathComponent(".env"))
        }

        for path in searchPaths {
            if let key = loadKeyFromFile(path: path) {
                return key
            }
        }

        return nil
    }

    private static func loadKeyFromFile(path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip comments and blank lines
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            // Look for OPENAI_API_KEY=value entries
            if trimmed.hasPrefix("OPENAI_API_KEY=") {
                let key = String(trimmed.dropFirst("OPENAI_API_KEY=".count))
                    .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"")))
                return key.isEmpty ? nil : key
            }
        }

        return nil
    }
}

