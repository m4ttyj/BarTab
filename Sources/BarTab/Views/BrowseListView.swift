import SwiftUI

struct BrowseListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let results = model.browseResults

        VStack(spacing: 0) {
            Picker("Filter", selection: $model.browseFilter) {
                ForEach(BrowseFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("Limit the search to command-line formulae or to macOS apps (casks).")
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if model.isLoadingCatalog && model.catalogRows.isEmpty {
                Placeholder(
                    title: "Downloading the catalogue…",
                    message: "Fetching every formula and cask from formulae.brew.sh. This happens once a day.",
                    systemImage: "arrow.down.circle"
                )
            } else if let error = model.catalogError, model.catalogRows.isEmpty {
                Placeholder(title: "Couldn't load the catalogue", message: error, systemImage: "wifi.exclamationmark")
            } else if results.isEmpty {
                Placeholder(title: "No matches", message: "Try a different search term.", systemImage: "magnifyingglass")
            } else {
                List(selection: $model.selection) {
                    if model.browseSearch.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Most installed in the last 30 days")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(results) { row in
                        CatalogRowView(entry: row.entry, isInstalled: model.isInstalled(row.entry.asRef))
                            .tag(row.entry.asRef)
                            .contextMenu {
                                if model.isInstalled(row.entry.asRef) {
                                    Button("Uninstall…") { model.selection = row.entry.asRef }
                                } else {
                                    Button("Install") { model.install(row.entry.asRef) }
                                }
                                if let homepage = row.entry.homepage {
                                    Button("Open Homepage") { model.openHomepage(homepage) }
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .searchable(text: $model.browseSearch, placement: .toolbar, prompt: "Search formulae and casks")
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if model.isLoadingCatalog {
                    ProgressView().controlSize(.small)
                    Text("Refreshing catalogue…")
                } else {
                    Text("\(Format.count(model.catalogRows.count)) packages · updated \(Format.relative(model.catalogFetchedAt))")
                }
                Spacer()
                Button("Refresh") {
                    Task { await model.loadCatalog(forceRefresh: true) }
                }
                .buttonStyle(.link)
                .help("Re-download the full package list from formulae.brew.sh")
                .disabled(model.isLoadingCatalog)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

struct CatalogRowView: View {
    let entry: CatalogEntry
    let isInstalled: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.kind.symbol)
                .foregroundStyle(entry.kind == .formula ? .orange : .blue)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    if isInstalled {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if entry.deprecated { Pill(text: "Deprecated", tint: .red) }
                }
                if let desc = entry.desc {
                    Text(desc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(entry.version)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if entry.installs30d > 0 {
                    Text("\(Format.count(entry.installs30d))↓")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
