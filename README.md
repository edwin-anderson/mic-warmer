# Mic Warmer

A tiny macOS menu-bar app that keeps your microphone "warm" so push-to-talk
dictation (Wispr Flow, SuperWhisper, etc.) activates instantly — no more clipped
first words.

## Why

macOS powers the mic hardware down after a couple of seconds of silence. The next
time a dictation app starts listening, the first 1–2 seconds of speech are lost
while the mic wakes up. Mic Warmer holds the mic awake on demand so capture is
always instant.

**It never records you.** While warm, the app opens an audio session and throws
every sample away immediately — nothing is recorded, saved, or sent anywhere. The
only effect is that the mic stays powered on.

## How to use

1. Launch Mic Warmer — it lives in the menu bar (no Dock icon). It starts **off**.
2. First launch asks you to pick a global hotkey. You can change it any time via
   the menu's **Set Hotkey…**.
3. Press your hotkey (or click the menu bar icon → **Warm the mic**) to hold the
   mic open. Press again to release it.

The menu-bar icon shows the state at a glance:

- **Outline mic** — off (default behavior; mic sleeps when idle).
- **Orange filled mic** — warm (mic held open; dictation is instant).

## Things you'll notice (all normal)

- **An orange dot** appears in the menu bar while warm. That's macOS telling you
  the mic is on — exactly what we want.
- **A second mic icon** (a "Microphone Mode / Voice Isolation" menu) shows up next
  to ours while warm. That's a built-in macOS control that appears for any app
  using the mic; it disappears when you turn Mic Warmer off. It's not a second copy
  of the app.
- The first time you warm the mic, macOS asks for **microphone permission** — click
  Allow. (If you ever rebuild/reinstall the app, macOS may ask again.)
- On **AirPods / Bluetooth** headsets, holding the mic open switches them into
  call-quality mode, which lowers playback quality. That's a Bluetooth limitation —
  use the built-in mic if it bothers you.

## Install

```sh
xcodegen generate
xcodebuild -project MicWarmer.xcodeproj -scheme MicWarmer \
  -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/MicWarmer.app /Applications/
```

Then launch it from Spotlight / Launchpad like any app. Requires macOS 14 or later.

## Privacy

No audio is ever recorded, stored, or transmitted. The app starts off and only
opens the mic after you explicitly turn it on, for as long as you leave it on.
