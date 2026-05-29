import AppKit

/// Menu-bar-only agent app. Owns the single football panel and a status item with
/// show/hide, reset, sound toggle and quit.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var panel: FootballPanel?
    private var soundItem: NSMenuItem?
    private var visibilityItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let football = FootballPanel()
        football.orderFrontRegardless()
        panel = football

        setupStatusItem()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let img = NSImage(systemSymbolName: "soccerball", accessibilityDescription: "Desktop Football")
            img?.isTemplate = true
            button.image = img ?? NSImage()
        }
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let visibility = NSMenuItem(title: "Hide Football", action: #selector(toggleVisibility),
                                    keyEquivalent: "")
        visibility.target = self
        menu.addItem(visibility)
        visibilityItem = visibility

        let reset = NSMenuItem(title: "Reset to Centre", action: #selector(resetBall), keyEquivalent: "r")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        let soundToggle = NSMenuItem(title: "Sound", action: #selector(toggleSound), keyEquivalent: "")
        soundToggle.target = self
        soundToggle.state = .on
        menu.addItem(soundToggle)
        soundItem = soundToggle

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Desktop Football", action: #selector(NSApp.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    // MARK: - Actions

    @objc private func toggleVisibility() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            visibilityItem?.title = "Show Football"
        } else {
            panel.orderFrontRegardless()
            visibilityItem?.title = "Hide Football"
        }
    }

    @objc private func resetBall() {
        if panel?.isVisible == false { panel?.orderFrontRegardless() }
        panel?.reset()
    }

    @objc private func toggleSound() {
        guard let panel, let soundItem else { return }
        panel.soundEnabled.toggle()
        soundItem.state = panel.soundEnabled ? .on : .off
    }
}
