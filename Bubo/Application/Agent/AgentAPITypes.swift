import Foundation

// MARK: - OpenAI-Compatible API Types (DeepSeek)

/// Tool definition in OpenAI format (wraps function in a type envelope).
struct OpenAITool: Encodable {
    let type = "function"
    let function: FunctionDef

    struct FunctionDef: Encodable {
        let name: String
        let description: String
        let parameters: [String: Any]

        enum CodingKeys: String, CodingKey {
            case name, description, parameters
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(description, forKey: .description)
            let data = try JSONSerialization.data(withJSONObject: parameters)
            let rawJSON = try JSONDecoder().decode(AnyCodable.self, from: data)
            try container.encode(rawJSON, forKey: .parameters)
        }
    }
}

struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [Message]
    let tools: [OpenAITool]
    let tool_choice: ToolChoice
    let max_tokens: Int

    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ToolChoice: Encodable {
        let type: String
        let function: FunctionName

        struct FunctionName: Encodable {
            let name: String
        }
    }
}

struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: ResponseMessage
    }

    struct ResponseMessage: Decodable {
        let tool_calls: [ToolCall]?
    }

    struct ToolCall: Decodable {
        let function: FunctionCall
    }

    struct FunctionCall: Decodable {
        let name: String
        let arguments: String // JSON string
    }
}

// MARK: - AnyCodable (for encoding/decoding arbitrary JSON)

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            value = b
        } else if let i = try? container.decode(Int.self) {
            value = i
        } else if let d = try? container.decode(Double.self) {
            value = d
        } else if let s = try? container.decode(String.self) {
            value = s
        } else if let arr = try? container.decode([AnyCodable].self) {
            value = arr.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported type"))
        }
    }
}
