import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let preferences = Preferences()
    private lazy var session = TuningSession(preferences: preferences)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = makeStatusMenu()
        updateIcon(live: false)

        popover.behavior = .transient
        popover.delegate = self
        let tuningHost = NSHostingController(rootView: TuningView(session: session, preferences: preferences))
        // Publish the SwiftUI size before the popover is positioned. Without this the popover is
        // placed for its default 320×320, then grows upward into the menu bar and notch.
        tuningHost.sizingOptions = [.preferredContentSize]
        popover.contentViewController = tuningHost

        session.onLiveChange = { [weak self] live in self?.updateIcon(live: live) }
        session.onAutoStop = { [weak self] in self?.popover.performClose(nil) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stop()
    }

    // MARK: Menu actions

    @objc private func startTuning() {
        // This runs while the status menu is still tracking; show the popover after it closes,
        // otherwise the menu's dismissal immediately closes the transient popover.
        DispatchQueue.main.async { [self] in
            guard let button = statusItem.button else { return }
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            session.start()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let settingsHost = NSHostingController(rootView: SettingsView(preferences: preferences))
            settingsHost.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: settingsHost)
            window.title = "Tunelet Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            // Size to the content before centring; otherwise a 1×32 window gets centred and then
            // grows down and to the right from there.
            window.setContentSize(settingsHost.view.fittingSize)
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Leaving tuning mode always releases the microphone.
        session.stop()
    }

    // MARK: Building UI

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Start Tuning", action: #selector(startTuning), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Tunelet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        return menu
    }

    /// Template tuning fork normally; tinted orange (like the system mic indicator) while listening.
    private func updateIcon(live: Bool) {
        let description = live ? "Tunelet, listening" : "Tunelet"
        guard var image = NSImage(systemSymbolName: "tuningfork", accessibilityDescription: description) else { return }
        if live, let tinted = image.withSymbolConfiguration(.init(paletteColors: [.systemOrange])) {
            image = tinted
            image.isTemplate = false
        } else {
            image.isTemplate = true
        }
        statusItem.button?.image = image
    }

    /// Menu-bar apps have no visible main menu, but text fields still need the standard Edit
    /// commands (⌘C, ⌘V, ⌘Z…) to reach them, and those come from the main menu.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }
}
