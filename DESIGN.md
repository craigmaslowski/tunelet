# Tunelet — Design

A menu-bar guitar tuner for macOS. Built mainly for one user, an acoustic player who uses uncommon alternate tunings.

## Features

- **Guitar mode** snaps to the nearest string of the current tuning and shows the offset from that string's target.
- **Chromatic mode** shows the nearest note in equal temperament. Use it for badly detuned strings, capos, and anything outside the current tuning.
- **Tunings are user-configured.** The only built-in one is Standard (E2 A2 D3 G3 B3 E4). Every tuning has exactly 6 strings.
- **A4 calibration** is a reference pitch setting that defaults to 440 Hz.
- **Reference tones** are a nice-to-have that may slip from v1.

### Explicitly out of scope

- **"String tuned" markers.** Tuning one string changes neck tension, so strings tuned earlier drift. Markers would make people trust a stale result and skip re-checking every string.
- **Manual string lock.** Auto-snap plus chromatic mode covers this.
- **Tunings with other than 6 strings, and bass.**

## Interface

- **Menu-bar app** with no Dock icon (`LSUIElement`).
- **Menu-bar icon** is the `tuningfork` SF Symbol. It changes while the mic is live; the exact live-state look is decided in step 3.
- **Menu items:** Start Tuning, Settings…, Quit.
- **Start Tuning** opens an `NSPopover` under the icon and turns the mic on. The mic is never on outside tuning mode.
- **Ending tuning mode:**
  - Clicking away closes the popover and turns the mic off.
  - **Auto-stop:** the mic turns off after 2 minutes with no detected pitch. The time can be changed in Settings.
- **Tuning screen (popover):**
  - Large note name and cents offset
  - Measured frequency in Hz
  - Needle gauge covering ±50 cents, with an in-tune zone
  - In guitar mode, the 6 strings with the current one highlighted
  - Guitar/chromatic switch, tuning picker, current A4 value
- **Settings window:**
  - Tuning editor
  - A4 calibration
  - Auto-stop timeout
  - Launch at login toggle (`SMAppService`)

## Audio and signal processing

- **Capture:** `AVAudioSinkNode`, so the app receives the small hardware buffers. The real-time callback only copies samples into a lock-free ring buffer: no allocation and no locks.
- **Analysis thread:** runs every ~20 ms (~50 readings/s) over a ~85 ms window (4096 samples at 48 kHz).
- **Pitch detection:** YIN, using the cumulative mean normalized difference and parabolic interpolation, computed with vDSP.
  - **Range:** 60 Hz–1.2 kHz. The lowest tuning in use has D2 (73.4 Hz) on the 6th string, so 60 Hz leaves room below it.
  - **Confidence:** YIN's confidence value decides whether a pitch is present. It drives the display and the auto-stop timer.
- **Smoothing:**
  - Median of the last few readings, which drops outliers from the pick attack
  - Spring-animated needle
  - Reset when the note jumps by more than about 1 semitone, so a newly plucked string shows immediately
  - When the note dies, the last reading stays on screen briefly, dimmed

  Smoothing amounts are constants, set by ear on a real guitar. They are not user settings.

## Build and distribution

- **Language and frameworks:** Swift.
  - AppKit for the status item, menu and popover
  - SwiftUI for the views
  - AVAudioEngine and Accelerate for audio
  - No third-party dependencies
- **Package layout:** a Swift Package, with no Xcode project; only the Command Line Tools are needed.
  - `TuneletCore` is a library for the DSP and note math.
  - `Tunelet` is the app executable.
- **App bundle:** a script assembles `Tunelet.app` with its Info.plist (`NSMicrophoneUsageDescription`, `LSUIElement`). It signs the app with a self-signed Keychain code-signing identity, so the mic permission survives rebuilds, then installs it to `~/Applications`.
- **Lowest macOS version:** 26.
- **Tests:** Swift Testing through `swift test`.
- **Bundle ID:** `com.craigmaslowski.Tunelet`.

## Build order

Each step is reviewed before the next one starts.

1. Pitch detection and note math, with tests against synthetic guitar signals
2. Real-time capture, the ring buffer and the analysis thread
3. Menu-bar shell and popover
4. Tuning screen
5. Settings
6. Signing, bundling and install
