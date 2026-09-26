import SwiftUI

struct HistoryView: View {
    var body: some View {
        ContentUnavailableView(
            "No History Yet",
            systemImage: "clock.arrow.circlepath",
            description: Text("This version of MacUp only checks for updates and never changes anything, so there is nothing to record yet.")
        )
    }
}
