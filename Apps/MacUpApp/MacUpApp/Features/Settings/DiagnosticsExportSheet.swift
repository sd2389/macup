import AppKit
import MacUpCore
import SwiftUI
import UniformTypeIdentifiers

/// Export Diagnostics: what goes in the file, what is left out, and the exact
/// text, all before anything is written (CLAUDE.md §13, §16).
///
/// Nothing leaves the Mac from here. Save writes one new file where the user
/// chooses, readable only by them; attaching it to anything is up to them.
struct DiagnosticsExportSheet: View {
    @Environment(AppModel.self) private var model
    let export: DiagnosticsExport

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                contents
                    .frame(width: 350)
                Divider()
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        // Sized, not fixed, so larger text still fits (CLAUDE.md §21).
        .frame(minWidth: 800, idealWidth: 920, minHeight: 560, idealHeight: 680)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Export Diagnostics").font(.title2.weight(.semibold))
            Text("A file to attach to a bug report. Everything in it is shown here first. MacUp saves it only where you choose, and sends it nowhere.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .accessibilityElement(children: .combine)
    }

    // MARK: What is in it

    /// What is left out comes first, straight under the one choice that
    /// changes it, because it is the half a reader is trusting MacUp about;
    /// what is in the file can also be read in full beside it.
    private var contents: some View {
        Form {
            Section {
                Toggle("Include package names", isOn: packageNames)
                    .disabled(export.isGathering)
            } footer: {
                Text("Off by default: what you have installed is your own business. While it is off, each name is replaced with a placeholder such as brew:package-1.")
                    .leadingFooter()
            }
            Section("Left out") {
                ForEach(export.leftOut, id: \.self) { line in
                    ContentsRow(text: line, symbol: "minus.circle")
                }
            }
            Section("In the file") {
                ForEach(export.included, id: \.self) { line in
                    ContentsRow(text: line, symbol: "checkmark.circle")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var packageNames: Binding<Bool> {
        Binding(get: { export.includesPackageNames }, set: { export.setIncludesPackageNames($0) })
    }

    // MARK: The file itself

    @ViewBuilder
    private var preview: some View {
        if export.isGathering {
            VStack(spacing: 10) {
                ProgressView().accessibilityHidden(true)
                Text("Gathering diagnostics…")
                Text("MacUp is running a read-only check and Doctor. Nothing on this Mac is changed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Preview").font(.headline)
                    Spacer()
                    if let content = export.content {
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(content.count), countStyle: .file)), exactly as it would be saved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                DiagnosticsPreviewText(text: export.preview)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
            .padding(16)
        }
    }

    // MARK: Saving

    private var footer: some View {
        HStack(spacing: 12) {
            status
            Spacer(minLength: 12)
            if export.savedPath == nil {
                Button("Cancel") { model.endDiagnosticsExport() }
                    .keyboardShortcut(.cancelAction)
                Button("Save…") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(export.content == nil)
                    .help("Choose where to save exactly the text shown here")
            } else {
                Button("Done") { model.endDiagnosticsExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var status: some View {
        if let problem = export.problem {
            Label {
                Text(problem.displayPath).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "xmark.octagon").foregroundStyle(.red).accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Not saved. \(problem)")
        } else if let path = export.savedPath {
            HStack(spacing: 10) {
                Label {
                    Text("Saved to \(path.displayPath). Only you can read it.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle").accessibilityHidden(true)
                }
                .accessibilityElement(children: .combine)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
        }
    }

    /// Asks where to save, then writes exactly what the preview shows.
    ///
    /// The panel is modal, so the text cannot change between the moment the
    /// user presses Save and the moment it is written.
    private func save() {
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.message = "Only you will be able to read the file, and it stays on this Mac until you attach it to something yourself."
        panel.prompt = "Save"
        panel.nameFieldStringValue = export.suggestedFileName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let refusal = RefusesExistingFiles(homeDirectory: export.homeDirectory)
        panel.delegate = refusal
        let response = panel.runModal()
        panel.delegate = nil
        withExtendedLifetime(refusal) {}
        guard response == .OK, let url = panel.url else { return }
        export.save(to: url)
    }
}

/// One line of what is, or is not, in the file.
private struct ContentsRow: View {
    let text: String
    let symbol: String

    var body: some View {
        Label {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }
}

/// Keeps the save panel open, saying why, when the chosen name is taken.
///
/// MacUp never replaces a file, so accepting a name that is already in use
/// would only end in a refusal after the panel had closed.
@MainActor
private final class RefusesExistingFiles: NSObject, NSOpenSavePanelDelegate {
    let homeDirectory: String

    init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard let problem = DiagnosticsFile.problem(writingTo: url.path) else { return }
        throw NSError(domain: "dev.macup.diagnostics", code: 1, userInfo: [
            NSLocalizedDescriptionKey: problem.message(homeDirectory: homeDirectory),
            NSLocalizedRecoverySuggestionErrorKey: "Choose another name or folder.",
        ])
    }
}

/// The file's text, read-only and selectable.
///
/// An AppKit text view rather than SwiftUI `Text`, because the file runs to
/// hundreds of lines: it scrolls without laying all of them out at once, the
/// keyboard can move through it, select it, and search it, and VoiceOver
/// reads it as the text area it is.
private struct DiagnosticsPreviewText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.usesFindBar = true
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.textColor = .labelColor
            textView.backgroundColor = .textBackgroundColor
            textView.textContainerInset = NSSize(width: 8, height: 8)
            textView.setAccessibilityLabel("Preview of the file, exactly as it would be saved")
            textView.string = text
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
        textView.scrollToBeginningOfDocument(nil)
    }
}
