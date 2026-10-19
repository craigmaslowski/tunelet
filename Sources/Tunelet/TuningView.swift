import AppKit
import SwiftUI
import TuneletCore

/// Offsets within this many cents count as in tune.
let inTuneCents = 2.0

/// Contents of the tuning popover.
struct TuningView: View {
    let session: TuningSession
    @Bindable var preferences: Preferences

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Picker("Mode", selection: $preferences.mode) {
                    Text("Guitar").tag(TunerMode.guitar)
                    Text("Chromatic").tag(TunerMode.chromatic)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                Picker("Tuning", selection: $preferences.selectedTuningID) {
                    ForEach(preferences.tunings) { tuning in
                        Text(tuning.name).tag(tuning.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
            }

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
                    TunerReadout(pitch: session.pitch, preferences: preferences)
                }
            }
            // Top-aligned so the gauge stays put when the strings row comes and goes with the mode.
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: session.state == .listening ? .top : .center)

            Text("A4 = \(preferences.a4.formatted(.number.precision(.fractionLength(0...1)))) Hz")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340, height: 400)
    }
}

// MARK: - Readout

private struct TunerReadout: View {
    let pitch: PitchSmoother.Output
    let preferences: Preferences

    var body: some View {
        let tuning = preferences.selectedTuning
        let accidentals = preferences.effectiveAccidentals
        let (frequency, held): (Double?, Bool) = switch pitch {
        case .pitch(let f): (f, false)
        case .held(let f): (f, true)
        case .none: (nil, false)
        }
        let target = frequency.map { preferences.mode.target(for: $0, tuning: tuning, a4: preferences.a4) }
        let inTune = target.map { abs($0.cents) <= inTuneCents } ?? false
        let color = target.map { centsColor($0.cents) } ?? Color.secondary

        VStack(spacing: 10) {
            // Note name with a smaller octave number.
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(target.map { $0.note.name(accidentals) } ?? "–")
                    .font(.system(size: 64, weight: target == nil ? .ultraLight : .bold, design: .rounded))
                Text(target.map { "\($0.note.octave)" } ?? " ")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(inTune ? Color.green : Color.primary)
            .frame(height: 76)

            HStack(spacing: 18) {
                Text(target.map { formatCents($0.cents) } ?? "Pluck a string")
                    .foregroundStyle(target == nil ? Color.secondary : color)
                if let frequency {
                    Text(String(format: "%.2f Hz", frequency))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.title3.monospacedDigit())

            GaugeView(cents: target?.cents ?? 0, active: target != nil, color: color)
                .frame(height: 110)

            if preferences.mode == .guitar {
                StringsRow(tuning: tuning, accidentals: accidentals,
                           active: target?.string, inTune: inTune)
            }
        }
        // A held reading is the last value after the string went quiet: still readable, clearly stale.
        .opacity(held ? 0.45 : 1)
        .animation(.easeOut(duration: 0.2), value: held)
    }

    private func formatCents(_ cents: Double) -> String {
        let rounded = (cents * 10).rounded() / 10
        if rounded == 0 { return "0.0¢" }
        // Typographic minus (U+2212) rather than a hyphen.
        return (rounded > 0 ? "+" : "\u{2212}") + String(format: "%.1f¢", abs(rounded))
    }
}

func centsColor(_ cents: Double) -> Color {
    switch abs(cents) {
    case ...inTuneCents: .green
    case ...10: .yellow
    default: .orange
    }
}

// MARK: - Gauge

struct GaugeView: View {
    var cents: Double
    var active: Bool
    var color: Color

    private static let range = 50.0       // ± cents shown
    private static let sweep = 55.0       // ± degrees from vertical

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height - 6)
            let radius = min(geo.size.width / 2 - 24, geo.size.height - 22)
            let angle = active ? max(-Self.range, min(Self.range, cents)) / Self.range * Self.sweep : 0

            ZStack {
                Canvas { context, _ in
                    // In-tune band.
                    var band = Path()
                    let bandAngle = inTuneCents / Self.range * Self.sweep
                    for step in 0...12 {
                        let a = -bandAngle + 2 * bandAngle * Double(step) / 12
                        let p = Self.point(center, radius - 4, a)
                        step == 0 ? band.move(to: p) : band.addLine(to: p)
                    }
                    context.stroke(band, with: .color(.green.opacity(0.55)), lineWidth: 10)

                    // Ticks every 5¢, long ones every 25¢.
                    for c in stride(from: -50, through: 50, by: 5) {
                        let a = Double(c) / Self.range * Self.sweep
                        let major = c % 25 == 0
                        var tick = Path()
                        tick.move(to: Self.point(center, radius - (major ? 14 : 7), a))
                        tick.addLine(to: Self.point(center, radius, a))
                        context.stroke(tick, with: .color(.secondary), lineWidth: major ? 1.5 : 1)
                    }
                    context.draw(Text("♭").font(.callout).foregroundStyle(.secondary),
                                 at: Self.point(center, radius + 12, -Self.sweep))
                    context.draw(Text("♯").font(.callout).foregroundStyle(.secondary),
                                 at: Self.point(center, radius + 12, Self.sweep))

                    context.fill(Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)),
                                 with: .color(.primary))
                }

                Needle(center: center, length: radius - 2, angle: angle)
                    .stroke(active ? color : Color.secondary.opacity(0.35),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: angle)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(active ? String(format: "%+.0f cents", cents) : "No note")
    }

    /// Point at `radius` from `center`, `degrees` clockwise from straight up.
    nonisolated static func point(_ center: CGPoint, _ radius: Double, _ degrees: Double) -> CGPoint {
        let r = degrees * .pi / 180
        return CGPoint(x: center.x + radius * sin(r), y: center.y - radius * cos(r))
    }
}

private struct Needle: Shape {
    var center: CGPoint
    var length: Double
    var angle: Double

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: center)
        path.addLine(to: GaugeView.point(center, length, angle))
        return path
    }
}

// MARK: - Strings

private struct StringsRow: View {
    let tuning: Tuning
    let accidentals: Accidentals
    let active: Int?
    let inTune: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tuning.strings.indices, id: \.self) { i in
                let isActive = i == active
                VStack(spacing: 3) {
                    Circle()
                        .fill(isActive ? (inTune ? Color.green : Color.accentColor) : Color.secondary.opacity(0.15))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Text(tuning.strings[i].name(accidentals))
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(isActive ? Color.white : Color.primary)
                        )
                    Text("\(Tuning.stringCount - i)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement()
                .accessibilityLabel("String \(Tuning.stringCount - i), \(tuning.strings[i].label(accidentals))")
            }
        }
        .animation(.easeOut(duration: 0.12), value: active)
        .animation(.easeOut(duration: 0.12), value: inTune)
    }
}

// MARK: - Permission

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
