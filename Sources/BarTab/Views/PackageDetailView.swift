import AppKit
import SwiftUI

struct PackageDetailView: View {
    @Environment(AppModel.self) private var model
    let ref: PackageRef

    @State private var dependents: [String] = []
    @State private var loadedDependents = false
    @State private var showUninstallConfirm = false
    @State private var showForgetConfirm = false
    @State private var showZapConfirm = false

    private var installed: InstalledPackage? { model.installedPackage(ref) }
    private var catalog: CatalogEntry? { model.catalogEntry(ref) }
    private var outdated: OutdatedPackage? { model.outdatedEntry(ref) }

    private var title: String { installed?.name ?? catalog?.name ?? ref.token }
    private var desc: String? { installed?.desc ?? catalog?.desc }
    private var homepage: String? { installed?.homepage ?? catalog?.homepage }
    private var caveats: String? { installed?.caveats ?? catalog?.caveats }
    private var dependencies: [String] { installed?.dependencies ?? catalog?.dependencies ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                actionBar
                if installed?.isOrphaned == true { orphanBanner }
                if ref.kind == .cask, installed != nil, model.appManagementStatus == .denied {
                    AppManagementBanner()
                }
                deprecationBanner
                detailsCard
                if !dependencies.isEmpty { dependenciesCard }
                if installed != nil { dependentsCard }
                if let caveats { caveatsCard(caveats) }
                commandCard
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: ref.id) {
            loadedDependents = false
            dependents = []
            guard installed != nil else { loadedDependents = true; return }
            dependents = await model.dependents(of: ref)
            loadedDependents = true
        }
        .confirmationDialog(
            "Uninstall \(ref.token)?",
            isPresented: $showUninstallConfirm,
            titleVisibility: .visible
        ) {
            Button("Uninstall", role: .destructive) { model.uninstall(ref) }
            if ref.kind == .cask {
                Button("Uninstall and Remove All Data", role: .destructive) { showZapConfirm = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if dependents.isEmpty {
                Text("This removes \(ref.token) from \(ref.kind == .formula ? "the Cellar" : "your Mac").")
            } else {
                Text("\(dependents.count) installed package\(dependents.count == 1 ? "" : "s") depend on this: \(dependents.prefix(6).joined(separator: ", "))\(dependents.count > 6 ? "…" : ""). Removing it will likely break them.")
            }
        }
        .confirmationDialog(
            "Remove \(ref.token) from Homebrew?",
            isPresented: $showForgetConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) { model.forgetOrphanedCask(ref) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Homebrew stops tracking \(ref.token). Nothing is deleted — the app is already gone. You can install it again at any time.")
        }
        .confirmationDialog(
            "Remove all data for \(ref.token)?",
            isPresented: $showZapConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove Everything", role: .destructive) { model.uninstall(ref, zap: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("`brew uninstall --zap` also deletes preferences, caches and application support files. This can't be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                    .textSelection(.enabled)
                KindBadge(kind: ref.kind)
            }
            if title != ref.token {
                Text(ref.token)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let desc {
                Text(desc)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                if installed != nil {
                    Pill(text: "Installed", systemImage: "checkmark.circle.fill", tint: .green)
                }
                if outdated != nil {
                    Pill(text: "Update available", systemImage: "arrow.up.circle.fill", tint: .accentColor)
                }
                if installed?.pinned == true {
                    Pill(text: "Pinned", systemImage: "pin.fill", tint: .orange)
                }
                if installed?.kegOnly == true {
                    Pill(text: "Keg-only", systemImage: "lock", tint: .secondary)
                }
                if installed?.installedOnRequest == false {
                    Pill(text: "Installed as a dependency")
                }
            }
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 8) {
            if installed == nil {
                Button {
                    model.install(ref)
                } label: {
                    Label("Install", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .help("Runs brew install \(ref.kind.brewFlag) \(ref.token)")
                .disabled(catalog?.disabled == true)
            } else {
                if outdated != nil {
                    Button {
                        model.upgrade(ref)
                    } label: {
                        Label("Upgrade", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .help(outdated?.pinned == true
                          ? "Pinned at \(installed?.installedVersion ?? "this version") — unpin it first"
                          : "Runs brew upgrade \(ref.kind.brewFlag) \(ref.token), moving to \(outdated?.currentVersion ?? "the latest version")")
                    .disabled(outdated?.pinned == true)
                }
                Button("Reinstall") { model.reinstall(ref) }
                    .help("Runs brew reinstall \(ref.kind.brewFlag) \(ref.token) — removes and installs the same version again, which fixes a broken install")
                if ref.kind == .formula, let installed {
                    Button(installed.pinned ? "Unpin" : "Pin") {
                        model.setPinned(ref, pinned: !installed.pinned)
                    }
                    .help(installed.pinned
                          ? "Allow this formula to be upgraded again"
                          : "Hold this formula at \(installed.installedVersion)")
                }
                Button("Uninstall…", role: .destructive) { showUninstallConfirm = true }
                    .help("Removes \(ref.token) from your Mac. You'll be asked to confirm, and warned if anything depends on it.")
            }

            Spacer()

            if let homepage {
                Button {
                    model.openHomepage(homepage)
                } label: {
                    Label("Homepage", systemImage: "safari")
                }
                .help("Open the project's website in your browser")
            }
            if installed != nil {
                Button {
                    model.revealInFinder(ref)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .labelStyle(.iconOnly)
                }
                .help("Reveal in Finder")
            }
        }
        .disabled(model.operations.isBusy && installed == nil)
    }

    @ViewBuilder
    private var deprecationBanner: some View {
        let isDeprecated = installed?.deprecated ?? catalog?.deprecated ?? false
        let isDisabled = catalog?.disabled ?? false
        if isDeprecated || isDisabled {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isDisabled ? "This package is disabled" : "This package is deprecated")
                        .fontWeight(.medium)
                    Text(installed?.deprecationReason
                         ?? (isDisabled
                             ? "Homebrew no longer builds or installs it."
                             : "It still works, but it will be removed from Homebrew eventually."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Cards

    /// Shown when Homebrew has a cask registered whose app is no longer on disk.
    private var orphanBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "questionmark.app.dashed")
                    .foregroundStyle(.red)
                Text("The app is missing")
                    .fontWeight(.semibold)
            }

            Text("Homebrew still has \(ref.token) registered, but \(installed?.appNames.first ?? "its app") isn't in your Applications folder — most likely deleted by hand rather than removed with brew.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Until that's settled Homebrew keeps reporting it as installed, and a plain `brew uninstall` refuses to remove it because the app it wants to delete isn't there.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    model.reinstall(ref)
                } label: {
                    Label("Download It Again", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .help("Runs brew reinstall --cask \(ref.token), putting the app back")
                .disabled(model.operations.isBusy)

                Button("Remove from Homebrew…", role: .destructive) { showForgetConfirm = true }
                    .help("Runs brew uninstall --cask --force \(ref.token), so Homebrew stops tracking an app you've already deleted")
                    .disabled(model.operations.isBusy)
            }
            .padding(.top, 2)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
    }

    private var detailsCard: some View {
        SectionCard(title: "Details", systemImage: "info.circle") {
            VStack(alignment: .leading, spacing: 6) {
                if let installed {
                    InfoRow("Installed version", installed.installedVersion)
                }
                if let latest = outdated?.currentVersion ?? installed?.latestVersion ?? catalog?.version {
                    InfoRow(installed == nil ? "Version" : "Latest version", latest)
                }
                if let installedAt = installed?.installedAt {
                    InfoRow("Installed on", Format.date(installedAt))
                }
                if let size = model.size(ref) {
                    InfoRow("Size on disk", Format.bytes(size))
                }
                if let tap = installed?.tap ?? catalog?.tap {
                    InfoRow("Tap", tap)
                }
                if let license = installed?.license ?? catalog?.license {
                    InfoRow("License", license)
                }
                if let installs = catalog?.installs30d, installs > 0 {
                    InfoRow("Installs (30 days)", Format.count(installs))
                }
                if let apps = (installed?.appNames.isEmpty == false ? installed?.appNames : catalog?.appNames),
                   !apps.isEmpty {
                    InfoRow(label: "Apps") { Text(apps.joined(separator: ", ")) }
                }
                if let homepage {
                    InfoRow(label: "Homepage") {
                        Button(homepage) { model.openHomepage(homepage) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var dependenciesCard: some View {
        SectionCard(title: "Dependencies (\(dependencies.count))", systemImage: "point.3.connected.trianglepath.dotted") {
            WrappingTags(items: dependencies) { name in
                if let resolved = model.resolveDependency(name) {
                    model.selection = resolved
                }
            }
        }
    }

    @ViewBuilder
    private var dependentsCard: some View {
        SectionCard(title: "Required by", systemImage: "arrow.turn.up.left") {
            if !loadedDependents {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }
            } else if dependents.isEmpty {
                Text("Nothing else you've installed needs this — safe to remove.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                WrappingTags(items: dependents) { name in
                    if let resolved = model.resolveDependency(name) {
                        model.selection = resolved
                    }
                }
            }
        }
    }

    private func caveatsCard(_ text: String) -> some View {
        SectionCard(title: "Caveats", systemImage: "text.bubble") {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The command that matches what you'd actually want to run right now.
    private var suggestedArguments: [String] {
        if installed == nil { return ["install", ref.kind.brewFlag, ref.token] }
        if outdated != nil { return ["upgrade", ref.kind.brewFlag, ref.token] }
        return ["info", ref.kind.brewFlag, ref.token]
    }

    private var commandCard: some View {
        let arguments = suggestedArguments
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
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .help("Copy command")
                Button {
                    model.openInTerminal(arguments)
                } label: {
                    Label("Run in Terminal", systemImage: "apple.terminal")
                        .labelStyle(.iconOnly)
                }
                .help("Run this in Terminal instead — needed for the few casks that ask for a password")
            }
        }
    }
}
