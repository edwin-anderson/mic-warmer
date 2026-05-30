import AppKit
import SwiftUI
import KeyboardShortcuts
import AVFoundation

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    // Whether the mic is currently held open. Deliberately NOT persisted: the app always starts
    // OFF, and the mic is only ever opened after the user explicitly toggles it on this session.
    @Published private(set) var isWarm = false

    private let keepWarm = MicKeepWarm()
    private var recorderWindow: NSWindow?

    private init() {
        // If the mic stops capturing and the watchdog can't recover it, stop showing "warm" so the
        // menu-bar icon never lies about the mic's real state. Delivered on the main thread.
        keepWarm.onWarmthLost = { [weak self] in
            MainActor.assumeIsolated { self?.isWarm = false }
        }
        KeyboardShortcuts.onKeyDown(for: .toggleWarm) {
            MainActor.assumeIsolated {
                AppState.shared.toggleWarm()
            }
        }
    }

    var hasHotkey: Bool {
        KeyboardShortcuts.getShortcut(for: .toggleWarm) != nil
    }

    func toggleWarm() {
        if isWarm {
            keepWarm.stop()
            isWarm = false
        } else {
            warmAfterPermission()
        }
    }

    // The mic is only opened once we hold (or are granted) permission. On first use macOS shows
    // its own permission prompt; if the user previously denied it we point them at System Settings.
    private func warmAfterPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startWarming()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                // requestAccess calls back on an arbitrary queue; hop to main before touching state.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if granted { AppState.shared.startWarming() }
                        // If denied at the prompt, we simply stay OFF.
                    }
                }
            }
        default: // .denied or .restricted
            showMicDeniedAlert()
        }
    }

    private func startWarming() {
        keepWarm.start { success in
            // start(completion:) always calls back on the main thread, and reports true only once
            // real audio is confirmed flowing — so isWarm reflects the mic's actual state.
            MainActor.assumeIsolated {
                if success {
                    AppState.shared.isWarm = true
                } else {
                    AppState.shared.isWarm = false
                    AppState.shared.showCaptureFailedAlert()
                }
            }
        }
    }

    func showRecorder() {
        if recorderWindow == nil {
            let hosting = NSHostingController(rootView: HotkeyRecorderView())
            let win = NSWindow(contentViewController: hosting)
            win.title = "Mic Warmer"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            recorderWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        recorderWindow?.center()
        recorderWindow?.makeKeyAndOrderFront(nil)
    }

    private func showMicDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone access is turned off"
        alert.informativeText = "Mic Warmer needs microphone access to keep the mic warm. Turn it on in System Settings ▸ Privacy & Security ▸ Microphone, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // Warming failed. Either there's genuinely no input device, or macOS started the session but
    // delivered no audio — which almost always means the microphone is being silently blocked
    // (commonly after a rebuild/reinstall, because ad-hoc signing changes the app's code hash and
    // invalidates the old permission grant). Point the user at the fix for each case.
    private func showCaptureFailedAlert() {
        guard AVCaptureDevice.default(for: .audio) != nil else {
            showNoMicAlert()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Mic Warmer couldn’t turn the microphone on"
        alert.informativeText = "macOS started the audio session but isn’t delivering any audio — microphone access is being blocked. This often happens after the app is rebuilt or reinstalled.\n\nOpen System Settings ▸ Privacy & Security ▸ Microphone, switch Mic Warmer off and back on (or remove and re-add it), then try warming again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func showNoMicAlert() {
        let alert = NSAlert()
        alert.messageText = "No microphone found"
        alert.informativeText = "Mic Warmer couldn't find an audio input device to keep warm. Connect a microphone and try again."
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
