import MacUpCore
import SwiftUI

/// A line under an update that would change a service that is running, or a
/// database's data, so the effect is visible before anyone opens the
/// details. The details say the whole of it.
struct ServiceImpactLabel: View {
    let update: UpdateCandidate

    var body: some View {
        let running = update.signals.contains(.runsAsService)
        if update.signals.contains(.mayMigrateData) {
            Label(
                (running ? "A database that is running now as a service. " : "A database. ")
                    + "Its new version may convert your data files for good, so back up first; see the details.",
                systemImage: "cylinder.split.1x2"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        } else if running {
            Label("Running now as a service, which keeps the old version until it restarts; see the details.", systemImage: "gearshape.2")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
