# mic-warmer

## What this is

A small native macOS menu-bar utility that fixes the push-to-talk activation delay in voice dictation apps (Wispr Flow, SuperWhisper, etc.). On this Mac, macOS powers down the microphone hardware after about 2 seconds of inactivity; the next time an app starts capturing, the first 1-2 seconds of speech are lost while the mic wakes up. This tool keeps the mic hardware awake so dictation activation is instant and no words get clipped.

## The problem it solves

When the mic has been idle, pressing the dictation hotkey clips the first word or two because the hardware isn't awake yet. Keeping an audio capture session open holds the mic hardware powered on, so capture is always instant. The audio captured by this tool is immediately discarded — nothing is recorded, stored, or transmitted. The only effect is that the mic hardware stays warm.

## How it should work (UX)

- The tool is toggled with a global keyboard hotkey.
- Press the hotkey once: the mic is held open ("warm") and stays open indefinitely. Dictation is now instant.
- Press the hotkey again: the mic session is released, returning the Mac to default behavior (mic sleeps after idle, and the activation delay returns). This is the intended revert.
- The user must be able to set / change the hotkey themselves from within the app (do not ship a hardcoded-only shortcut).
- While the mic is held open, macOS shows the orange microphone indicator dot in the menu bar. This is expected and correct — it is the user's visual confirmation that the mic is warm.
- On launch, the tool should start in the OFF state (mic not held open). The mic is only ever held open after the user explicitly toggles it on. This is a deliberate privacy choice — the mic must never be open unless the user turned it on this session.
- The menu-bar icon should reflect state, so the user can tell at a glance whether the mic is currently warm or off.

## Reference project (IMPORTANT)

Use the user's existing project at /Users/edwin/Documents/Programming/PersonalProject/clipboard-peek as the structural reference. It is a working, verified native macOS menu-bar utility by the same user and solves most of the same problems this tool needs. Read its CLAUDE.md first — it documents the conventions, toolchain constraints, build/install flow, and gotchas. In particular, mic-warmer should follow the same patterns:

- LSUIElement menu-bar app (no Dock icon), built with the same general structure.
- Uses the sindresorhus/KeyboardShortcuts package (already used in clipboard-peek) for the user-configurable global hotkey with a recorder UI and no Accessibility permission requirement.
- Generated via XcodeGen from a project.yml, ad-hoc signed (CODE_SIGN_IDENTITY = "-"), no Apple Developer account or notarization.
- Same UserDefaults-based persistence approach for settings like the chosen hotkey.

## Hard constraints (from the user and the reference project)

- Target toolchain is old and fixed: macOS 15.3.1, Swift 5.9, macOS 14.x SDK. Deployment target macOS 14.0. Do not use newer-SDK-only APIs. (AVCaptureSession audio capture is long-standing and fully available on macOS 14.)
- The user is NOT a Swift programmer. Keep code readable, explain choices in plain terms, and verify it builds and works before handing off — do not leave the user to debug.
- Privacy is a core concern: the tool must never record, store, or transmit audio. Captured audio samples are discarded immediately. Starts OFF on launch.

## Build & install (definition of done)

- The project source lives in /Users/edwin/Documents/Programming/PersonalProject/mic-warmer (this repo).
- The finished build is a self-contained .app bundle that is installed into /Applications, so the user can launch it like any normal Mac app (Spotlight, Launchpad, double-click) — the same way clipboard-peek installs (cp -R the built .app into /Applications/).
- Done means: the app builds in Release, installs to /Applications, launches as a menu-bar item, lets the user set a hotkey, and toggling that hotkey warms/cools the mic (verifiable via the orange menu-bar dot appearing/disappearing and dictation first-words no longer being clipped).

## Out of scope (v1)

- Automatic device-switch handling, Bluetooth deadlock recovery, ring-buffer lookback, running at login, or any always-on/background-daemon behavior. This tool is purely manual toggle-on / toggle-off.
- Note for the user's awareness (not a feature to build): if toggled on while using AirPods/Bluetooth audio, holding the mic open forces SCO telephony mode, which degrades audio playback quality. This is a Bluetooth protocol limitation, not a bug. Not relevant when using the built-in mic.

## Before you start (do extensive research FIRST)

The user has specifically requested that you do extensive research before writing any code — this project is likely to fail without it, given the pinned older toolchain. Before implementing:

- Research current, correct Swift usage for this toolchain (Swift 5.9, macOS 14.x SDK, deployment target macOS 14.0). Do not rely on memory for API shapes; verify them. Avoid any API that requires a newer SDK than is installed.
- Research how to correctly hold an AVCaptureSession audio input open on macOS 14 while discarding captured samples (the keep-warm mechanism).
- Research the microphone permission flow (NSMicrophoneUsageDescription in Info.plist + AVCaptureDevice.requestAccess(for: .audio)) and how it behaves for an ad-hoc-signed, LSUIElement menu-bar app.
- Research the sindresorhus/KeyboardShortcuts package's current API for registering a user-configurable global hotkey and presenting its recorder UI, cross-checking against how clipboard-peek already uses it.
- Read the clipboard-peek source and CLAUDE.md thoroughly before starting, and mirror its conventions and build/install flow.

You're the engineer. This brief is intent, not spec. Use AskUserQuestion if anything is fuzzy.