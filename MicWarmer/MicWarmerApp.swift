import SwiftUI
import AppKit

@main
struct MicWarmerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Drives the menu-bar icon: outline mic when off, orange filled mic when warm.
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
        } label: {
            Image(systemName: state.isWarm ? "mic.fill" : "mic")
                .foregroundStyle(state.isWarm ? Color.orange : Color.primary)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Touch the singleton so the hotkey handler is registered at launch.
        let state = AppState.shared

        // First run (or after clearing the hotkey): guide the user to set one.
        if !state.hasHotkey {
            state.showRecorder()
        }
    }
}

struct MenuContent: View {
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        Button(appState.isWarm ? "Stop warming the mic" : "Warm the mic") {
            appState.toggleWarm()
        }

        Button("Set Hotkey…") {
            appState.showRecorder()
        }

        Divider()

        Button("Quit Mic Warmer") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
