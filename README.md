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

## Works with whatever mic you use

Mic Warmer warms **all of your microphones at once** — the built-in mic, an external
display mic (like a Studio Display), USB mics, and so on — and follows along
automatically when you dock, undock, or plug one in. You never have to tell it which
mic to use.

This matters because dictation apps usually pick the mic for you. Wispr Flow's
**Auto-detect** setting, for example, switches between your built-in and external
mics depending on what's connected — so the mic it ends up using isn't always your
Mac's "default" input. By keeping every mic warm, Mic Warmer makes sure that
whichever one your app lands on is already awake. (This is why a delay could show up
only when docked: the dictation app was using a different mic than the system
default.)

**Does warming several mics mix them into your recording? No.** This is the natural
worry, so to be clear: macOS keeps every app's microphone audio completely separate.
Each app gets its own private stream from the *one* mic it opened. Your dictation app
records only the single mic it chose — Mic Warmer just keeps the *other* mics powered
and instantly throws away everything it captures from them. The mics are never mixed
together, so there's no echo, no doubling, and no second mic bleeding into your
recording. Warming a mic only keeps the hardware awake; it doesn't route that mic's
sound anywhere.

**Bluetooth mics (AirPods, etc.) are skipped on purpose.** Holding a Bluetooth mic
open forces it into low-quality "call" mode, which would wreck your music/playback
the whole time you're warmed. The trade-off: a Bluetooth mic won't be pre-warmed, so
dictating through AirPods can still clip the first word — use a built-in or wired mic
for instant dictation.

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
- With several mics connected, **each one is held open** while warm, so you may see
  more than one mic listed as "in use" in Control Center. That's expected — Mic Warmer
  is keeping each awake. (Bluetooth mics are skipped, so your headphones keep full
  audio quality — see *Works with whatever mic you use* above.)

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
