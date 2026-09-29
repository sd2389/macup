import MacUpCore
import SwiftUI

/// What happened to one attempt, in the one sentence History uses for it.
///
/// The words are ``HistoryHeadline``'s, the same ones `macup history` prints.
/// The symbol and its tint only repeat them: a deliberate stop gets a stop
/// sign rather than an error, and only a confirmed update gets a checkmark.
struct HistoryHeadlineLabel: View {
    let headline: HistoryHeadline

    var body: some View {
        Label {
            Text(headline.text.displaySafe)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: headline.symbolName)
                .foregroundStyle(headline.tone.color)
                .accessibilityHidden(true)
        }
    }
}

extension HistoryHeadline.Tone {
    var color: Color {
        switch self {
        case .good: .green
        case .caution: .orange
        case .problem: .red
        case .neutral: .secondary
        }
    }
}
