import ServiceManagement
import SwiftUI
import TuneletCore

/// Settings window contents.
struct SettingsView: View {
    @Bindable var preferences: Preferences

    var body: some View {
        TabView {
            GeneralSettings(preferences: preferences)
                .tabItem { Label("General", systemImage: "gearshape") }
            TuningsEditor(preferences: preferences)
                .tabItem { Label("Tunings", systemImage: "tuningfork") }
        }
        .padding(12)
        .frame(width: 580, height: 580)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var preferences: Preferences
    @ViewState private var launchAtLogin = LaunchAtLogin()

    private static let autoStopChoices: [(String, TimeInterval)] = [
        ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120),
        ("3 minutes", 180), ("5 minutes", 300), ("10 minutes", 600),
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent("A4 reference") {
                    HStack(spacing: 6) {
                        TextField("A4", value: $preferences.a4,
                                  format: .number.precision(.fractionLength(0...1)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("Hz")
                        Stepper("A4", value: $preferences.a4, in: Preferences.a4Range, step: 1)
                            .labelsHidden()
                        Button("Reset") { preferences.a4 = 440 }
                            .disabled(preferences.a4 == 440)
                    }
                }
                .onChange(of: preferences.a4) { _, value in
                    // Typed values outside the range are pulled back in.
                    let clamped = min(max(value, Preferences.a4Range.lowerBound), Preferences.a4Range.upperBound)
                    if clamped != value { preferences.a4 = clamped }
                }

                Picker("Note names", selection: $preferences.accidentals) {
                    Text("Sharps (C♯, F♯)").tag(Accidentals.sharps)
                    Text("Flats (D♭, G♭)").tag(Accidentals.flats)
                }

                LabeledContent("In tune within") {
                    HStack(spacing: 6) {
                        Text("±\(Int(preferences.inTuneCents))¢").monospacedDigit()
                        Stepper("In tune within", value: $preferences.inTuneCents,
                                in: Preferences.inTuneRange, step: 1)
                            .labelsHidden()
                        Button("Reset") { preferences.inTuneCents = 2 }
                            .disabled(preferences.inTuneCents == 2)
                    }
                }
            } footer: {
                Text("Tunings can override the note-name setting in the Tunings tab. Offsets inside the in-tune range show green.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Reference tones", isOn: $preferences.referenceTones)
                Text("Click a string in the tuner to hear its note. The tuner ignores the microphone while the tone plays.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Stop listening after", selection: $preferences.autoStopSeconds) {
                    ForEach(Self.autoStopChoices, id: \.1) { label, seconds in
                        Text(label).tag(seconds)
                    }
                }
                Text("The microphone turns off when this long passes without a note.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if launchAtLogin.needsApproval {
                    HStack {
                        Text("Approve Tunelet in Login Items to finish turning this on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let error = launchAtLogin.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin.refresh() }
    }
}

/// Wraps the system login-item registration. The system, not UserDefaults, is the source of truth.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var error: String?

    init() { refresh() }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        error = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}

// MARK: - Tunings

private struct TuningsEditor: View {
    @Bindable var preferences: Preferences
    @ViewState private var selection: UUID?
    @ViewState private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(preferences.tunings) { tuning in
                        Text(tuning.name.isEmpty ? "Untitled" : tuning.name).tag(tuning.id)
                    }
                }
                .listStyle(.bordered)

                HStack(spacing: 0) {
                    Button(action: addTuning) { Image(systemName: "plus").frame(width: 24, height: 20) }
                        .help("New tuning, starting from the selected one")
                    Button { confirmingDelete = true } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .help("Delete the selected tuning")
                        .disabled(selection == nil || preferences.tunings.count <= 1)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.top, 4)
            }
            .frame(width: 170)

            Group {
                if let id = selection, preferences.tunings.contains(where: { $0.id == id }) {
                    TuningDetail(tuning: binding(for: id), preferences: preferences)
                        .id(id)
                } else {
                    Text("Select a tuning").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.leading, 12)
        }
        .padding(8)
        .onAppear { selection = selection ?? preferences.selectedTuningID }
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: deleteSelected)
        }
    }

    private var deleteTitle: String {
        let name = preferences.tunings.first { $0.id == selection }?.name ?? ""
        return "Delete “\(name.isEmpty ? "Untitled" : name)”?"
    }

    /// Looks the tuning up by id on every access, so a deletion can never leave a stale index.
    private func binding(for id: UUID) -> Binding<Tuning> {
        Binding(
            get: { preferences.tunings.first { $0.id == id } ?? .standard },
            set: { updated in
                if let index = preferences.tunings.firstIndex(where: { $0.id == id }) {
                    preferences.tunings[index] = updated
                }
            }
        )
    }

    private func addTuning() {
        let base = preferences.tunings.first { $0.id == selection } ?? preferences.selectedTuning
        let tuning = Tuning(name: "New Tuning", strings: base.strings, accidentals: base.accidentals)
        preferences.tunings.append(tuning)
        selection = tuning.id
    }

    private func deleteSelected() {
        guard let id = selection, preferences.tunings.count > 1,
              let index = preferences.tunings.firstIndex(where: { $0.id == id }) else { return }
        let neighbour = preferences.tunings[index == 0 ? 1 : index - 1].id
        selection = neighbour
        preferences.tunings.remove(at: index)
    }
}

private struct TuningDetail: View {
    @Binding var tuning: Tuning
    let preferences: Preferences

    var body: some View {
        Form {
            TextField("Name", text: $tuning.name)

            Picker("Note names", selection: $tuning.accidentals) {
                Text("Use global setting (\(preferences.accidentals == .sharps ? "sharps" : "flats"))")
                    .tag(Accidentals?.none)
                Text("Sharps").tag(Accidentals?.some(.sharps))
                Text("Flats").tag(Accidentals?.some(.flats))
            }

            Section("Strings") {
                LabeledContent("Number of strings") {
                    HStack(spacing: 6) {
                        Text("\(tuning.strings.count)").monospacedDigit()
                        Stepper("Number of strings", value: stringCount, in: Tuning.stringCountRange)
                            .labelsHidden()
                    }
                }
                .help("Adds or removes a string on the bass side")

                ForEach(tuning.strings.indices, id: \.self) { i in
                    StringNoteField(
                        number: tuning.strings.count - i,
                        note: $tuning.strings[i],
                        accidentals: tuning.accidentals(default: preferences.accidentals),
                        a4: preferences.a4
                    )
                    // Fields are identified by position; start fresh when strings are added or
                    // removed, or each would keep showing its old note.
                    .id("\(tuning.strings.count)-\(i)")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The string count; changing it adds or removes strings on the bass side.
    private var stringCount: Binding<Int> {
        Binding(
            get: { tuning.strings.count },
            set: { count in
                while tuning.strings.count < count, let more = tuning.addingBassString() { tuning = more }
                while tuning.strings.count > count, let fewer = tuning.removingBassString() { tuning = fewer }
            }
        )
    }
}

/// One string's note: type a name ("D2", "F#3", "Bb2") or step by semitones.
private struct StringNoteField: View {
    let number: Int
    @Binding var note: Note
    let accidentals: Accidentals
    let a4: Double

    @ViewState private var text = ""
    @ViewState private var problem: String?
    @FocusState private var focused: Bool

    var body: some View {
        LabeledContent("String \(number)") {
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    TextField("Note", text: $text)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 70)
                        .focused($focused)
                        .foregroundStyle(problem == nil ? Color.primary : Color.red)
                        .onChange(of: text) { _, value in apply(value) }
                        .onSubmit { revertIfInvalid() }
                    Stepper("Semitones", onIncrement: { step(1) }, onDecrement: { step(-1) })
                        .labelsHidden()
                    Text(String(format: "%.1f Hz", note.frequency(a4: a4)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onAppear { text = note.label(accidentals) }
        .onChange(of: accidentals) { _, value in text = note.label(value) }
        .onChange(of: focused) { _, isFocused in if !isFocused { revertIfInvalid() } }
    }

    /// From an 8-string's low F♯1 up to the detector's ceiling.
    private func detectable(_ candidate: Note) -> Bool {
        candidate.midi >= Tuning.lowestNote.midi && candidate.frequency(a4: a4) <= YINDetector.defaultRange.upperBound
    }

    /// Lowest and highest allowed notes at the current A4, e.g. "F♯1 to D6".
    private var rangeDescription: String {
        let notes = (0...127).map(Note.init(midi:)).filter(detectable)
        guard let low = notes.first, let high = notes.last else { return "none" }
        return "\(low.label(accidentals)) to \(high.label(accidentals))"
    }

    /// Commits the text as soon as it names a usable note; otherwise just flags it.
    private func apply(_ value: String) {
        guard let parsed = Note(value) else {
            problem = "Enter a note like D2, F#3 or Bb2"
            return
        }
        guard detectable(parsed) else {
            problem = "Outside Tunelet's range (\(rangeDescription))"
            return
        }
        problem = nil
        if parsed != note { note = parsed }
    }

    private func step(_ semitones: Int) {
        let next = Note(midi: note.midi + semitones)
        guard detectable(next) else { return }
        note = next
        text = next.label(accidentals)
        problem = nil
    }

    private func revertIfInvalid() {
        if problem != nil {
            text = note.label(accidentals)
            problem = nil
        } else {
            // Normalise spelling, e.g. "f#3" → "F♯3".
            text = note.label(accidentals)
        }
    }
}
