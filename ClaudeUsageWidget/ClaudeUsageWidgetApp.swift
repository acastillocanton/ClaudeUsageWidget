import SwiftUI
import WidgetKit

@main
struct ClaudeUsageWidgetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No main window - this is a menu bar / widget app
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var usageInfo: UsageInfo = .empty

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Fetch data immediately
        usageInfo = UsageFetcher.fetchAndSave()

        // Status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        updateMenuBarIcon()
        buildMenu()

        // Auto-refresh every 5 minutes
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Also refresh icon every 30s
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateMenuBarIcon()
        }
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Claude Usage", action: nil, keyEquivalent: "").isEnabled = false

        menu.addItem(NSMenuItem.separator())

        let reset5h = UsageFetcher.formatDuration(usageInfo.fiveHourResetSeconds)
        let fiveH = NSMenuItem(title: "5h: \(Int(usageInfo.fiveHourPercent))% — \(UsageFetcher.formatTokens(usageInfo.tokensUsed5h ?? 0)) tokens — \(reset5h)", action: nil, keyEquivalent: "")
        fiveH.isEnabled = false
        menu.addItem(fiveH)

        let reset7d = UsageFetcher.formatDuration(usageInfo.sevenDayResetSeconds)
        let sevenD = NSMenuItem(title: "7d: \(Int(usageInfo.sevenDayPercent))% — \(UsageFetcher.formatTokens(usageInfo.tokensUsed7d ?? 0)) tokens — \(reset7d)", action: nil, keyEquivalent: "")
        sevenD.isEnabled = false
        menu.addItem(sevenD)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(withTitle: "Refresh", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(withTitle: "Reload Widget", action: #selector(reloadWidget), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "By Alejandro Castillo — castillocanton.com", action: #selector(openAuthorSite), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")

        statusItem.menu = menu
    }

    @objc func refresh() {
        usageInfo = UsageFetcher.fetchAndSave()
        updateMenuBarIcon()
        buildMenu()
        WidgetCenter.shared.reloadAllTimelines()
    }

    @objc func reloadWidget() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    @objc func openAuthorSite() {
        if let url = URL(string: "https://castillocanton.com") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem.button else { return }
        let fiveH = usageInfo.fiveHourPercent
        let sevenD = usageInfo.sevenDayPercent

        let w: CGFloat = 44, h: CGFloat = 18
        let image = NSImage(size: NSSize(width: w, height: h))
        image.lockFocus()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        NSAttributedString(string: "5h", attributes: attrs).draw(at: NSPoint(x: 0, y: 8))
        drawBar(at: NSPoint(x: 14, y: 11), w: 26, h: 4, pct: fiveH)
        NSAttributedString(string: "7d", attributes: attrs).draw(at: NSPoint(x: 0, y: 0))
        drawBar(at: NSPoint(x: 14, y: 3), w: 26, h: 4, pct: sevenD)
        image.unlockFocus()
        image.isTemplate = false
        button.image = image
        button.title = ""
    }

    private func drawBar(at o: NSPoint, w: CGFloat, h: CGFloat, pct: Double) {
        NSColor.gray.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: NSRect(x: o.x, y: o.y, width: w, height: h), xRadius: 2, yRadius: 2).fill()
        let fw = max(0, w * CGFloat(pct / 100))
        if fw > 0 {
            let c = UsageFetcher.barColor(pct)
            NSColor(red: c.r, green: c.g, blue: c.b, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: o.x, y: o.y, width: fw, height: h), xRadius: 2, yRadius: 2).fill()
        }
    }
}
