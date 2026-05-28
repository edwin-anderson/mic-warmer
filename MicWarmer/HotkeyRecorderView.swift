import SwiftUI
import KeyboardShortcuts

struct HotkeyRecorderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Mic Warmer")
                .font(.headline)

            Text("Pick a global hotkey to warm / cool the microphone. Click the field, then press your combination — it must include at least one modifier (⌘, ⌥, ⌃, or ⇧). Press it once to hold the mic open so dictation is instant; press it again to release.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Warm/cool hotkey:")
                KeyboardShortcuts.Recorder(for: .toggleWarm)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 400, height: 200)
    }
}
