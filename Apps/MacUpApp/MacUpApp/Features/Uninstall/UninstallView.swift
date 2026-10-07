import AppKit
import MacUpCore
import SwiftUI

/// Everything MacUp can uninstall — apps, and packages by provider — with the
/// way to review an uninstall. Looking changes nothing; the review sheet is
/// where anything is chosen, and nothing is removed before it is confirmed.
struct UninstallView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var state = model.uninstaller
        Group {
            if let catalog = state.catalog {
                list(catalog, search: state.search)
            } else if state.isScanning {
                ProgressView("Looking at what is installed…")
            } else {
                ContentUnavailableView {
                    Label("Nothing Listed Yet", systemImage: "trash")
                } description: {
                    Text("MacUp lists your apps and packages so you can uninstall one with nothing left behind. Looking changes nothing.")
                } actions: {
                    Button("Look Now") { Task { await model.scanUninstallable() } }
                }
            }
        }
        .searchable(text: $state.search, placement: .toolbar, prompt: "App or package")
        .toolbar {
            ToolbarItem {
                if state.isScanning {
                    ProgressView().controlSize(.small).help("Looking at what is installed")
                } else {
                    Button {
                        Task { await model.scanUninstallable() }
                    } label: {
                        Label("Look Again", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .help("List what is installed again. Looking changes nothing.")
                }
            }
        }
        .sheet(isPresented: $state.isReviewing) {
            UninstallReviewSheet()
                // Nothing may close the sheet while files are being removed.
                .interactiveDismissDisabled(state.isRunning)
        }
        .task { if state.catalog == nil { await model.scanUninstallable() } }
    }

    private func list(_ catalog: UninstallCatalog, search: String) -> some View {
        let words = search.lowercased().split(separator: " ").map(String.init)
        func matches(_ fields: [String?]) -> Bool {
            guard !words.isEmpty else { return true }
            let text = fields.compactMap { $0?.lowercased() }.joined(separator: " ")
            return words.allSatisfy { text.contains($0) }
        }
        let apps = catalog.apps.filter { matches([$0.name, $0.bundleIdentifier, $0.source.displayName]) }
        let orphans = model.orphanedLeftovers.filter { matches([$0.identifier, $0.guessedName]) }
        let providers: [(ProviderID, [UninstallablePackage])] = [ProviderID.homebrew, .npm, .mise].map { provider in
            (provider, catalog.packages(of: provider).filter { matches([$0.name, $0.target, $0.kind.displayName]) })
        }
        return List {
            Section {
                if apps.isEmpty { Text(words.isEmpty ? "No apps found." : "No app matches.").foregroundStyle(.secondary) }
                ForEach(apps) { app in UninstallAppRow(app: app) }
            } header: {
                Text("Apps")
            }
            ForEach(providers, id: \.0) { provider, packages in
                if !packages.isEmpty || words.isEmpty {
                    Section {
                        if packages.isEmpty {
                            Text(catalog.state(of: provider)?.message?.displaySafe ?? "Nothing installed with \(provider.displayName).")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(packages) { package in UninstallPackageRow(package: package) }
                    } header: {
                        Text(provider.displayName)
                    }
                }
            }
            if !orphans.isEmpty || words.isEmpty {
                Section {
                    if orphans.isEmpty {
                        Text("MacUp found nothing it is sure enough about to list.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(orphans) { group in UninstallLeftoversRow(group: group) }
                } header: {
                    Text("Left Behind by Apps You Removed")
                } footer: {
                    Text("Files named after an app that is not installed any more. MacUp cannot ask an app that is gone whether these are its files, so nothing is ticked for you: you choose what goes. The same list is `macup uninstall --orphans`.")
                        .leadingFooter()
                }
            }
            if !catalog.manualInstalls.isEmpty && words.isEmpty {
                Section {
                    ForEach(catalog.manualInstalls) { install in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(install.name.displaySafe).fontWeight(.medium)
                            Text(install.reason.displaySafe).font(.callout).foregroundStyle(.secondary)
                            ForEach(Array(install.steps.enumerated()), id: \.offset) { index, step in
                                Text("\(index + 1). \(step.displaySafe)").font(.callout).textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Needs You, Not MacUp")
                }
            }
        }
    }
}

private struct UninstallAppRow: View {
    @Environment(AppModel.self) private var model
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name.displaySafe).fontWeight(.medium)
                Text([app.version?.displaySafe, app.source.displayName].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !app.removability.isRemovable, let reason = app.removability.reason {
                    Text(reason.displaySafe)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Uninstall…") { Task { await model.reviewUninstall(.app(app)) } }
                .disabled(model.uninstaller.isRunning)
                .accessibilityLabel("Review uninstalling \(app.name)")
                .help(app.removability.isRemovable
                    ? "See exactly what would be removed. Nothing is removed until you confirm."
                    : "See what MacUp can and cannot remove for \(app.name).")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

/// One app's leftovers, with how big they are and why MacUp thinks an app
/// left them.
private struct UninstallLeftoversRow: View {
    @Environment(AppModel.self) private var model
    let group: OrphanedLeftovers

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.identifier.displaySafe).fontWeight(.medium)
                Text("\(UninstallSizeText.text(group.sizeBytes, partial: group.sizeIsPartial)) · \(group.files.count == 1 ? "1 item" : "\(group.files.count) items")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(group.evidence, id: \.self) { reason in
                    Text(reason.displaySafe)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Review…") { Task { await model.reviewLeftovers(group) } }
                .disabled(model.uninstaller.isRunning)
                .accessibilityLabel("Review what \(group.identifier) left behind")
                .help("See every file, with its size. Nothing is ticked, and nothing is removed until you confirm.")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

private struct UninstallPackageRow: View {
    @Environment(AppModel.self) private var model
    let package: UninstallablePackage

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: package.provider.symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(package.name.displaySafe).fontWeight(.medium)
                Text([package.target.displaySafe, package.version?.displaySafe, package.note?.displaySafe].compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Uninstall…") { Task { await model.reviewUninstall(.package(package)) } }
                .disabled(model.uninstaller.isRunning)
                .accessibilityLabel("Review uninstalling \(package.name)")
                .help("See exactly what would be removed. Nothing is removed until you confirm.")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}
