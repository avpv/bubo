import Foundation

// MARK: - Errors

enum AgentError: Error, LocalizedError {
    case noAPIKey
    case encoding
    case network(String)
    case api(String)
    case parsing(String)
    case validation(String)
    case rateLimited(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: "No API key configured. Add your DeepSeek API key in Settings → AI Assistant."
        case .encoding: "Failed to encode request."
        case .network(let msg): "Network error: \(msg)"
        case .api(let msg): "API error: \(msg)"
        case .parsing(let msg): "Parse error: \(msg)"
        case .validation(let msg): "Validation error: \(msg)"
        case .rateLimited(let msg): msg
        }
    }
}

