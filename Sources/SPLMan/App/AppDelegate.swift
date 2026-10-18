import AppKit
import CoreGraphics
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum WindowStateKey {
        static let screenIdentifier = "SPLMan.mainWindow.screenIdentifier"
        static let fullScreen = "SPLMan.mainWindow.fullScreen"
    }

    private struct WindowState {
        let screenIdentifier: String
        let isFullScreen: Bool
    }

    private var window: NSWindow?
    private var model: MeterModel?
    private var isRestoringWindowState = false
    private var temporaryFallbackScreenIdentifier: String?
    private var isUsingTemporaryScreenFallback = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "SPLMan", withExtension: "icns"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = iconImage
        }

        let model = MeterModel()
        let content = MeterView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1920, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "SPL Man"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: content)
        window.backgroundColor = .black
        window.minSize = NSSize(width: 960, height: 300)
        window.setFrameAutosaveName("SPLMan.mainWindow")
        if !window.setFrameUsingName("SPLMan.mainWindow") {
            window.center()
        }

        let savedWindowState = loadWindowState()
        if let savedWindowState {
            let preferredScreen = NSScreen.screens.first {
                screenIdentifier(for: $0) == savedWindowState.screenIdentifier
            }
            let targetScreen = preferredScreen ?? NSScreen.main ?? NSScreen.screens.first

            if let targetScreen {
                if preferredScreen == nil {
                    temporaryFallbackScreenIdentifier = screenIdentifier(for: targetScreen)
                    isUsingTemporaryScreenFallback = true
                }
                move(window, to: targetScreen)
            }
        }

        isRestoringWindowState = savedWindowState?.isFullScreen == true
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.model = model
        self.window = window

        if savedWindowState?.isFullScreen == true {
            DispatchQueue.main.async { [weak window] in
                window?.toggleFullScreen(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let window {
            persistWindowState(for: window)
        }
        model?.shutdown()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        persistWindowStateIfReady(from: notification, updateScreenPreference: true)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        isRestoringWindowState = false
        persistWindowStateIfReady(from: notification)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isRestoringWindowState = false
        persistWindowStateIfReady(from: notification)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isRestoringWindowState = false
        persistWindowState(for: window)
    }

    func windowWillClose(_ notification: Notification) {
        persistWindowStateIfReady(from: notification)
    }

    private func loadWindowState() -> WindowState? {
        let defaults = UserDefaults.standard
        guard let screenIdentifier = defaults.string(forKey: WindowStateKey.screenIdentifier) else {
            return nil
        }

        return WindowState(
            screenIdentifier: screenIdentifier,
            isFullScreen: defaults.bool(forKey: WindowStateKey.fullScreen)
        )
    }

    private func persistWindowStateIfReady(
        from notification: Notification,
        updateScreenPreference: Bool = false
    ) {
        guard !isRestoringWindowState, let window = notification.object as? NSWindow else {
            return
        }

        persistWindowState(for: window, updateScreenPreference: updateScreenPreference)
    }

    private func persistWindowState(for window: NSWindow, updateScreenPreference: Bool = false) {
        let defaults = UserDefaults.standard
        defaults.set(window.styleMask.contains(.fullScreen), forKey: WindowStateKey.fullScreen)

        guard let screen = window.screen,
              let screenIdentifier = screenIdentifier(for: screen) else {
            return
        }

        if isUsingTemporaryScreenFallback {
            guard updateScreenPreference,
                  let fallbackScreenIdentifier = temporaryFallbackScreenIdentifier,
                  screenIdentifier != fallbackScreenIdentifier else {
                return
            }

            isUsingTemporaryScreenFallback = false
            temporaryFallbackScreenIdentifier = nil
        }

        defaults.set(screenIdentifier, forKey: WindowStateKey.screenIdentifier)
    }

    private func screenIdentifier(for screen: NSScreen) -> String? {
        let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screenNumber = screen.deviceDescription[screenNumberKey] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(screenNumber.uint32Value)) else {
            return nil
        }

        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    private func move(_ window: NSWindow, to targetScreen: NSScreen) {
        let currentScreen = NSScreen.screens.max {
            intersectionArea(of: window.frame, with: $0.frame)
                < intersectionArea(of: window.frame, with: $1.frame)
        }

        guard currentScreen != targetScreen else {
            window.setFrame(
                constrainedFrame(window.frame, to: targetScreen.visibleFrame, minimumSize: window.minSize),
                display: false
            )
            return
        }

        var frame = window.frame
        if let currentScreen {
            let sourceFrame = currentScreen.visibleFrame
            let targetFrame = targetScreen.visibleFrame
            let offsetFromLeft = frame.minX - sourceFrame.minX
            let offsetFromTop = sourceFrame.maxY - frame.maxY
            frame.origin.x = targetFrame.minX + offsetFromLeft
            frame.origin.y = targetFrame.maxY - offsetFromTop - frame.height
        } else {
            frame.origin.x = targetScreen.visibleFrame.midX - frame.width / 2
            frame.origin.y = targetScreen.visibleFrame.midY - frame.height / 2
        }

        window.setFrame(
            constrainedFrame(frame, to: targetScreen.visibleFrame, minimumSize: window.minSize),
            display: false
        )
    }

    private func intersectionArea(of firstFrame: NSRect, with secondFrame: NSRect) -> CGFloat {
        let intersection = firstFrame.intersection(secondFrame)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func constrainedFrame(
        _ frame: NSRect,
        to visibleFrame: NSRect,
        minimumSize: NSSize
    ) -> NSRect {
        var constrainedFrame = frame
        let effectiveMinimumWidth = min(minimumSize.width, visibleFrame.width)
        let effectiveMinimumHeight = min(minimumSize.height, visibleFrame.height)
        constrainedFrame.size.width = min(
            max(frame.width, effectiveMinimumWidth),
            visibleFrame.width
        )
        constrainedFrame.size.height = min(
            max(frame.height, effectiveMinimumHeight),
            visibleFrame.height
        )
        constrainedFrame.origin.x = min(
            max(constrainedFrame.minX, visibleFrame.minX),
            visibleFrame.maxX - constrainedFrame.width
        )
        constrainedFrame.origin.y = min(
            max(constrainedFrame.minY, visibleFrame.minY),
            visibleFrame.maxY - constrainedFrame.height
        )
        return constrainedFrame
    }
}
