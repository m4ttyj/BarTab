import AppKit
import SwiftUI

/// Explains the App Management permission and gets the user to the right place.
///
/// Homebrew's own error says "your terminal does not have App Management
/// permissions", which is misleading here: brew is running as part of BarTab, so
/// macOS asks about BarTab. Granting the permission to Terminal changes nothing.
/// The copy below says so explicitly, because that's the bit people get wrong.
///
/// Layout note: only put this in the wide detail pane. `fixedSize` is needed so
/// the paragraphs wrap instead of truncating, but in the narrow list column that
/// same modifier leaves the window with no drawable content at all. Use
/// `AppManagementNotice` in the list column instead.
struct AppManagementBanner: View {
    @Environment(AppModel.self) private var model

    /// Shown after an operation already failed, rather than as a pre-flight warning.
    var afterFailure = false

    private var title: String {
        afterFailure
            ? "That failed because BarTab can't manage apps yet"
            : "BarTab needs permission to manage apps"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(title)
                    .fontWeight(.semibold)
            }

            Text("macOS requires the App Management permission before an app can change another app that is already installed. Adopting, upgrading and removing casks all need it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Grant it to BarTab, not to Terminal — brew runs as part of BarTab, so BarTab is what macOS asks about.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Privacy & Security → App Management → switch on BarTab")
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)

            Text("You can adopt without it, but Homebrew may then delete and reinstall the app rather than taking over the copy you already have — which can lose its place in the Dock and its notification settings.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("If BarTab is not listed, add it with the + button. Already switched it on and still seeing this? Quit BarTab and open it again.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    model.openAppManagementSettings()
                } label: {
                    Label("Open System Settings", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .help("Jump straight to Privacy & Security → App Management")

                HStack(spacing: 6) {
                    Button("Check Again") {
                        Task { await model.checkAppManagement() }
                    }
                    .help("Re-test whether macOS will let BarTab modify an installed app")
                    .disabled(model.isCheckingAppManagement)

                    Button("Quit BarTab") { NSApp.terminate(nil) }
                        .help("Quit so you can reopen BarTab and pick up the new permission")

                    if model.isCheckingAppManagement {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(.top, 2)
        }
        .font(.callout)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }
}


/// One-line version for the narrow list column, where the full banner's text
/// wrapping cannot be made to behave. Deliberately short enough not to need
/// `fixedSize`, which breaks layout at that width.
struct AppManagementNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("BarTab needs App Management permission")
                .font(.callout)
                .lineLimit(2)
            Button("Fix…") { model.openAppManagementSettings() }
                .controlSize(.small)
                .help("Open Privacy & Security → App Management and switch on BarTab")
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.13))
    }
}
