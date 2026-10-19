import SwiftUI

/// Settings window contents. Step 3 placeholder; the full settings arrive in step 5.
struct SettingsView: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Stepper(value: $preferences.autoStopSeconds, in: Preferences.autoStopRange, step: 30) {
                Text("Stop listening after \(Int(preferences.autoStopSeconds)) s without a note")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
