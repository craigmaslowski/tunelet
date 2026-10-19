# Tunelet — Design

A menu-bar guitar tuner for macOS. Built mainly for one user, an acoustic player who uses uncommon alternate tunings.

## Features

- **Guitar mode** snaps to the nearest string of the current tuning and shows the offset from that string's target.
- **Chromatic mode** shows the nearest note in equal temperament. Use it for badly detuned strings, capos, and anything outside the current tuning.
- **Tunings are user-configured.** The only built-in one is Standard (E2 A2 D3 G3 B3 E4). Every tuning has exactly 6 strings.
- **A4 calibration** is a reference pitch setting that defaults to 440 Hz.
- **Sharps or flats** is a global preference (default: sharps). Each tuning can override it or follow the global setting. Chromatic mode uses the selected tuning's effective spelling, so note names don't change when you switch modes while tuning the same guitar.
- **Reference tones** are a nice-to-have that may slip from v1.

### Explicitly out of scope

- **"String tuned" markers.** Tuning one string changes neck tension, so strings tuned earlier drift. Markers would make people trust a stale result and skip re-checking every string.
- **Manual string lock.** Auto-snap plus chromatic mode covers this.
- **Tunings with other than 6 strings, and bass.**

## Interface

- **Menu-bar app** with no Dock icon (`LSUIElement`).
- **Menu-bar icon** is the `tuningfork` SF Symbol: a template image normally, tinted system orange while the mic is live, to match the macOS mic indicator. SF Symbols has no filled or circled variant of `tuningfork`, so a tint is the available way to show the live state.
- **Menu items:** Start Tuning, Settings…, Quit.
- **Start Tuning** opens an `NSPopover` under the icon and turns the mic on. The mic is never on outside tuning mode.
- **Ending tuning mode:**
  - Clicking away closes the popover and turns the mic off.
  - **Auto-stop:** the mic turns off after 2 minutes with no detected pitch. The time can be changed in Settings.
- **Tuning screen (popover):**
  - Large note name and cents offset
  - Measured frequency in Hz
  - Needle gauge covering ±50 cents (pegged beyond), with an in-tune zone of **±2¢**. Colours: green within ±2¢, yellow within ±10¢, orange beyond.
  - In guitar mode, the 6 strings with the current one highlighted
  - Guitar/chromatic switch, tuning picker, current A4 value
- **Settings window:**
  - Tuning editor
  - A4 calibration
  - Auto-stop timeout
  - Launch at login toggle (`SMAppService`)

## Audio and signal processing

- **Capture:** `AVAudioSinkNode`, so the app receives the small hardware buffers. The real-time callback only copies samples into a lock-free ring buffer: no allocation and no locks.
  - **Ring buffer (`SampleRing`):** holds about 1 s of channel-0 samples. The producer records how far it is about to write before writing, then publishes the new end. The consumer copies the newest window, then checks against that reservation and throws away any copy a write overlapped. A stress test confirms copies are never torn.
- **Analysis thread (`PitchAnalyzer`):** a dispatch timer on its own queue at `userInteractive` priority. It runs every ~20 ms (~50 readings/s) over a ~85 ms window (4096 samples at 48 kHz), and skips a run when no new audio has arrived. Windows quieter than -50 dBFS RMS count as silence, and YIN isn't run on them.
- **Output:** raw readings (pitch or none, plus RMS level) are delivered to the main actor. Smoothing is applied on top of these in the tuning screen layer (step 4).
- **Device changes:** on `AVAudioEngineConfigurationChange`, capture rebuilds for the new format.
- **`tunelet-probe`:** a command-line tool (`swift run tunelet-probe [seconds]`) that prints live readings. It's for checking capture against a real guitar.
- **Pitch detection:** YIN, using the cumulative mean normalized difference and parabolic interpolation, computed with vDSP.
  - **Range:** 60 Hz–1.2 kHz. The lowest tuning in use has D2 (73.4 Hz) on the 6th string, so 60 Hz leaves room below it.
  - **Confidence:** YIN's confidence value decides whether a pitch is present. It drives the display and the auto-stop timer.
  - **Pitch reference:** Tunelet reports the period of the whole waveform, not the bare fundamental. Real strings are stiff, so their overtones run slightly sharp and pull the reading about 1–1.5¢ sharp of the fundamental on a modelled stiff string. The ear is pulled the same way, the effect is below audibility, and most software tuners behave like this. Correcting toward the bare fundamental was considered and rejected: it adds an FFT refinement step, and the low E's fundamental is its weakest partial, so the correction would be noisiest where it matters most.
  - **Measured accuracy:** about 0.25¢ or better on clean harmonic signals from D2 to E5, at 44.1, 48 and 96 kHz.
- **Smoothing:**
  - Median of the last few readings, which drops outliers from the pick attack
  - Spring-animated needle
  - Reset when the note jumps by more than about 1 semitone, so a newly plucked string shows immediately
  - When the note dies, the last reading stays on screen briefly, dimmed

  Smoothing amounts are constants, set by ear on a real guitar. They are not user settings. Starting values:
  - median of 5 readings (~100 ms)
  - jump threshold 100¢. A jump only resets once **two consecutive readings agree** on the new note, so a lone octave error is ignored, at a cost of one reading (20 ms).
  - hold 1.5 s
  - needle spring: response 0.25 s, damping 0.8

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
- **Tests:** Swift Testing, run with `scripts/test.sh`, not a bare `swift test`. With only the Command Line Tools and a macOS 26 target, SwiftPM's default build engine sometimes compiles tests with an explicit plugin list that leaves out Swift Testing's macro plugin. The script adds the toolchain's testing plugin directory as a search path, worked out from `xcrun`.
- **Bundle ID:** `com.craigmaslowski.Tunelet`.

## Build order

Each step is reviewed before the next one starts.

1. Pitch detection and note math, with tests against synthetic guitar signals
2. Real-time capture, the ring buffer and the analysis thread
3. Menu-bar shell and popover
4. Tuning screen
5. Settings
6. Signing, bundling and install
