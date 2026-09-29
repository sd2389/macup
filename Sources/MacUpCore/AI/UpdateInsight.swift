import Foundation

/// A clearly labelled note an AI estimate adds to an update. MacUp composes it
/// in code from TypeSafe's judgments; TypeSafe writes none of it.
public struct AICaution: Sendable, Hashable, Codable {
    public var note: String
    /// The probability behind the claim the note makes.
    public var probability: Double

    public init(note: String, probability: Double) {
        self.note = note
        self.probability = probability
    }
}

/// One update's estimate, and what MacUp makes of it.
public struct UpdateEstimateResult: Sendable, Hashable {
    public var estimate: AIEstimate
    /// `nil` when the judgments do not point to extra danger for this change.
    public var caution: AICaution?
    /// Read from this Mac rather than asked again.
    public var fromCache: Bool
    /// Why the estimate could not be kept, when it could not.
    public var saveProblem: String?

    public init(estimate: AIEstimate, caution: AICaution?, fromCache: Bool, saveProblem: String? = nil) {
        self.estimate = estimate
        self.caution = caution
        self.fromCache = fromCache
        self.saveProblem = saveProblem
    }
}

/// "AI caution" for an update: two quick judgments about a package, made
/// from its name, package manager, and versions only, that can add caution
/// to an update and can never take any away.
///
/// TypeSafe is asked what kind of software the package is and whether a major
/// upgrade of it commonly migrates or rewrites the data it keeps. Code decides
/// what follows. Only a confident judgment that points to extra danger — a
/// database, or data that gets migrated, meeting a major version change —
/// produces anything: a note that says where it came from and how sure it
/// was, and a signal (``RiskSignal/aiCaution``) that makes the policy engine
/// ask first where it would otherwise have updated without asking. Risk is
/// never lowered, no rule is changed, and nothing is ever decided to be safe.
public enum UpdateInsight {
    /// How sure TypeSafe must be before its judgment becomes a caution.
    static let migratesDataThreshold = 0.8
    static let databaseThreshold = 0.8
    /// The changes a data caution is about. A patch or a minor release of a
    /// database does not migrate its data, so it gets no caution; a change
    /// MacUp could not classify might be a major one, so it does.
    static let cautionedChanges: Set<VersionChange> = [.major, .unknown]

    static let questions: [String: TypeSafeQuestion] = [
        "software_kind": .choice(
            "What kind of software is `package`?",
            options: [
                .init(SoftwareKind.database.rawValue, "A database or data store that keeps data on disk, such as PostgreSQL, MySQL, Redis, or SQLite."),
                .init(SoftwareKind.runtime.rawValue, "A programming language runtime, compiler, or toolchain, such as Node.js, Python, Go, or a JDK."),
                .init(SoftwareKind.service.rawValue, "A background service or server that runs on its own, such as a web server or a message broker."),
                .init(SoftwareKind.cliTool.rawValue, "A command-line tool that people run directly."),
                .init(SoftwareKind.library.rawValue, "A library that other software links against or imports."),
                .init(SoftwareKind.guiApp.rawValue, "An application with a graphical interface."),
                .init(SoftwareKind.packageManager.rawValue, "A package or version manager, such as npm, pip, Homebrew, or mise."),
                .init(SoftwareKind.other.rawValue, "None of these."),
            ]
        ),
        "migrates_data": .noul(
            "Does a major-version upgrade of `package` commonly migrate, convert, or rewrite the data it keeps on disk, so that its data should be backed up before such an upgrade?",
            yes: "A major upgrade changes its stored data or on-disk format, for example database files or a data directory.",
            no: "It keeps no data of its own, or a major upgrade leaves its stored data as it is."
        ),
    ]

    /// The state sent for one update: exactly the fields the disclosure lists.
    static func state(for candidate: UpdateCandidate) -> TypeSafeValue {
        var package: [String: TypeSafeValue] = [
            "id": .string(candidate.id.rawValue),
            "name": .string(TerminalText.sanitize(candidate.displayName)),
            "packageManager": .string(candidate.provider.displayName),
            "kind": .string(candidate.kind.estimateDescription),
            "availableVersion": .string(TerminalText.sanitize(candidate.availableVersion.raw)),
        ]
        if let installed = candidate.installedVersion {
            package["installedVersion"] = .string(TerminalText.sanitize(installed.raw))
        }
        return .object(["package": .object(package)])
    }

    static func estimate(from response: TypeSafeResponse, for candidate: UpdateCandidate, askedAt: Date) throws -> AIEstimate {
        guard let kind = response.choice("software_kind"),
              let softwareKind = SoftwareKind(rawValue: kind.choice),
              let migrates = response.noul("migrates_data")
        else { throw AIError.unexpectedResponse }
        return AIEstimate(
            item: candidate.id,
            installedVersion: candidate.installedVersion?.raw,
            availableVersion: candidate.availableVersion.raw,
            model: response.model,
            askedAt: askedAt,
            softwareKind: softwareKind,
            softwareKindProbability: kind.probability(of: kind.choice),
            softwareKindConfidence: kind.confidence,
            dataMigrationProbability: migrates
        )
    }

    /// The caution an estimate adds to this update, or `nil`.
    public static func caution(for candidate: UpdateCandidate, estimate: AIEstimate) -> AICaution? {
        guard estimate.matches(candidate), cautionedChanges.contains(candidate.versionChange) else { return nil }
        let name = TerminalText.sanitize(candidate.displayName)
        let isDatabase = estimate.softwareKind == .database && estimate.softwareKindProbability >= databaseThreshold
        let migrates = estimate.dataMigrationProbability >= migratesDataThreshold
        let known = candidate.versionChange == .major
        switch (isDatabase, migrates) {
        case (true, true):
            let upgrade = known ? "a major upgrade may" : "if this is a major upgrade, it may"
            return AICaution(
                note: "AI estimate from TypeSafe, \(AskMacUp.percent(estimate.dataMigrationProbability)): \(name) looks like a database; \(upgrade) migrate its data on first start — back up first.",
                probability: estimate.dataMigrationProbability
            )
        case (false, true):
            let upgrade = known ? "a major upgrade of \(name) may" : "if this is a major upgrade, \(name) may"
            return AICaution(
                note: "AI estimate from TypeSafe, \(AskMacUp.percent(estimate.dataMigrationProbability)): \(upgrade) migrate or rewrite the data it keeps — back up first.",
                probability: estimate.dataMigrationProbability
            )
        case (true, false):
            return AICaution(
                note: "AI estimate from TypeSafe, \(AskMacUp.percent(estimate.softwareKindProbability)): \(name) looks like a database — back up its data before a major upgrade.",
                probability: estimate.softwareKindProbability
            )
        case (false, false):
            return nil
        }
    }

    /// The candidate with its caution added, or unchanged. Adding a signal and
    /// a note can only raise its risk, never lower it.
    public static func applying(_ estimate: AIEstimate?, to candidate: UpdateCandidate) -> UpdateCandidate {
        guard let estimate, let caution = caution(for: candidate, estimate: estimate) else { return candidate }
        return candidate.adding(signals: [.aiCaution], notes: [caution.note])
    }

    /// Every update in `report` with the caution its newest matching estimate adds.
    public static func applying(_ estimates: [AIEstimate], to report: CheckReport) -> CheckReport {
        guard !estimates.isEmpty else { return report }
        var report = report
        report.updates = report.updates.map { candidate in
            applying(estimates.filter { $0.matches(candidate) }.max { $0.askedAt < $1.askedAt }, to: candidate)
        }
        return report
    }
}

extension ItemKind {
    var estimateDescription: String {
        switch self {
        case .formula: "Homebrew formula"
        case .cask: "Homebrew cask"
        case .globalPackage: "global npm package"
        case .tool: "mise tool"
        case .systemUpdate: "macOS update"
        }
    }
}

extension AIService {
    /// The estimate for one update: the saved one when this exact version
    /// change was asked about before, otherwise one request, saved on this Mac.
    /// Throws ``AIError`` when AI help is off or the request fails.
    public func estimate(
        _ candidate: UpdateCandidate,
        configuration: LoadedConfiguration,
        environment: [String: String],
        paths: MacUpPaths,
        refresh: Bool = false
    ) async throws -> UpdateEstimateResult {
        // The same gate as a request, even for a saved answer: with AI help
        // off, MacUp behaves as though it had never asked.
        guard !configuration.hasErrors else { throw AIError.configurationUnreadable }
        guard configuration.configuration.aiSettings.enabled else { throw AIError.disabled }
        guard candidate.provider != .macos else {
            throw AIError(.invalidRequest, "MacUp does not ask about macOS updates: they always wait for you, and nothing was sent.")
        }

        let cache = estimates(paths)
        if !refresh, let saved = (try? cache.load())?.filter({ $0.matches(candidate) }).max(by: { $0.askedAt < $1.askedAt }) {
            return UpdateEstimateResult(
                estimate: saved,
                caution: UpdateInsight.caution(for: candidate, estimate: saved),
                fromCache: true
            )
        }

        let (client, _) = try client(configuration, environment: environment)
        let response = try await client.ask(state: UpdateInsight.state(for: candidate), questions: UpdateInsight.questions)
        let estimate = try UpdateInsight.estimate(from: response, for: candidate, askedAt: now())
        var saveProblem: String?
        do {
            try cache.save(estimate)
        } catch let error as MacUpError {
            saveProblem = error.message
        } catch {
            saveProblem = "The estimate could not be saved, so MacUp will not apply it after this."
        }
        return UpdateEstimateResult(
            estimate: estimate,
            caution: UpdateInsight.caution(for: candidate, estimate: estimate),
            fromCache: false,
            saveProblem: saveProblem
        )
    }

    /// The report with the cautions of saved estimates added, while AI help
    /// is on. Reads one local file and sends nothing.
    public func cautioned(_ report: CheckReport, configuration: LoadedConfiguration, paths: MacUpPaths) -> (report: CheckReport, problem: String?) {
        guard appliesEstimates(configuration) else { return (report, nil) }
        do {
            return (UpdateInsight.applying(try estimates(paths).load(), to: report), nil)
        } catch let error as MacUpError {
            return (report, error.message)
        } catch {
            return (report, "MacUp could not read its saved AI estimates, so it is not applying any of them.")
        }
    }

    /// Deletes every saved estimate. Local only; allowed with AI help off.
    @discardableResult
    public func forgetEstimates(paths: MacUpPaths) throws -> Int {
        try estimates(paths).clear()
    }
}
