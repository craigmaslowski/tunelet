import AppKit
import SwiftUI
import TuneletCore

/// Contents of the tuning popover.
struct TuningView: View {
    let session: TuningSession

    var body: some View {
        Group {
            switch session.state {
            case .idle, .requestingPermission:
                ProgressView().controlSize(.small)
            case .permissionDenied:
                PermissionDeniedView()
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            case .listening:
                RawReadingView(reading: session.reading)
            }
        }
        .padding(20)
        .frame(width: 360, height: 260)
    }
}

private struct PermissionDeniedView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "mic.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text("Microphone access is off").font(.headline)
            Text("Allow Tunelet in System Settings → Privacy & Security → Microphone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

/// Step 3 placeholder: raw, unsmoothed readings against Standard tuning. Replaced in step 4.
private struct RawReadingView: View {
    let reading: PitchReading?

    var body: some View {
        VStack(spacing: 8) {
            if let estimate = reading?.estimate {
                let nearest = Tuning.standard.nearestString(to: estimate.frequency, a4: 440)
                Text(Tuning.standard.strings[nearest.index].label(.sharps))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                Text(String(format: "%+.1f¢   %.2f Hz", nearest.cents, estimate.frequency))
                    .font(.title3.monospacedDigit())
            } else {
                Text("Pluck a string").font(.title2).foregroundStyle(.secondary)
            }
            if let reading {
                Text(String(format: "%.0f dBFS", reading.levelDBFS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
