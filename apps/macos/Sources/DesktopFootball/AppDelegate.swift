import AppKit
import FootballPhysics

/// Menu-bar-only agent app. Owns the single football panel and a status item with
/// show/hide, reset, gravity mode, sound toggle and quit.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var panel: FootballPanel?
    private var soundItem: NSMenuItem?
    private var visibilityItem: NSMenuItem?
    private var gravityItems: [NSMenuItem] = []
    private var gameModeItem: NSMenuItem?
    private var cruiseModeItem: NSMenuItem?
    private var comboItems: [NSMenuItem] = []

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

        menu.addItem(buildGravityMenuItem())

        menu.addItem(.separator())

        let gm = NSMenuItem(title: "Game Mode", action: #selector(toggleGameMode), keyEquivalent: "g")
        gm.target = self
        gm.state = .off
        menu.addItem(gm)
        gameModeItem = gm

        menu.addItem(buildComboMenuItem())

        let cruise = NSMenuItem(title: "Cruise Mode", action: #selector(toggleCruiseMode), keyEquivalent: "")
        cruise.target = self; cruise.state = .off
        menu.addItem(cruise)
        cruiseModeItem = cruise

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

    /// "Gravity Mode" parent item with a checkmarked radio submenu.
    private func buildGravityMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Gravity Mode", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let current = panel?.gravityMode ?? .normal
        gravityItems = GravityMode.allCases.map { mode in
            let item = NSMenuItem(title: mode.menuTitle, action: #selector(setGravity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = (mode == current) ? .on : .off
            submenu.addItem(item)
            return item
        }
        parent.submenu = submenu
        return parent
    }

    /// "Combo Strikes" submenu — how many phantom hits fire on a standard combo.
    private func buildComboMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Combo Strikes", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let options: [(String, Int)] = [("Off", 0), ("2 Hits", 2), ("3 Hits", 3)]
        let current = panel?.comboStrikeCount ?? 2
        comboItems = options.map { (title, count) in
            let item = NSMenuItem(title: title, action: #selector(setCombo(_:)), keyEquivalent: "")
            item.target = self
            item.tag = count
            item.state = count == current ? .on : .off
            submenu.addItem(item)
            return item
        }
        parent.submenu = submenu
        return parent
    }

    // MARK: - Actions

    @objc private func toggleCruiseMode() {
        guard let panel, let cruiseModeItem else { return }
        let on = !panel.isCruiseMode
        panel.setCruiseMode(on)
        cruiseModeItem.state = on ? .on : .off
    }

    @objc private func toggleGameMode() {
        guard let panel, let gameModeItem else { return }
        let newValue = !panel.isGameMode
        panel.setGameMode(newValue)
        gameModeItem.state = newValue ? .on : .off
    }

    @objc private func setCombo(_ sender: NSMenuItem) {
        panel?.comboStrikeCount = sender.tag
        for item in comboItems { item.state = item.tag == sender.tag ? .on : .off }
    }

    @objc private func setGravity(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? GravityMode else { return }
        panel?.setGravityMode(mode)
        for item in gravityItems {
            item.state = (item.representedObject as? GravityMode == mode) ? .on : .off
        }
    }

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
