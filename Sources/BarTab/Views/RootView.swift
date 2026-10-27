import Combine
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var maintenanceSelection: MaintenanceTask? = .doctor

    var body: some View {
        Group {
            if let setupError = model.setupError {
                BrewMissingView(message: setupError)
            } else {
                splitView
            }
        }
    }

    @ViewBuilder
    private var splitView: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 208, max: 260)
        } content: {
            contentColumn
                .id(model.section)
                .navigationSplitViewColumnWidth(min: 260, ideal: 400, max: 520)
        } detail: {
            detailColumn
        }
        .navigationTitle(model.section.title)
        .toolbar { toolbarContent }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshLocalIfStale() }
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch model.section {
        case .installed: InstalledListView()
        case .updates: UpdatesListView()
        case .browse: BrowseListView()
        case .adopt: AdoptListView()
        case .maintenance: MaintenanceListView(selection: $maintenanceSelection)
        case .activity: ActivityListView()
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch model.section {
        case .installed, .updates, .browse:
            if let ref = model.selection {
                PackageDetailView(ref: ref)
                    .id(ref.id)
            } else {
                Placeholder(
                    title: "Nothing selected",
                    message: "Pick a package from the list to see its details.",
                    systemImage: "sidebar.right"
                )
            }
        case .adopt:
            AdoptDetailView()
        case .maintenance:
            MaintenanceDetailView(task: maintenanceSelection)
        case .activity:
            ActivityDetailView()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if model.operations.isBusy {
                RunningIndicator()
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.refreshLocal() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Re-read what's installed and check for updates")
            .disabled(model.isLoadingLocal)
        }
    }
}

/// Compact spinner + label shown while a brew command is running.
private struct RunningIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.section = .activity
        } label: {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(model.operations.current?.title ?? "Working…")
                    .lineLimit(1)
                    .font(.callout)
            }
        }
        .buttonStyle(.plain)
        .help("Show activity")
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.section) {
            Section("Library") {
                row(.installed, badge: model.installed.count)
                row(.updates, badge: model.outdated.count, badgeIsAlert: !model.outdated.isEmpty)
                row(.browse, badge: nil)
                row(.adopt, badge: model.readyToAdoptCount == 0 ? nil : model.readyToAdoptCount)
            }
            Section("System") {
                row(.maintenance, badge: nil)
                row(.activity, badge: model.operations.pendingCount == 0 ? nil : model.operations.pendingCount)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { statusFooter }
    }

    private func row(_ section: SidebarSection, badge: Int?, badgeIsAlert: Bool = false) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(badge ?? 0)
            .help(section.help)
            .tag(section)
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            Divider()
            HStack(spacing: 5) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.orange)
                Text(model.brewVersion.isEmpty ? "Homebrew" : "Homebrew \(model.brewVersion)")
                    .lineLimit(1)
            }
            Text("Updated \(Format.relative(model.lastLocalRefresh))")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Setup failure

struct BrewMissingView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.orange)
            Text("Homebrew not found")
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Link("Open brew.sh", destination: URL(string: "https://brew.sh")!)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
