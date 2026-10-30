import AppKit

/// The menu bar. Document actions travel the responder chain to the frontmost `ProjectDocument`.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu(appMenu()))
        menu.addItem(submenu(fileMenu()))
        menu.addItem(submenu(editMenu()))
        menu.addItem(submenu(clipMenu()))
        menu.addItem(submenu(viewMenu()))
        menu.addItem(submenu(playbackMenu()))
        #if DEBUG
        menu.addItem(submenu(debugMenu()))
        #endif
        let window = windowMenu()
        menu.addItem(submenu(window))
        NSApplication.shared.windowsMenu = window
        return menu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    private static func functionKey(_ code: Int) -> String {
        String(Character(UnicodeScalar(UInt32(code))!))
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Overlap")
        menu.addItem(item("About Overlap", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Hide Overlap", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Overlap", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New", #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save…", #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item("Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]))
        menu.addItem(item("Revert to Saved", #selector(NSDocument.revertToSaved(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Import…", #selector(ProjectDocument.importMedia(_:)), "i"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Delete", #selector(ProjectDocument.delete(_:)), functionKey(NSBackspaceCharacter), []))
        menu.addItem(item("Delete and Close Gap", #selector(ProjectDocument.deleteAndCloseGap(_:)), functionKey(NSBackspaceCharacter), .shift))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(item("Select Clip at Playhead", #selector(ProjectDocument.selectClipAtPlayhead(_:)), "c", []))
        return menu
    }

    private static func clipMenu() -> NSMenu {
        let menu = NSMenu(title: "Clip")
        menu.addItem(item("Split at Playhead", #selector(ProjectDocument.splitAtPlayhead(_:)), "b"))
        menu.addItem(item("Trim Start to Playhead", #selector(ProjectDocument.trimStartToPlayhead(_:)), "[", .option))
        menu.addItem(item("Trim End to Playhead", #selector(ProjectDocument.trimEndToPlayhead(_:)), "]", .option))
        menu.addItem(.separator())
        menu.addItem(item("Add Fade In", #selector(ProjectDocument.toggleFadeIn(_:))))
        menu.addItem(item("Add Fade Out", #selector(ProjectDocument.toggleFadeOut(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Detach Audio", #selector(ProjectDocument.detachAudio(_:)), "s", [.control, .shift]))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        for tab in PanelTab.allCases {
            menu.addItem(item(tab.title, #selector(ProjectDocument.showPanelTab(_:)), "\(tab.rawValue)", tag: tab.rawValue))
        }
        menu.addItem(.separator())
        menu.addItem(item("Hide Panel", #selector(ProjectDocument.togglePanel(_:)), "s", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("Zoom In", #selector(ProjectDocument.zoomInTimeline(_:)), "="))
        menu.addItem(item("Zoom Out", #selector(ProjectDocument.zoomOutTimeline(_:)), "-"))
        menu.addItem(item("Zoom to Fit", #selector(ProjectDocument.zoomTimelineToFit(_:)), "z", .shift))
        menu.addItem(item("Snapping", #selector(ProjectDocument.toggleSnapping(_:)), "n", []))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func playbackMenu() -> NSMenu {
        let menu = NSMenu(title: "Playback")
        menu.addItem(item("Play", #selector(ProjectDocument.togglePlayback(_:)), " ", []))
        menu.addItem(item("Play Backward", #selector(ProjectDocument.playBackward(_:)), "j", []))
        menu.addItem(item("Pause", #selector(ProjectDocument.pausePlayback(_:)), "k", []))
        menu.addItem(item("Play Forward", #selector(ProjectDocument.playForward(_:)), "l", []))
        menu.addItem(.separator())
        menu.addItem(item("Previous Frame", #selector(ProjectDocument.previousFrame(_:)), functionKey(NSLeftArrowFunctionKey), []))
        menu.addItem(item("Next Frame", #selector(ProjectDocument.nextFrame(_:)), functionKey(NSRightArrowFunctionKey), []))
        menu.addItem(item("Previous Edit", #selector(ProjectDocument.previousEdit(_:)), functionKey(NSUpArrowFunctionKey), []))
        menu.addItem(item("Next Edit", #selector(ProjectDocument.nextEdit(_:)), functionKey(NSDownArrowFunctionKey), []))
        menu.addItem(.separator())
        menu.addItem(item("Go to Start", #selector(ProjectDocument.goToStart(_:)), functionKey(NSHomeFunctionKey), []))
        menu.addItem(item("Go to End", #selector(ProjectDocument.goToEnd(_:)), functionKey(NSEndFunctionKey), []))
        return menu
    }

    private static func debugMenu() -> NSMenu {
        let menu = NSMenu(title: "Debug")
        menu.addItem(item("Prototype: 2-Second Fades on Every Clip", #selector(ProjectDocument.togglePrototypeFades(_:))))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
