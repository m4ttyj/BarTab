import SwiftUI

enum MaintenanceTask: String, CaseIterable, Identifiable, Hashable {
    case doctor, cleanup, autoremove, update

    var id: String { rawValue }

    var title: String {
        switch self {
        case .doctor: "Health Check"
        case .cleanup: "Clean Up"
        case .autoremove: "Unused Dependencies"
        case .update: "Update Homebrew"
        }
    }

    var subtitle: String {
        switch self {
        case .doctor: "Look for problems with your install"
        case .cleanup: "Delete old versions and cached downloads"
        case .autoremove: "Remove dependencies nothing needs any more"
        case .update: "Fetch the latest package definitions"
        }
    }

    var symbol: String {
        switch self {
        case .doctor: "stethoscope"
        case .cleanup: "trash"
        case .autoremove: "leaf"
        case .update: "arrow.triangle.2.circlepath"
        }
    }
}

struct MaintenanceListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: MaintenanceTask?

    var body: some View {
        List(selection: $selection) {
            ForEach(MaintenanceTask.allCases) { task in
                HStack(spacing: 10) {
                    Image(systemName: task.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title).fontWeight(.medium)
                        Text(task.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    badge(for: task)
                }
                .padding(.vertical, 3)
                .tag(task)
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func badge(for task: MaintenanceTask) -> some View {
        switch task {
        case .doctor:
            if let report = model.doctorReport {
                Image(systemName: report.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(report.isHealthy ? .green : .orange)
            }
        case .cleanup:
            if let preview = model.cleanupPreview, preview.reclaimableBytes > 0 {
                Text(Format.bytes(preview.reclaimableBytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .autoremove, .update:
            EmptyView()
        }
    }
}

struct MaintenanceDetailView: View {
    @Environment(AppModel.self) private var model
    let task: MaintenanceTask?

    var body: some View {
        Group {
            switch task {
            case .doctor: doctorPane
            case .cleanup: cleanupPane
            case .autoremove: autoremovePane
            case .update: updatePane
            case nil:
                Placeholder(title: "Pick a maintenance task", systemImage: "stethoscope")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Doctor

    private var doctorPane: some View {
        pane(
            title: "Health Check",
            blurb: "`brew doctor` inspects your install for anything that could make builds fail — stray files in the prefix, broken symlinks, unexpected dylibs. Warnings are common and usually harmless.",
            primary: {
                Button {
                    Task { await model.runDoctor() }
                } label: {
                    if model.isRunningDoctor {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Running…") }
                    } else {
                        Label("Run Health Check", systemImage: "stethoscope")
                    }
                }
                .buttonStyle(.borderedProminent)
                .help("Runs brew doctor. Read-only — it reports problems, it doesn't change anything.")
                .disabled(model.isRunningDoctor)
            },
            content: {
                if let report = model.doctorReport {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            report.isHealthy ? "Your system is ready to brew." : "brew doctor found some notes",
                            systemImage: report.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(report.isHealthy ? .green : .orange)
                        .font(.headline)

                        if !report.output.isEmpty {
                            OutputBlock(text: report.output)
                        }
                    }
                }
            }
        )
    }

    // MARK: Cleanup

    private var cleanupPane: some View {
        pane(
            title: "Clean Up",
            blurb: "Homebrew keeps old versions and every downloaded bottle. `brew cleanup` removes them. Nothing you have installed is affected.",
            primary: {
                HStack(spacing: 8) {
                    Button {
                        Task { await model.checkCleanup() }
                    } label: {
                        if model.isCheckingCleanup {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
                        } else {
                            Label("See What Can Be Freed", systemImage: "magnifyingglass")
                        }
                    }
                    .help("Runs brew cleanup --dry-run. Reports what would be deleted without deleting it.")
                    .disabled(model.isCheckingCleanup)

                    Button {
                        model.runCleanup()
                    } label: {
                        Label("Clean Up Now", systemImage: "trash")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Runs brew cleanup --prune=all -s. Deletes old versions and cached downloads — installed packages are untouched.")
                    .disabled(model.operations.isBusy)
                }
            },
            content: {
                if let preview = model.cleanupPreview {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(preview.reclaimableBytes > 0
                             ? "About \(Format.bytes(preview.reclaimableBytes)) can be freed."
                             : "Nothing to clean up.")
                            .font(.headline)
                        if !preview.output.isEmpty {
                            OutputBlock(text: preview.output)
                        }
                    }
                }
            }
        )
    }

    // MARK: Autoremove

    private var autoremovePane: some View {
        pane(
            title: "Unused Dependencies",
            blurb: "Formulae that were only installed to satisfy something else, where that something else is now gone. `brew autoremove` deletes them.",
            primary: {
                Button {
                    model.runAutoremove()
                } label: {
                    Label("Remove Unused Dependencies", systemImage: "leaf")
                }
                .buttonStyle(.borderedProminent)
                .help("Runs brew autoremove. Uninstalls formulae that were only there for something you've since removed.")
                .disabled(model.operations.isBusy)
            },
            content: {
                let orphans = model.installed.filter { $0.kind == .formula && !$0.installedOnRequest }
                Text("\(orphans.count) of your \(model.counts.formulae) formulae were installed as dependencies. Homebrew will only remove the ones nothing still needs.")
                    .foregroundStyle(.secondary)
            }
        )
    }

    // MARK: Update

    private var updatePane: some View {
        @Bindable var model = model

        return pane(
            title: "Update Homebrew",
            blurb: "Pulls the newest formula and cask definitions, then re-checks what's outdated. BarTab does this for you shortly after it opens, so you shouldn't normally need the button.",
            primary: {
                Button {
                    model.updateHomebrew()
                } label: {
                    Label("Update Homebrew", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .help("Runs brew update. Fetches the newest formula and cask definitions — it doesn't upgrade anything yet.")
                .disabled(model.operations.isBusy)
            },
            content: {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Update definitions when BarTab opens", isOn: $model.autoUpdateOnLaunch)
                        .help("Runs brew update in the background after launch, then re-checks for updates")
                    Text("At most once an hour, and skipped if a command is already running. A refresh that fails is retried next time you open BarTab.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        InfoRow("Definitions updated", Format.relative(model.lastHomebrewUpdate))
                        InfoRow("Homebrew version", model.brewVersion.isEmpty ? "—" : model.brewVersion)
                        InfoRow("Prefix", model.env?.prefix.path ?? "—")
                        InfoRow("Packages installed", "\(model.installed.count)")
                        InfoRow("Disk used", Format.bytes(model.totalInstalledSize))
                    }
                }
            }
        )
    }

    // MARK: Shell

    private func pane<Primary: View, Content: View>(
        title: String,
        blurb: String,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.largeTitle.weight(.semibold))
                Text(.init(blurb))
                    .foregroundStyle(.secondary)
                primary()
                content()
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

/// Monospaced, scrollable, selectable block of command output.
struct OutputBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
