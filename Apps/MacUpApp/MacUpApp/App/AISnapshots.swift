#if DEBUG
import AppKit
import Foundation
import MacUpCore

/// Debug snapshots only: AI help answered from canned replies, with a
/// pretend key that is not a key, and estimates kept in memory. A snapshot
/// run never reaches TypeSafe, never reads or writes the Keychain, and never
/// writes MacUp's state directory.
enum AISnapshotService {
    static func make() -> AIService {
        AIService(transport: CannedTypeSafe(), keyStore: SnapshotKeyStore(), estimates: { _ in cache })
    }

    private static let cache = InMemoryAIEstimateCache()
}

private struct SnapshotKeyStore: APIKeyStoring {
    func containsKey() throws -> Bool { true }
    func readKey() throws -> TypeSafeAPIKey? { try TypeSafeAPIKey(validating: "snapshot-only-not-a-key") }
    func saveKey(_ key: TypeSafeAPIKey) throws {}
    func deleteKey() throws -> Bool { false }
}

/// Reads the questions MacUp asked and answers each with a plausible option:
/// the package the request names, Ignore, a database that migrates its data.
private struct CannedTypeSafe: TypeSafeTransport {
    func send(_ request: TypeSafeHTTPRequest) async throws -> TypeSafeHTTPResponse {
        guard let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let questions = body["questions"] as? [String: [String: Any]]
        else { return TypeSafeHTTPResponse(statusCode: 422) }
        let text = ((body["state"] as? [String: Any])?["request"] as? String ?? "").lowercased()

        var answers: [String: Any] = [:]
        for (id, question) in questions {
            guard question["type"] as? String == "choice" else {
                answers[id] = ["type": "noul", "noul": id == "migrates_data" ? 0.91 : 0.98]
                continue
            }
            let options = ((question["criteria"] as? [String: Any]) ?? [:]).keys.sorted()
            let preferred: String? = switch id {
            case "action": "set_item_policy"
            case "item": options.first { $0.contains(":") && text.contains(($0.split(separator: ":").last ?? "").lowercased()) }
            case "item_policy": "ignore"
            case "provider", "note_text": "none"
            case "provider_policy": "ask"
            case "software_kind": "database"
            default: nil
            }
            let winner = preferred.flatMap { options.contains($0) ? $0 : nil } ?? options.first { $0 != "none_of_these" } ?? ""
            var probabilities = Dictionary(uniqueKeysWithValues: options.map { ($0, 0.04 / Double(max(options.count - 1, 1))) })
            probabilities[winner] = 0.96
            answers[id] = ["type": "choice", "choice": winner, "probabilities": probabilities, "confidence": 0.94]
        }
        let reply: [String: Any] = ["model": "jev-1.13.0", "answers": answers, "usage": ["input_tokens": 300, "output_tokens": 20]]
        return TypeSafeHTTPResponse(statusCode: 200, body: (try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
    }
}

extension Snapshots {
    /// The Features card with AI help on, the sheet that turns it on, an
    /// estimate beside an update, and the Ask MacUp popover — all from the
    /// canned replies above, with the configuration on disk untouched.
    @MainActor
    static func captureAI(model: AppModel, main: NSWindow?, into directory: PrivateDirectory, suffix: String) async {
        model.ai.snapshotOverride = true
        model.reapplyAICautions()
        await model.refreshAIStatus()

        model.section = .features
        try? await Task.sleep(for: .milliseconds(900))
        if let main { write(main, to: directory, named: "features-ai-\(suffix).png") }
        model.ai.isShowingEnableSheet = true
        try? await Task.sleep(for: .milliseconds(900))
        if let sheet = main?.attachedSheet { write(sheet, to: directory, named: "ai-enable-\(suffix).png") }
        model.ai.isShowingEnableSheet = false
        try? await Task.sleep(for: .milliseconds(500))

        if let update = model.report?.updates.first(where: { $0.provider != .macos }) {
            model.section = .updates
            model.selectedUpdate = update.id
            await model.estimate(update)
            try? await Task.sleep(for: .milliseconds(900))
            if let main { write(main, to: directory, named: "updates-ai-\(suffix).png") }

            model.ai.askText = "stop updating \(update.displayName)"
            await model.askMacUp()
            model.ai.isShowingAsk = true
            try? await Task.sleep(for: .milliseconds(1200))
            if let popover = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }) {
                write(popover, to: directory, named: "ask-\(suffix).png")
            }
            model.ai.isShowingAsk = false
        }

        model.cancelAsk()
        model.ai.askText = ""
        model.ai.estimates = [:]
        model.ai.snapshotOverride = false
        model.reapplyAICautions()
        await model.refreshAIStatus()
        try? await Task.sleep(for: .milliseconds(500))
    }
}
#endif
