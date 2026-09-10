import AppKit
import SwiftUI

// MARK: - List

struct AdoptListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let candidates = model.adoptionCandidates

        VStack(spacing: 0) {
            Picker("Filter", selection: $model.adoptFilter) {
                ForEach(AdoptFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("\u{201C}Adoptable\u{201D} lists only apps that match a Homebrew cask. \u{201C}All apps\u{201D} also shows the ones with no match.")
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if model.appManagementStatus == .denied {
                AppManagementNotice()
                Divider()
            }

            if model.isScanningApps && model.installedApps.isEmpty {
                Placeholder(title: "Looking through your apps…", systemImage: "hourglass")
            } else if model.catalogRows.isEmpty {
                Placeholder(
                    title: "Waiting for the catalogue",
                    message: "Homebrew's cask list has to load before apps can be matched against it.",
                    systemImage: "arrow.down.circle"
                )
            } else if candidates.isEmpty && model.adoptFilter == .adoptable {
                Placeholder(
                    title: "Nothing to adopt",
                    message: "Every app we found is either already managed by Homebrew or has no matching cask.",
                    systemImage: "checkmark.circle"
                )
            } else {
                List(selection: $model.adoptSelection) {
                    if !candidates.isEmpty {
                        Section("Matched to a cask") {
                            ForEach(candidates) { candidate in
                                AdoptRow(candidate: candidate)
                                    .tag(candidate.id)
                                    .contextMenu {
                                        if candidate.canAdopt {
                                            Button("Adopt") { model.adopt(candidate) }
                                        }
                                        Button("Show in Finder") { model.revealApp(candidate.app) }
                                    }
                            }
                        }
                    }
                    if model.adoptFilter == .all {
                        Section("No matching cask") {
                            ForEach(model.unmatchedApps) { app in
                                UnmatchedRow(app: app)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
        // Keyed on the scan result, not a bare `.task`: the app scan usually
        // finishes *after* this view first appears, so a one-shot task would run
        // while there was nothing to probe and never run again.
        .task(id: model.installedApps.count) {
            // The probe is also what makes macOS show its permission prompt, so
            // running it here asks at the moment it makes sense.
            guard !model.installedApps.isEmpty else { return }
            await model.checkAppManagement()
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text("\(model.readyToAdoptCount) ready · \(model.installedApps.count) apps scanned")
                Spacer()
                Button("Adopt All Ready") { model.adoptAllReady() }
                    .buttonStyle(.link)
                    .help("Adopt every app marked ready, one after another. Apps with version differences and App Store apps are skipped.")
                    .disabled(model.readyToAdoptCount == 0 || model.operations.isBusy)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

/// The app's real icon, straight from the bundle.
struct AppIcon: View {
    let path: String
    var size: CGFloat = 28

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct AdoptRow: View {
    let candidate: AdoptionCandidate

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(path: candidate.app.path)

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.app.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("Cask: \(candidate.cask.token)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Pill(text: candidate.readiness.title, systemImage: symbol, tint: tint)
                    if candidate.bundleIDConfirmed {
                        Pill(text: "ID verified", systemImage: "checkmark.seal", tint: .secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(candidate.app.shortVersion ?? candidate.app.bundleVersion ?? "—")
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                if !AdoptionMatcher.versionsAgree(app: candidate.app, cask: candidate.cask) {
                    Text(candidate.cask.version.split(separator: ",").first.map(String.init) ?? candidate.cask.version)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var tint: Color {
        switch candidate.readiness {
        case .ready: .green
        case .versionMismatch: .orange
        case .appStore: .secondary
        }
    }

    private var symbol: String {
        switch candidate.readiness {
        case .ready: "checkmark.circle.fill"
        case .versionMismatch: "exclamationmark.triangle.fill"
        case .appStore: "bag"
        }
    }
}

struct UnmatchedRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: app.path, size: 22)
                .opacity(0.6)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.displayName)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                if app.isMacAppStore {
                    Text("From the App Store")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Text(app.shortVersion ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Detail

struct AdoptDetailView: View {
    @Environment(AppModel.self) private var model

    private var candidate: AdoptionCandidate? {
        model.adoptSelection.flatMap { model.candidate(id: $0) }
    }

    var body: some View {
        if let candidate {
            AdoptDetailBody(candidate: candidate)
                .id(candidate.id)
        } else if model.appManagementStatus == .denied {
            ScrollView {
                AppManagementBanner()
                    .padding(20)
                    .frame(maxWidth: 720, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            Placeholder(
                title: "Adopt an app you already have",
                message: "Homebrew can take over an app you installed by hand, so future updates come from brew. Pick one from the list.",
                systemImage: "app.badge.checkmark"
            )
        }
    }
}

private struct AdoptDetailBody: View {
    @Environment(AppModel.self) private var model
    let candidate: AdoptionCandidate

    @State private var showReplaceConfirm = false

    private var app: InstalledApp { candidate.app }
    private var cask: CatalogEntry { candidate.cask }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actions
                if model.appManagementStatus == .denied {
                    AppManagementBanner()
                }
                readinessBanner
                detailsCard
                commandCard
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .confirmationDialog(
            "Replace \(app.displayName) with Homebrew's copy?",
            isPresented: $showReplaceConfirm,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) { model.replaceWithCask(candidate) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the copy at \(app.path) and installs version \(cask.version) in its place. App data and preferences are kept, but any changes inside the app bundle are lost.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            AppIcon(path: app.path, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                Text(app.displayName)
                    .font(.largeTitle.weight(.semibold))
                    .textSelection(.enabled)
                if let desc = cask.desc {
                    Text(desc)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Pill(text: "Not managed by Homebrew", systemImage: "questionmark.circle", tint: .orange)
                    if candidate.bundleIDConfirmed {
                        Pill(text: "Bundle ID verified", systemImage: "checkmark.seal", tint: .green)
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                model.adopt(candidate)
            } label: {
                Label("Adopt", systemImage: "app.badge.checkmark")
            }
            .buttonStyle(.borderedProminent)
            .help(candidate.canAdopt
                  ? "Runs brew install --cask --adopt \(cask.token). Your copy stays where it is — Homebrew just starts managing it."
                  : "Homebrew won't adopt this one. See the note below for why.")
            .disabled(!candidate.canAdopt || model.operations.isBusy)

            if candidate.readiness == .versionMismatch {
                Button("Replace…", role: .destructive) {
                    showReplaceConfirm = true
                }
                .help("Delete your copy and install the cask's version over it")
                .disabled(model.operations.isBusy)
            }

            Spacer()

            Button {
                model.selection = cask.asRef
                model.section = .browse
            } label: {
                Label("View Cask", systemImage: "square.grid.2x2")
            }
            .help("Show the \(cask.token) cask in Browse")
            Button {
                model.revealApp(app)
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .labelStyle(.iconOnly)
            }
            .help("Reveal in Finder")
        }
    }

    @ViewBuilder
    private var readinessBanner: some View {
        switch candidate.readiness {
        case .ready:
            banner(
                symbol: "checkmark.circle.fill",
                tint: .green,
                title: "Ready to adopt",
                body: cask.autoUpdates
                    ? "This cask is marked as self-updating, so Homebrew adopts it without comparing versions. Your copy stays exactly where it is — brew just starts tracking it."
                    : "Your version matches the cask, so Homebrew will adopt your copy in place rather than reinstalling it."
            )
        case .versionMismatch:
            banner(
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Versions don't match",
                body: "You have \(app.shortVersion ?? "an unknown version") and the cask ships \(cask.version). Homebrew only adopts an identical copy, so it will refuse — safely, leaving your app untouched. Update the app to \(cask.version) and adopt then, or replace it with Homebrew's copy."
            )
        case .appStore:
            banner(
                symbol: "bag.fill",
                tint: .secondary,
                title: "Installed from the App Store",
                body: "The App Store will keep updating this app on its own, which would fight with Homebrew over the same bundle. Adopt it only if you first delete it and let brew install a fresh copy."
            )
        }
    }

    private func banner(symbol: String, tint: Color, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var detailsCard: some View {
        SectionCard(title: "Match", systemImage: "arrow.triangle.merge") {
            VStack(alignment: .leading, spacing: 6) {
                InfoRow("Your version", app.shortVersion ?? app.bundleVersion ?? "unknown")
                InfoRow("Cask version", cask.version)
                InfoRow("Cask", cask.token)
                if let tap = cask.tap { InfoRow("Tap", tap) }
                InfoRow("Self-updating", cask.autoUpdates ? "Yes — brew won't compare versions" : "No")
                if let bundleID = app.bundleID {
                    InfoRow("Bundle identifier", bundleID)
                }
                InfoRow("Location", app.path)
                InfoRow("Matched on", candidate.bundleIDConfirmed
                        ? "App name and bundle identifier"
                        : "App name (\(app.fileName))")
                if let homepage = cask.homepage {
                    InfoRow(label: "Homepage") {
                        Button(homepage) { model.openHomepage(homepage) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var commandCard: some View {
        let arguments = candidate.canAdopt
            ? ["install", "--cask", "--adopt", cask.token]
            : ["install", "--cask", "--force", cask.token]
        let command = (["brew"] + arguments).joined(separator: " ")
        return SectionCard(title: "Command line", systemImage: "terminal") {
            HStack(spacing: 8) {
                Text(command)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                }
                .help("Copy command")
                Button {
                    model.openInTerminal(arguments)
                } label: {
                    Label("Run in Terminal", systemImage: "apple.terminal").labelStyle(.iconOnly)
                }
                .help("Run this in Terminal instead")
            }
        }
    }
}
