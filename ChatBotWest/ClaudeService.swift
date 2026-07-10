import Foundation
import FirebaseAuth
import FirebaseFunctions

/// Claude API の呼び出し。
/// ログイン済みなら Firebase Functions のプロキシ (`chat`) を使い、APIキーは端末に不要。
/// プロキシに接続できない場合は、設定画面で保存したAPIキーで直接呼び出しにフォールバックする(Web版と同じ挙動)。
enum ClaudeService {
    static let model = "claude-opus-4-8"
    static let apiKeyDefaultsKey = "anthropic-api-key"

    struct ChatMessage {
        let role: String // "user" | "assistant"
        let content: String
    }

    enum ClaudeError: LocalizedError {
        case noApiKey
        case refusal
        case empty
        case server(String)

        var errorDescription: String? {
            switch self {
            case .noApiKey: return "サーバー(APIプロキシ)に接続できませんでした。設定からAPIキーを入力するか、管理者にご連絡ください。"
            case .refusal: return "この内容にはお答えできません。別の質問をお試しください。"
            case .empty: return "回答を取得できませんでした。もう一度お試しください。"
            case .server(let m): return m
            }
        }
    }

    static var storedApiKey: String {
        UserDefaults.standard.string(forKey: apiKeyDefaultsKey) ?? ""
    }

    static func call(system: String, messages: [ChatMessage], schema: [String: Any]? = nil) async throws -> String {
        let msgDicts = messages.map { ["role": $0.role, "content": $0.content] }

        // Firebase Functions プロキシ(ログイン済みのみ)
        if Auth.auth().currentUser != nil {
            var data: [String: Any] = ["system": system, "messages": msgDicts]
            if let schema { data["schema"] = schema }
            do {
                let fn = Functions.functions(region: "us-central1").httpsCallable("chat")
                let result = try await fn.call(data)
                let d = result.data as? [String: Any] ?? [:]
                if d["refusal"] as? Bool == true { throw ClaudeError.refusal }
                if let text = d["text"] as? String, !text.isEmpty { return text }
                throw ClaudeError.empty
            } catch let e as ClaudeError {
                throw e
            } catch {
                // プロキシ未デプロイ等 → APIキーがあれば直接呼び出しにフォールバック
                if storedApiKey.isEmpty {
                    throw ClaudeError.server("サーバー(APIプロキシ)に接続できませんでした。管理者にご連絡ください。(\(error.localizedDescription))")
                }
            }
        }

        return try await callDirect(system: system, messages: msgDicts, schema: schema)
    }

    private static func callDirect(system: String, messages: [[String: String]], schema: [String: Any]?) async throws -> String {
        let key = storedApiKey
        guard !key.isEmpty else { throw ClaudeError.noApiKey }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "thinking": ["type": "adaptive"],
            "system": system,
            "messages": messages,
        ]
        if let schema {
            body["output_config"] = ["format": ["type": "json_schema", "schema": schema]]
        }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 120

        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["error"] as? [String: Any] }
                .flatMap { $0["message"] as? String } ?? ""
            if status == 401 { throw ClaudeError.server("APIキーが無効です。設定から正しいキーを入力してください。") }
            if status == 429 { throw ClaudeError.server("リクエストが混み合っています。しばらく待ってから再度お試しください。") }
            throw ClaudeError.server("APIエラー (\(status)): \(detail)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeError.empty }
        if json["stop_reason"] as? String == "refusal" { throw ClaudeError.refusal }
        let text = (json["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw ClaudeError.empty }
        return text
    }
}
