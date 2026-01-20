//
//  WindowManager.swift
//  ClaudeIsland
//
//  Manages the notch window lifecycle
//

import AppKit
import os.log

/// Logger for window management
private let logger = Logger(subsystem: "com.claudeisland", category: "Window")

class WindowManager {
    private(set) var windowControllers: [NotchWindowController] = []

    /// Set up or recreate the notch window(s)
    func setupNotchWindow() -> NotchWindowController? {
        // Use ScreenSelector for screen selection
        let screenSelector = ScreenSelector.shared
        screenSelector.refreshScreens()

        // Clear existing windows
        clearAllWindows()

        switch screenSelector.selectionMode {
        case .allScreens:
            // Create a window for each screen
            for screen in screenSelector.availableScreens {
                let controller = NotchWindowController(screen: screen)
                controller.showWindow(nil)
                windowControllers.append(controller)
            }
            return windowControllers.first

        default:
            // Single screen mode (automatic or specific)
            guard let screen = screenSelector.selectedScreen else {
                logger.warning("No screen found")
                return nil
            }

            let controller = NotchWindowController(screen: screen)
            controller.showWindow(nil)
            windowControllers.append(controller)

            return controller
        }
    }

    /// Clear all existing windows
    private func clearAllWindows() {
        for controller in windowControllers {
            controller.window?.orderOut(nil)
            controller.window?.close()
        }
        windowControllers.removeAll()
    }
}
