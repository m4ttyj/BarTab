import SwiftUI

struct UpdatesListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let items = model.outdatedList

        VStack(spacing: 0) {
            header
            Divider()

            if let release = model.availableAppUpdate {
                AppUpdateNotice(release: release)
                Divider()
            }

            if model.appManagementStatus == .denied, model.hasOutdatedCasks {
                AppManagementNotice()
                Divider()
            }

            if items.isEmpty {
                Placeholder(
                    title: model.isLoadingLocal ? "Checking…" : "Everything is up to date",
                    message: model.isLoadingLocal ? nil : "Checked \(Format.relative(model.lastLocalRefresh)), against definitions updated \(Format.relative(model.lastHomebrewUpdate)).",
                    systemImage: model.isLoadingLocal ? "hourglass" : "checkmark.circle"
                )
            } else {
                List(selection: $model.selection) {
                    ForEach(items) { item in
                        OutdatedRow(item: item, installed: model.installedPackage(item.asRef))
                            .tag(item.asRef)
                            .contextMenu {
                                Button("Upgrade") { model.upgrade(item.asRef) }
                                    .disabled(item.pinned)
                                if item.kind == .formula {
                                    Button(item.pinned ? "Unpin" : "Pin") {
                                        model.setPinned(item.asRef, pinned: !item.pinned)
                                    }
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    /// The content column can be dragged down to 260pt, where all three controls
    /// on one line truncate the primary action to "Upgrad…". `ViewThatFits`
    /// measures the roomy layout first and falls back to a stacked one, which
    /// avoids guessing at a breakpoint or forcing sizes with `fixedSize`.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                upgradeAllButton
                Spacer(minLength: 0)
                selfUpdatingToggle
                checkForUpdatesButton
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    upgradeAllButton
                    Spacer(minLength: 8)
                    checkForUpdatesButton
                }
                selfUpdatingToggle
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var upgradeAllButton: some View {
        Button {
            model.upgradeAll()
        } label: {
            Label("Upgrade All", systemImage: "arrow.up.circle.fill")
                .lineLimit(1)
        }
        .buttonStyle(.borderedProminent)
        .help("Runs brew upgrade — updates every package listed here except pinned ones")
        .disabled(model.upgradableCount == 0 || model.operations.isBusy)
    }

    private var selfUpdatingToggle: some View {
        @Bindable var model = model

        // Kept short on purpose: this label's width is what decides whether the
        // roomy single-row header still fits at the default column width.
        return Toggle("Self-updating", isOn: $model.includeSelfUpdatingCasks)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.caption)
            .lineLimit(1)
            .help("Also list casks that update themselves, like Chrome and Slack. Homebrew hides these by default because upgrading them rarely does anything.")
    }

    private var checkForUpdatesButton: some View {
        Button {
            model.updateHomebrew(showActivity: false)
        } label: {
            Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                .labelStyle(.iconOnly)
        }
        .help("Fetch the newest package definitions and re-check — runs brew update, then brew outdated")
        .disabled(model.operations.isBusy)
    }
}

struct OutdatedRow: View {
    let item: OutdatedPackage
    let installed: InstalledPackage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.symbol)
                .foregroundStyle(item.kind == .formula ? .orange : .blue)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(installed?.name ?? item.token)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if item.pinned { Pill(text: "Pinned", systemImage: "pin.fill", tint: .orange) }
                }
                HStack(spacing: 5) {
                    Text(item.installedVersionText)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(item.currentVersion)
                        .foregroundStyle(.green)
                        .fontWeight(.medium)
                }
                .font(.caption.monospacedDigit())
            }

            Spacer(minLength: 6)
        }
        .padding(.vertical, 3)
    }
}
