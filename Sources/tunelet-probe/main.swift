// Prints live pitch readings from the default input device, to check capture against a real guitar.
//
//   swift run tunelet-probe [seconds]      (default 30)
//
// macOS asks for microphone access for the terminal app the first time.

import AVFoundation
import TuneletCore

let duration = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 30
let a4 = 440.0
let tuning = Tuning.standard
let capture = AudioCapture()
var readings = 0
var pitched = 0

@MainActor
func format(_ reading: PitchReading) -> String {
    let level = String(format: "%6.1f dBFS", reading.levelDBFS)
    guard let estimate = reading.estimate else { return "  ——               \(level)" }
    let string = tuning.nearestString(to: estimate.frequency, a4: a4)
    let chromatic = Pitch.nearestNote(to: estimate.frequency, a4: a4)
    return String(format: "%@ %+6.1f¢   %8.2f Hz   chromatic %@ %+5.1f¢   conf %.2f   %@",
                  tuning.strings[string.index].label(.sharps).padding(toLength: 3, withPad: " ", startingAt: 0),
                  string.cents, estimate.frequency,
                  chromatic.note.label(.sharps).padding(toLength: 3, withPad: " ", startingAt: 0),
                  chromatic.cents, estimate.confidence, level)
}

@MainActor
func startCapture() {
    capture.onReading = { reading in
        readings += 1
        if reading.estimate != nil { pitched += 1 }
        // Every 5th reading (~10 lines/s) keeps it readable.
        if readings % 5 == 0 { print(format(reading)) }
    }
    capture.onFailure = { error in
        print("capture stopped: \(error.localizedDescription)")
        exit(1)
    }
    do {
        try capture.start()
    } catch {
        print("could not start capture: \(error.localizedDescription)")
        exit(1)
    }
    print("Listening at \(Int(capture.sampleRate)) Hz for \(Int(duration)) s. Standard tuning, A4 = \(Int(a4)) Hz.\n")

    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        MainActor.assumeIsolated {
            capture.stop()
            print(String(format: "\n%d readings in %.0f s (%.1f/s), %d with a pitch.",
                         readings, duration, Double(readings) / duration, pitched))
            exit(0)
        }
    }
}

AVCaptureDevice.requestAccess(for: .audio) { granted in
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            if granted {
                startCapture()
            } else {
                print("Microphone access denied. Allow your terminal in System Settings → Privacy & Security → Microphone.")
                exit(1)
            }
        }
    }
}
dispatchMain()
