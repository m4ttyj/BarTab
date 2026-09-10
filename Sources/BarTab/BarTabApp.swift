import SwiftUI

@main
struct BarTabApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .task { await model.start() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(section.title) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
                Divider()
            }
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await model.refreshLocal() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Update Homebrew") { model.updateHomebrew() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Divider()
                Button("Upgrade All Packages") { model.upgradeAll() }
                    .disabled(model.upgradableCount == 0)
            }
            CommandGroup(replacing: .help) {
                Link("Homebrew Documentation", destination: URL(string: "https://docs.brew.sh")!)
            }
        }
    }
}
