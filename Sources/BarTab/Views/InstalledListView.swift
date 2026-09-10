import SwiftUI

struct InstalledListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let packages = model.installedList

        VStack(spacing: 0) {
            Picker("Filter", selection: $model.installedFilter) {
                ForEach(InstalledFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Narrow the list. \u{201C}Top level\u{201D} shows only what you installed yourself, hiding packages that came along as dependencies.")
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if model.isLoadingLocal && model.installed.isEmpty {
                Placeholder(title: "Reading your Homebrew install…", systemImage: "hourglass")
            } else if let error = model.localError, model.installed.isEmpty {
                Placeholder(title: "Couldn't read installed packages", message: error, systemImage: "exclamationmark.triangle")
            } else if packages.isEmpty {
                Placeholder(
                    title: model.installedSearch.isEmpty ? "Nothing installed" : "No matches",
                    message: model.installedSearch.isEmpty ? "Head to Browse to install something." : nil,
                    systemImage: "magnifyingglass"
                )
            } else {
                List(selection: $model.selection) {
                    ForEach(packages) { package in
                        InstalledRow(package: package, size: model.size(package.asRef))
                            .tag(package.asRef)
                            .contextMenu { contextMenu(for: package) }
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $model.installedSearch, placement: .toolbar, prompt: "Search installed")
        .safeAreaInset(edge: .bottom) { summaryBar }
    }

    @ViewBuilder
    private func contextMenu(for package: InstalledPackage) -> some View {
        if model.outdatedEntry(package.asRef) != nil {
            Button("Upgrade") { model.upgrade(package.asRef) }
        }
        Button("Reinstall") { model.reinstall(package.asRef) }
        if package.kind == .formula {
            Button(package.pinned ? "Unpin" : "Pin at \(package.installedVersion)") {
                model.setPinned(package.asRef, pinned: !package.pinned)
            }
        }
        Divider()
        Button("Show in Finder") { model.revealInFinder(package.asRef) }
        if let homepage = package.homepage {
            Button("Open Homepage") { model.openHomepage(homepage) }
        }
        Divider()
        Button("Uninstall…", role: .destructive) { model.selection = package.asRef }
    }

    private var summaryBar: some View {
        let counts = model.counts
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Text("\(counts.formulae) formulae · \(counts.casks) casks")
                Spacer()
                if model.totalInstalledSize > 0 {
                    Text(Format.bytes(model.totalInstalledSize))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

struct InstalledRow: View {
    let package: InstalledPackage
    let size: Int64?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: package.kind.symbol)
                .foregroundStyle(package.kind == .formula ? .orange : .blue)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if package.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
                    if package.deprecated { Pill(text: "Deprecated", tint: .red) }
                    // Most formulae are dependencies, so flag the few you chose
                    // yourself rather than badging almost every row.
                    if package.kind == .formula, package.installedOnRequest {
                        Pill(text: "Top level", tint: .accentColor)
                    }
                }
                if let desc = package.desc {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(package.installedVersion)
                    .font(.caption.monospacedDigit())
                    .lineLimit(1)
                if let size {
                    Text(Format.bytes(size))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

extension InstalledPackage {
    var asRef: PackageRef { PackageRef(kind: kind, token: token) }
}

extension OutdatedPackage {
    var asRef: PackageRef { PackageRef(kind: kind, token: token) }
}

extension CatalogEntry {
    var asRef: PackageRef { PackageRef(kind: kind, token: token) }
}
