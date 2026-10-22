# Audio samples

One recording per string of two acoustic guitars in standard tuning, each string in tune according to that guitar's built-in tuner. Recorded through a MacBook's built-in microphone: mono, 48 kHz, AAC.

| Prefix | Guitar |
|---|---|
| `martin-gpc-x1e-` | Martin GPC-X1E |
| `hb-clc650-sm-ce-` | HB CLC650 SM-CE |

These are test fixtures. `Tests/TuneletCoreTests/RecordedStringTests.swift` runs each one through the detector and smoother, and checks that guitar mode shows only that string and reads it in tune. They cover failures synthetic signals didn't reproduce: a laptop mic's weak low end makes the low E's attack look an octave high, and sympathetic resonance from the low E makes the high e's attack look an octave low.
