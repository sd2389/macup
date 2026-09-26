import Foundation
import MacUpCore
import Testing

@testable import macup

/// Pins the `macup check --json` schema (version 1). If this test fails
/// because a field was renamed or removed, bump `CheckReport.schemaVersion`
/// and document the change in docs/CLI.md; purely additive fields only need
/// the golden file updated.
@Suite("JSON schema v1")
struct JSONSchemaTests {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)

    static func sampleReport() throws -> CheckReport {
        let brew = ResolvedExecutable(path: "/opt/homebrew/bin/brew", canonicalPath: "/opt/homebrew/bin/brew", source: .searchPath)
        let candidate = UpdateCandidate(
            id: try PackageID(parsing: "brew:git"),
            kind: .formula,
            displayName: "git",
            installedVersion: "2.43.0",
            availableVersion: "2.44.0",
            ownership: OwnershipChain([OwnershipLink(label: "Homebrew", path: "/opt/homebrew")])
        )
        let provider = ProviderReport(
            provider: .homebrew,
            displayName: "Homebrew",
            availability: .available,
            capabilities: [.detect, .inventory, .outdated, .refreshMetadata],
            executable: brew,
            version: "7.0.6",
            facts: [ProviderFact(key: "prefix", label: "Prefix", value: "/opt/homebrew")],
            installedCount: 1,
            updateCount: 1,
            findings: [DiagnosticFinding(id: "homebrew.multipleInstallations", severity: .warning, provider: .homebrew, title: "More than one Homebrew installation was found")],
            errors: [],
            durationSeconds: 0.5
        )
        return CheckReport(
            mode: .readOnly,
            startedAt: date,
            finishedAt: date.addingTimeInterval(1),
            cancelled: false,
            configuration: ConfigurationSummary(LoadedConfiguration(
                configuration: .defaults,
                source: .defaults,
                path: "/Users/example/.config/macup/config.json"
            )),
            providers: [provider],
            updates: [candidate],
            commands: [CommandRecord(
                command: "/opt/homebrew/bin/brew outdated --json=v2",
                effect: .readOnly,
                outcome: .exited,
                exitStatus: 0,
                startedAt: date,
                durationSeconds: 0.25
            )]
        )
    }

    static let golden = """
        {
          "cancelled" : false,
          "commands" : [
            {
              "command" : "/opt/homebrew/bin/brew outdated --json=v2",
              "durationSeconds" : 0.25,
              "effect" : "readOnly",
              "exitStatus" : 0,
              "outcome" : "exited",
              "startedAt" : "2026-09-21T14:13:20Z"
            }
          ],
          "configuration" : {
            "automaticModificationsAllowed" : true,
            "issues" : [

            ],
            "path" : "/Users/example/.config/macup/config.json",
            "source" : "defaults",
            "valid" : true
          },
          "finishedAt" : "2026-09-21T14:13:21Z",
          "kind" : "check",
          "macupVersion" : "\(MacUp.version)",
          "mode" : "readOnly",
          "providers" : [
            {
              "availability" : "available",
              "capabilities" : [
                "detect",
                "inventory",
                "outdated",
                "refreshMetadata"
              ],
              "displayName" : "Homebrew",
              "durationSeconds" : 0.5,
              "errors" : [

              ],
              "executable" : {
                "canonicalPath" : "/opt/homebrew/bin/brew",
                "path" : "/opt/homebrew/bin/brew",
                "source" : "searchPath"
              },
              "facts" : [
                {
                  "key" : "prefix",
                  "label" : "Prefix",
                  "value" : "/opt/homebrew"
                }
              ],
              "findings" : [
                {
                  "id" : "homebrew.multipleInstallations",
                  "provider" : "homebrew",
                  "severity" : "warning",
                  "title" : "More than one Homebrew installation was found"
                }
              ],
              "installedCount" : 1,
              "provider" : "homebrew",
              "updateCount" : 1,
              "version" : "7.0.6"
            }
          ],
          "schemaVersion" : 1,
          "startedAt" : "2026-09-21T14:13:20Z",
          "summary" : {
            "providersChecked" : 1,
            "providersDisabled" : 0,
            "providersUnavailable" : 0,
            "providersWithErrors" : 0,
            "updatesAvailable" : 1
          },
          "updates" : [
            {
              "availableVersion" : "2.44.0",
              "details" : {

              },
              "displayName" : "git",
              "id" : "brew:git",
              "installedVersion" : "2.43.0",
              "kind" : "formula",
              "notes" : [

              ],
              "ownership" : {
                "links" : [
                  {
                    "label" : "Homebrew",
                    "path" : "/opt/homebrew"
                  }
                ]
              },
              "risk" : {
                "level" : "moderate",
                "reasons" : [
                  "Minor version change"
                ]
              },
              "signals" : [

              ],
              "versionChange" : "minor"
            }
          ]
        }
        """

    @Test("The check report encodes exactly as documented")
    func goldenCheckReport() throws {
        let encoded = try JSONOutput.encode(try Self.sampleReport())
        #expect(encoded == Self.golden)
    }

    @Test("The golden document decodes back to the same report")
    func goldenDecodes() throws {
        let decoded = try JSONDecoder.iso8601.decode(CheckReport.self, from: Data(Self.golden.utf8))
        #expect(decoded == (try Self.sampleReport()))
    }
}
