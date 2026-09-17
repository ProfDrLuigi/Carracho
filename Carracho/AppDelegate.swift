//
//  AppDelegate.swift
//  Carracho
//
//  Created by Prof. Dr. Luigi on 10.09.26.
//

import Cocoa
import Sparkle

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    // Keep Sparkle's controller alive for the lifetime of the application. It also owns
    // menu-item validation, so "Check for Update…" is disabled automatically while a check
    // cannot be started.
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        configureCarrachoMenus()
    }

    private func configureCarrachoMenus() {
        guard let main = NSApp.mainMenu else { return }

        if let format = main.item(withTitle: L("Format")) { main.removeItem(format) }
        configureViewMenu(in: main)

        if let appMenu = main.items.first?.submenu {
            if appMenu.item(withTitle: L("Check for Update…")) == nil {
                let updateItem = NSMenuItem(
                    title: L("Check for Update…"),
                    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                    keyEquivalent: ""
                )
                updateItem.target = updaterController
                // The first item is the standard About item; keep the update check directly
                // underneath it and before the existing separator.
                appMenu.insertItem(updateItem, at: min(1, appMenu.items.count))
            }

            if let settings = appMenu.items.first(where: {
                $0.title == L("Preferences…") || $0.title == L("Settings…")
            }) {
                settings.title = L("Settings…")
                settings.target = nil
                settings.action = #selector(ViewController.menuSettings(_:))
            }
        }

        if main.item(withTitle: L("Servers")) == nil {
            let servers = NSMenuItem(title: L("Servers"), action: nil, keyEquivalent: "")
            let menu = NSMenu(title: L("Servers"))
            menu.addItem(withTitle: L("Connect to Server…"), action: #selector(ViewController.menuConnect(_:)), keyEquivalent: "k")
            menu.addItem(withTitle: L("Disconnect"), action: #selector(ViewController.menuDisconnect(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: L("Import Bookmarks…"), action: #selector(ViewController.menuImportBookmarks(_:)), keyEquivalent: "")
            menu.addItem(withTitle: L("Export Bookmarks…"), action: #selector(ViewController.menuExportBookmarks(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: L("Files"), action: #selector(ViewController.menuFiles(_:)), keyEquivalent: "")
            menu.addItem(withTitle: L("News"), action: #selector(ViewController.menuNews(_:)), keyEquivalent: "")
            menu.addItem(withTitle: L("Chat Rooms"), action: #selector(ViewController.menuConferences(_:)), keyEquivalent: "")
            let serverInfo = menu.addItem(withTitle: L("Server Info"), action: #selector(ViewController.menuServerInfo(_:)), keyEquivalent: "")
            serverInfo.isHidden = true
            menu.addItem(.separator())
            let administration = menu.addItem(withTitle: L("Administration"), action: #selector(ViewController.menuAdministration(_:)), keyEquivalent: "")
            administration.isHidden = true
            servers.submenu = menu
            if let windowIndex = main.items.firstIndex(where: { $0.title == L("Window") }) {
                main.insertItem(servers, at: windowIndex)
            } else {
                main.addItem(servers)
            }
        }
    }

    /// The storyboard's stock macOS View menu used First Responder targets for toolbar/sidebar
    /// actions that this custom AppKit shell does not implement. Merely opening that menu makes
    /// AppKit validate those selectors across the responder chain. Keep the menu deterministic:
    /// every item has an explicit target and automatic validation is disabled.
    private func configureViewMenu(in main: NSMenu) {
        guard let viewItem = main.items.first(where: { item in
            item.submenu?.items.contains(where: { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }) == true
        }) else { return }

        let menu = NSMenu(title: viewItem.title)
        menu.autoenablesItems = false

        let system = NSMenuItem(title: L("System Appearance"), action: #selector(setViewMenuAppearance(_:)), keyEquivalent: "")
        system.target = self
        system.tag = 0
        menu.addItem(system)

        let light = NSMenuItem(title: L("Light"), action: #selector(setViewMenuAppearance(_:)), keyEquivalent: "")
        light.target = self
        light.tag = 1
        menu.addItem(light)

        let dark = NSMenuItem(title: L("Dark"), action: #selector(setViewMenuAppearance(_:)), keyEquivalent: "")
        dark.target = self
        dark.tag = 2
        menu.addItem(dark)

        menu.addItem(.separator())

        let fullScreen = NSMenuItem(title: L("Toggle Full Screen"), action: #selector(toggleMainWindowFullScreen(_:)), keyEquivalent: "f")
        fullScreen.target = self
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(fullScreen)

        viewItem.submenu = menu
        updateViewMenuAppearanceStates(menu)
    }

    @objc private func setViewMenuAppearance(_ sender: NSMenuItem) {
        let value: String
        switch sender.tag {
        case 1:
            value = "light"
            NSApp.appearance = NSAppearance(named: .aqua)
        case 2:
            value = "dark"
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            value = "system"
            NSApp.appearance = nil
        }
        UserDefaults.standard.set(value, forKey: "CarrachoAppearance")

        if let controller = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentViewController as? ViewController {
            controller.refreshAppearance()
        }
        if let menu = sender.menu { updateViewMenuAppearanceStates(menu) }
    }

    private func updateViewMenuAppearanceStates(_ menu: NSMenu) {
        let selected: Int
        switch UserDefaults.standard.string(forKey: "CarrachoAppearance") {
        case "light": selected = 1
        case "dark": selected = 2
        default: selected = 0
        }
        for item in menu.items where (0...2).contains(item.tag) && item.action == #selector(setViewMenuAppearance(_:)) {
            item.state = item.tag == selected ? .on : .off
            item.isEnabled = true
        }
    }

    @objc private func toggleMainWindowFullScreen(_ sender: Any?) {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(sender)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Carracho keeps live server sessions per bookmark. Leaving the process alive after the
        // last window is closed makes those sessions look like ghost users on the server.
        return true
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // ViewController observes the same termination notification and tears down every live
        // bookmark connection before the process exits.
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }


}

