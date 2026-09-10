import AppKit
import SwiftUI

struct ActivityListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var operations = model.operations

        VStack(spacing: 0) {
            if model.operations.operations.isEmpty {
                Placeholder(
                    title: "Nothing has run yet",
                    message: "Installs, upgrades and removals show up here with their full output.",
                    systemImage: "list.bullet.rectangle"
                )
            } else {
                List(selection: $operations.selectedOperationID) {
                    ForEach(model.operations.operations) { operation in
                        OperationRow(operation: operation)
                            .tag(operation.id)
                    }
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text("\(model.operations.operations.count) operation\(model.operations.operations.count == 1 ? "" : "s")")
                    Spacer()
                    Button("Clear Finished") { model.operations.clearFinished() }
                        .buttonStyle(.link)
                        .help("Remove completed operations from this list. Running ones stay.")
                        .disabled(model.operations.operations.allSatisfy { !$0.status.isTerminal })
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(.bar)
        }
    }
}

struct OperationRow: View {
    @Bindable var operation: BrewOperation

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(status: operation.status)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 3)
    }

    private var statusText: String {
        switch operation.status {
        case .queued: "Queued"
        case .running: operation.log.last?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "Running…"
        case .succeeded: "Done in \(Format.duration(operation.duration))"
        case .failed(let code): "Failed (exit \(code))"
        case .cancelled: "Cancelled"
        }
    }
}

struct StatusIcon: View {
    let status: OperationStatus

    var body: some View {
        switch status {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        }
    }
}

struct ActivityDetailView: View {
    @Environment(AppModel.self) private var model

    private var operation: BrewOperation? {
        guard let id = model.operations.selectedOperationID else { return model.operations.operations.first }
        return model.operations.operations.first { $0.id == id }
    }

    var body: some View {
        if let operation {
            OperationLogView(operation: operation)
                .id(operation.id)
        } else {
            Placeholder(title: "No operation selected", systemImage: "text.alignleft")
        }
    }
}

struct OperationLogView: View {
    @Environment(AppModel.self) private var model
    @Bindable var operation: BrewOperation
    @State private var autoScroll = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if operation.needsTerminal { terminalBanner }
            Divider()
            logBody
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusIcon(status: operation.status)
                Text(operation.title)
                    .font(.title2.weight(.semibold))
                Spacer()
                if operation.status == .running {
                    Button("Cancel", role: .destructive) { operation.cancel() }
                        .help("Stop this command now. A half-finished install may need brew cleanup afterwards.")
                }
            }
            HStack(spacing: 8) {
                Text(operation.commandLine)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(operation.commandLine, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy command")
                Spacer()
                Toggle("Follow", isOn: $autoScroll)
                    .help("Keep scrolling to the newest line as output arrives")
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.caption)
            }
        }
        .padding(16)
    }

    private var terminalBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "key.horizontal")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("This command needs an administrator password")
                    .fontWeight(.medium)
                Text("A GUI can't answer sudo's prompt safely. Run it in Terminal instead — the exact command is prefilled.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Run in Terminal") { model.operations.openInTerminal(operation) }
                .buttonStyle(.borderedProminent)
                .help("Open this exact command in Terminal, where you can type your password")
        }
        .padding(12)
        .background(.orange.opacity(0.12))
    }

    private var logBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(operation.log.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: operation.log.count) {
                guard autoScroll else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
