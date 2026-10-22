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
  - Needle gauge covering ±50 cents (pegged beyond), with an in-tune zone that defaults to **±2¢** and can be set from ±1¢ to ±10¢ in Settings. Colours: green within the in-tune range, yellow out to ±10¢ (or the range, if wider), orange beyond.
  - In guitar mode, the 6 strings with the current one highlighted
  - Guitar/chromatic switch, tuning picker, current A4 value
- **Settings window** (two tabs):
  - **General:**
    - A4 calibration: 415–466 Hz, typed or stepped, with a reset to 440
    - Global sharps/flats
    - In-tune range: ±1¢ to ±10¢, default ±2¢. Many guitars' built-in tuners call a wider window "in tune".
    - Auto-stop timeout: 30 s to 10 min
    - Launch at login (`SMAppService`; the system is the source of truth, not a stored flag)
  - **Tunings:**
    - A list with **+** (new tuning, copying the selected one's notes, since alternate tunings usually differ from an existing one by a few strings) and **−** (with confirmation; the last tuning can't be deleted).
    - The editor covers the name, a sharps/flats override (or "use global"), and the 6 string notes. Each note can be typed (`D2`, `F#3`, `Bb2`) or stepped by semitones, and shows its frequency. Notes outside the detector's range are rejected.

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
  - **Octave check:** in a real low-E recording through a MacBook mic, the attack's 2nd harmonic dominated (fundamental ~14% of it, odd harmonics nearly absent). The waveform repeated almost perfectly at half the period, and plain YIN read E3, which guitar mode snapped to the D string. After YIN picks a period, the detector looks at twice that period. The doubled period wins only if its dip is under half as deep, at least 0.03 lower, **and** below 0.01, a near-perfect repeat.
    - The last condition was added after a second recording, of all six strings. A plucked high e carries a quiet sympathetic E3 (about 15% of E4 during the attack, from the open low E), so twice its period repeats *fairly* well (dips 0.008–0.05) but not as cleanly as a real low string's period (0.002–0.008). Without the condition the high e's attack read E3 and showed the D string. That real E3 lacks the odd partials a real E3 string would have, which is why it can't repeat as cleanly.
    - Measured on both recordings, scored per string: every string shows correctly, the high e never shows D3, and the low E shows D3 for one 80 ms flash plus a 0.5 s span from a damping transient (not a string reading). Thresholds from 0.008 to 0.0125 give the same result. No synthetic genuine notes are wrongly halved.
    - The sympathetic-E3 effect could not be reproduced synthetically (a synthetic E3 component repeats perfectly at the doubled period), so the detector's high-e behaviour is verified against the recording only.
    - Only 2× is checked; there's no evidence of 3× errors.
- **Smoothing** (`PitchSmoother`, applied in the session before display):
  - **Median of 9 readings** (~180 ms) settles jitter and drops pick-attack outliers.
  - **Note changes need evidence.** A harmonic can be misread as the note, both as a string fades (its fundamental sinks below the room noise first) and in a low string's attack (see the octave check). So:
    - **A new note** (from silence, or a jump within 150 ms of an **attack**, meaning a level rise of at least 6 dB over the previous 3 readings) is shown once **3 readings agree** (60 ms). On the real recording, the first one or two readings of a pluck could be an octave high.
    - **A jump up to a harmonic** of the current note (×2…×6, within 50¢) without an attack is rejected once the note has **settled** (0.6 s after it was committed): that's a harmonic outlasting the fundamental. While a note is still settling, an octave correction is allowed in either direction, since the detector can misjudge an attack's octave both ways. This limits the damage when the detector errs. With the looser octave check, it cut the high e's wrong display from 3.4 s to 0.5 s.
    - **Any other jump**, including **down** to a sub-harmonic, is accepted after 5 consistent readings (~100 ms). A jump down usually means the current note *was* a harmonic, so it must not need an attack. An earlier version rejected harmonic jumps in both directions, which locked onto E3 after an octave-high attack and never showed the real E2.
  - **Tail cutoff:** readings more than 30 dB below the note's peak are untrusted. The peak is kept until the next attack, so this also covers the fade after the note ends.
  - **Hold:** with no trusted pitch the last note stays for 1.5 s, dimmed after a 100 ms grace period so single dropouts don't flicker. After that, the ended note is remembered until the next attack, and its harmonics are still rejected.
  - **Needle:** spring with response 0.35 s and damping 0.85.

  These are constants, not user settings. They were checked against synthetic decaying plucks of all six strings at three noise floors (`fadingLowEStaysOnE2` is the regression test). Real recordings via a `tunelet-probe --record` option were considered and deferred until real-world results show they're needed.

## Build and distribution

- **Language and frameworks:** Swift.
  - AppKit for the status item, menu and popover
  - SwiftUI for the views
  - AVAudioEngine and Accelerate for audio
  - No third-party dependencies
- **Package layout:** a Swift Package, with no Xcode project; only the Command Line Tools are needed.
  - `TuneletCore` is a library for the DSP and note math.
  - `Tunelet` is the app executable.
- **App bundle:** `scripts/bundle.sh` assembles `Tunelet.app` with its Info.plist (`NSMicrophoneUsageDescription`, `LSUIElement`) and signs it. A self-signed Keychain code-signing identity keeps the mic permission across rebuilds. The identity comes from `$TUNELET_SIGN_IDENTITY` or a gitignored `.signing-identity` file; with neither, the script falls back to ad-hoc signing with a warning. `scripts/install.sh` release-builds the app, quits a running copy, and installs to `~/Applications`. The README has the certificate setup steps.
- **Lowest macOS version:** 26.
- **`@ViewState` instead of `@State`:** in the macOS 26 SDK, `@State` resolves to a macro whose plugin (SwiftUIMacros) ships only with Xcode. `ViewState` is a typealias for SwiftUI's `State` property wrapper, which skips the macro and has the same runtime behaviour. `@Observable` is unaffected, because its plugin is part of the toolchain.
- **Tests:** Swift Testing, run with `scripts/test.sh`, not a bare `swift test`. With only the Command Line Tools and a macOS 26 target, SwiftPM's default build engine sometimes compiles tests with an explicit plugin list that leaves out Swift Testing's macro plugin. The script adds the toolchain's testing plugin directory as a search path, worked out from `xcrun`. It also runs tests serially (`--no-parallel`); otherwise the analyzer timing test gets starved by the unoptimised full-pipeline tests running alongside it.
- **Real-signal fixtures:**
  - `audio-samples/` holds one real recording per string for each of three guitars: a Martin GPC-X1E and an HB CLC650 SM-CE (steel strings), and a Cordoba F7 (nylon). They're in tune by each guitar's own tuner, recorded through a MacBook mic, about 2 MB total. `RecordedStringTests` runs all 18 through the full pipeline. Guitar mode must show only that string, never another, and the settled reading must be within ±6¢. These tests fail on both earlier octave bugs (`f4449f6`: low E shown as D; `e141cc8`: high e shown as D) and pass on the fix.
  - The measured low-E attack and sustain spectra are also kept as synthetic profiles (`SyntheticSignal.lowEAttack` / `lowESustain`) for detector-level tests.
  - Settled readings on the samples range from −3.9¢ to +3.0¢ across all three guitars, leaving at least 2¢ of margin. The nylon guitar's are the tightest (−3.0¢ to +2.1¢). A hard-plucked low E reads +7 to +11¢ for its first second, which is real: amplitude-dependent tension makes it sound sharp. It then settles.
- **Bundle ID:** `com.craigmaslowski.Tunelet`.

## Build order

Each step is reviewed before the next one starts.

1. Pitch detection and note math, with tests against synthetic guitar signals
2. Real-time capture, the ring buffer and the analysis thread
3. Menu-bar shell and popover
4. Tuning screen
5. Settings
6. Signing, bundling and install
