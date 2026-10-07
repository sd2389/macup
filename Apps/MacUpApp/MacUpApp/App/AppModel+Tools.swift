import Foundation
import MacUpCore
import Observation

/// What the app knows about the package managers on this Mac beyond the four
/// MacUp manages, and whether a scan is running.
///
/// The scan asks each tool it finds for its version, which is read-only but
/// means a process per tool, so the app scans when the Providers screen is
/// first opened and then only when someone asks again.
@MainActor
@Observable
final class ToolScanModel {
    fileprivate(set) var scan: ToolScan?
    fileprivate(set) var isScanning = false
    fileprivate(set) var task: Task<Void, Never>?
}

extension AppModel {
    /// The tools MacUp found and does not manage, newest scan first. Empty
    /// until a scan has finished.
    var unmanagedTools: [FoundTool] { tools.scan?.unmanaged ?? [] }

    var isScanningTools: Bool { tools.isScanning }

    /// Scans once. Opening the Providers screen again does not scan again;
    /// Scan Again does.
    func scanToolsIfNeeded() {
        guard tools.scan == nil, tools.task == nil else { return }
        scanTools()
    }

    /// The same read-only scan `macup provider scan` runs.
    func scanTools() {
        guard tools.task == nil else { return }
        tools.isScanning = true
        tools.task = Task { [weak self] in
            guard let self else { return }
            let environment = checkEnvironment(await loadEnvironment())
            let scan = await ToolScanner().scan(environment: environment)
            tools.scan = scan
            tools.isScanning = false
            tools.task = nil
        }
    }
}
