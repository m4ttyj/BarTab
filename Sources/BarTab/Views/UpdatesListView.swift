import SwiftUI

struct UpdatesListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let items = model.outdatedList

        VStack(spacing: 0) {
            header
            Divider()

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

    private var header: some View {
        @Bindable var model = model

        return HStack(spacing: 8) {
            Button {
                model.upgradeAll()
            } label: {
                Label("Upgrade All", systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("Runs brew upgrade — updates every package listed here except pinned ones")
            .disabled(model.upgradableCount == 0 || model.operations.isBusy)

            Spacer()

            Toggle("Self-updating apps", isOn: $model.includeSelfUpdatingCasks)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Also list casks like Chrome and Slack that update themselves")

            Button {
                model.updateHomebrew(showActivity: false)
            } label: {
                Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.iconOnly)
            }
            .help("Fetch the newest package definitions and re-check — runs brew update, then brew outdated")
            .disabled(model.operations.isBusy)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
