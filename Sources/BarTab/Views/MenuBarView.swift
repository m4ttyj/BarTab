import AppKit
import SwiftUI

/// The menu bar item's label: a mug, carrying a count when something is waiting.
///
/// The count is composited into a template image rather than passed as a `Label`
/// title: SwiftUI renders a `MenuBarExtra` label icon-only and silently drops the
/// text, so the number never appeared.
enum MenuBarIcon {
    @MainActor
    static func image(pending: Int) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let name = pending > 0 ? "mug.fill" : "mug"
        guard let mug = NSImage(systemSymbolName: name, accessibilityDescription: "BarTab")?
            .withSymbolConfiguration(configuration)
        else { return NSImage() }

        guard pending > 0 else {
            mug.isTemplate = true
            return mug
        }

        let label = "\(pending)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            // Template images are reduced to a mask, so this colour only needs
            // to be opaque — the menu bar picks the final appearance.
            .foregroundColor: NSColor.black,
        ]
        let labelSize = label.size(withAttributes: attributes)
        let gap: CGFloat = 2
        let size = NSSize(
            width: mug.size.width + gap + ceil(labelSize.width),
            height: max(mug.size.height, ceil(labelSize.height))
        )

        let composed = NSImage(size: size)
        composed.lockFocus()
        mug.draw(
            at: NSPoint(x: 0, y: (size.height - mug.size.height) / 2),
            from: .zero, operation: .sourceOver, fraction: 1
        )
        label.draw(
            at: NSPoint(x: mug.size.width + gap, y: (size.height - labelSize.height) / 2),
            withAttributes: attributes
        )
        composed.unlockFocus()
        composed.isTemplate = true
        return composed
    }
}

struct MenuBarLabel: View {
    let pending: Int

    var body: some View {
        Image(nsImage: MenuBarIcon.image(pending: pending))
    }
}

/// Contents of the menu bar item. In `.menu` style SwiftUI renders `Button` as a
/// menu item, `Text` as a disabled one and `Divider` as a separator.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model

    /// Enough to be useful without turning the menu into the Updates list.
    private static let visibleLimit = 12

    var body: some View {
        Text(summary)

        if let release = model.availableAppUpdate {
            Divider()
            Button("BarTab \(release.version) is available — what's new…") {
                model.openAppReleasePage()
            }
            if model.isSelfManagedByHomebrew {
                Button("Update BarTab with Homebrew…") { model.upgradeSelfInTerminal() }
            }
        }

        if !model.outdated.isEmpty {
            Divider()
            ForEach(model.outdated.prefix(Self.visibleLimit)) { item in
                Button("\(item.token)  \(item.installedVersionText) → \(item.currentVersion)") {
                    model.upgrade(item.asRef)
                }
                .disabled(item.pinned || model.operations.isBusy)
            }
            if model.outdated.count > Self.visibleLimit {
                Text("and \(model.outdated.count - Self.visibleLimit) more…")
            }
            Divider()
            Button("Upgrade All") { model.upgradeAll() }
                .disabled(model.upgradableCount == 0 || model.operations.isBusy)
        }

        Divider()
        Button("Check for Updates") { model.updateHomebrew(showActivity: false) }
            .disabled(model.operations.isBusy)
        Button("Open BarTab") { MenuBarMenu.activateMainWindow() }
        Divider()
        Button("Quit BarTab") { NSApp.terminate(nil) }
    }

    private var summary: String {
        if model.operations.isBusy {
            return model.operations.current?.title ?? "Working…"
        }
        switch model.outdated.count {
        case 0: return "Everything is up to date"
        case 1: return "1 update available"
        case let count: return "\(count) updates available"
        }
    }

    /// Brings the existing window forward. Deliberately doesn't open a new one:
    /// the app keeps its Dock icon, so reopening a closed window is the Dock's job.
    static func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}

/// Compact notice for the Updates list when a newer BarTab has been published.
/// Short by design — the narrow column can't take wrapped paragraphs.
struct AppUpdateNotice: View {
    @Environment(AppModel.self) private var model
    let release: AppRelease

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("BarTab \(release.version) available")
                .font(.callout)
                .lineLimit(1)
            Button("What's New…") { model.openAppReleasePage() }
                .controlSize(.small)
                .help("Open the release notes on GitHub")
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.10))
    }
}
