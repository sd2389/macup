import Foundation

/// One entry from `softwareupdate --list`.
struct SoftwareUpdateEntry: Sendable, Hashable {
    var label: String
    var title: String
    var version: String
    var sizeKiB: Int?
    var recommended: Bool?
    /// For example `restart` or `shut down`.
    var action: String?
    var otherFields: [String: String]

    var requiresRestart: Bool {
        guard let action = action?.lowercased() else { return false }
        return action.contains("restart") || action.contains("shut down")
    }

    var isOperatingSystemUpdate: Bool {
        title.lowercased().hasPrefix("macos") || label.lowercased().hasPrefix("macos")
    }

    var isBeta: Bool {
        title.range(of: #"\bbeta\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Parses `softwareupdate --list` output (macOS 11 and later):
///
/// ```text
/// Software Update Tool
///
/// Finding available software
/// Software Update found the following new or updated software:
/// * Label: macOS 27.2 Beta-26B5091g
/// 	Title: macOS 27.2 Beta, Version: 27.2, Size: 5935245KiB, Recommended: YES, Action: restart,
/// ```
///
/// or "No new software available." when there is nothing. Output MacUp does
/// not recognize is an error or a finding — never a guess.
enum SoftwareUpdateParser {
    static let foundHeader = "Software Update found the following new or updated software:"
    static let noUpdates = "No new software available."

    static func parse(
        standardOutput: String,
        standardError: String
    ) throws -> (entries: [SoftwareUpdateEntry], findings: [DiagnosticFinding], skipped: Int, partial: Bool) {
        let lines = (standardOutput + "\n" + standardError).components(separatedBy: .newlines)
        guard let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == foundHeader }) else {
            if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == noUpdates }) {
                return ([], [], 0, false)
            }
            throw MacUpError.parseFailed(
                "softwareupdate printed output MacUp does not recognize.",
                detail: TextExcerpt.tail(of: standardOutput + "\n" + standardError, maxLines: 8)
            )
        }

        var entries: [SoftwareUpdateEntry] = []
        var findings: [DiagnosticFinding] = []
        var unrecognized: [String] = []
        var pendingLabel: String?
        var skipped = 0

        func finishPendingWithoutDetails() {
            if let label = pendingLabel {
                skipped += 1
                findings.append(DiagnosticFinding(
                    id: "macos.unreadableUpdate",
                    severity: .warning,
                    provider: .macos,
                    title: "An available update could not be read",
                    detail: "softwareupdate listed \(TerminalText.sanitize(label.debugDescription)) without details.",
                    recommendation: "Review it in System Settings → General → Software Update."
                ))
            }
            pendingLabel = nil
        }

        for line in lines[(header + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed == noUpdates { continue }
            if trimmed.hasPrefix("* Label:") {
                finishPendingWithoutDetails()
                let label = trimmed.dropFirst("* Label:".count).trimmingCharacters(in: .whitespaces)
                if label.isEmpty { unrecognized.append(line) } else { pendingLabel = label }
            } else if trimmed.hasPrefix("Title:"), let label = pendingLabel {
                if let entry = entry(label: label, details: trimmed) {
                    entries.append(entry)
                    pendingLabel = nil
                } else {
                    finishPendingWithoutDetails()
                }
            } else {
                unrecognized.append(line)
            }
        }
        finishPendingWithoutDetails()

        if !unrecognized.isEmpty {
            if entries.isEmpty && findings.isEmpty {
                throw MacUpError.parseFailed(
                    "softwareupdate listed updates in a format MacUp does not recognize.",
                    detail: TextExcerpt.tail(of: unrecognized.joined(separator: "\n"), maxLines: 8)
                )
            }
            findings.append(DiagnosticFinding(
                id: "macos.unrecognizedOutput",
                severity: .warning,
                provider: .macos,
                title: "softwareupdate printed \(unrecognized.count) line(s) MacUp did not recognize",
                detail: TextExcerpt.tail(of: unrecognized.joined(separator: "\n"), maxLines: 5),
                recommendation: "Review available updates in System Settings → General → Software Update."
            ))
        }
        // Updates were listed but none could be read: fail closed rather than
        // report "up to date", whatever findings were recorded along the way.
        if entries.isEmpty {
            let details = findings.compactMap(\.detail).joined(separator: "\n")
            throw MacUpError.parseFailed(
                "softwareupdate said updates were available but listed none MacUp could read.",
                detail: details.isEmpty ? nil : details
            )
        }
        return (entries, findings, skipped, !unrecognized.isEmpty)
    }

    /// Parses `Title: …, Version: …, Size: …KiB, Recommended: YES, Action: restart,`.
    /// Fields are split only at `, Key: ` boundaries, so titles containing commas survive.
    static func entry(label: String, details: String) -> SoftwareUpdateEntry? {
        var text = details.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(",") { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }

        var fields: [String: String] = [:]
        var order: [String] = []
        for segment in splitFields(text) {
            guard let colon = segment.range(of: ": ") else { return nil }
            let key = String(segment[..<colon.lowerBound])
            fields[key] = String(segment[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            order.append(key)
        }
        guard order.first == "Title", let title = fields["Title"], !title.isEmpty,
              let version = fields["Version"], !version.isEmpty
        else { return nil }

        let sizeKiB = fields["Size"].flatMap { size -> Int? in
            guard size.hasSuffix("KiB") else { return nil }
            return Int(size.dropLast(3))
        }
        let recommended = fields["Recommended"].map { $0.uppercased() == "YES" }
        let known: Set<String> = ["Title", "Version", "Size", "Recommended", "Action"]
        return SoftwareUpdateEntry(
            label: label,
            title: title,
            version: version,
            sizeKiB: sizeKiB,
            recommended: recommended,
            action: fields["Action"],
            otherFields: fields.filter { !known.contains($0.key) }
        )
    }

    /// Splits at ", " only when the next text looks like `Key: `.
    private static func splitFields(_ text: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix(", "), startsField(text[text.index(index, offsetBy: 2)...]) {
                segments.append(current)
                current = ""
                index = text.index(index, offsetBy: 2)
                continue
            }
            current.append(text[index])
            index = text.index(after: index)
        }
        segments.append(current)
        return segments
    }

    /// `Key: ` where Key is one or more capitalized words.
    private static func startsField(_ text: Substring) -> Bool {
        guard let colon = text.range(of: ": ") else { return false }
        let key = text[..<colon.lowerBound]
        guard let first = key.first, first.isUppercase else { return false }
        return key.allSatisfy { $0.isLetter || $0 == " " }
    }
}
