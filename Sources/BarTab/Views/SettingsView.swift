import SwiftUI

/// The ⌘, window. Two behaviours worth controlling, plus BarTab's own version.
struct BarTabSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        return Form {
            Section("Menu Bar") {
                Toggle("Show BarTab in the menu bar", isOn: $model.showMenuBarIcon)
                Text("A mug in the menu bar, carrying a count when packages are waiting to be upgraded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Update definitions when BarTab opens", isOn: $model.autoUpdateOnLaunch)
                Text("Runs brew update in the background after launch and re-checks what's outdated — at most once an hour, and retried next launch if it fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Definitions updated", value: Format.relative(model.lastHomebrewUpdate))
            }

            Section("BarTab") {
                LabeledContent("Version", value: model.runningAppVersion)
                LabeledContent("Installed by") {
                    Text(model.isSelfManagedByHomebrew ? "Homebrew" : "Hand (not a cask)")
                }

                if let release = model.availableAppUpdate {
                    LabeledContent("Latest release") {
                        HStack(spacing: 8) {
                            Text(release.version)
                            Button("What's New…") { model.openAppReleasePage() }
                                .buttonStyle(.link)
                        }
                    }
                    if model.isSelfManagedByHomebrew {
                        Button("Update BarTab with Homebrew…") { model.upgradeSelfInTerminal() }
                            .help("Opens the upgrade in Terminal, so it survives BarTab being replaced")
                    }
                } else if let error = model.appUpdateCheckError {
                    LabeledContent("Latest release", value: "Couldn't check")
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Latest release", value: "Up to date")
                }

                Button {
                    Task { await model.checkForAppUpdate(force: true) }
                } label: {
                    if model.isCheckingAppUpdate {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
                    } else {
                        Text("Check for BarTab Updates")
                    }
                }
                .disabled(model.isCheckingAppUpdate)
                .help("Asks GitHub for the newest published release")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
