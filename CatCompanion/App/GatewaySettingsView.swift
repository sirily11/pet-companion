import SwiftUI

struct GatewaySettingsView: View {
    @ObservedObject var settings: GatewaySettings
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var confirmRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("AI Settings", systemImage: "sparkles").font(.system(size: 25, weight: .medium, design: .serif))
            Text("Give your cat a voice and a little personality. Connect with your own Vercel AI Gateway key.")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("AI Gateway key").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if settings.hasKey { Label("Saved in Keychain", systemImage: "checkmark.shield").font(.system(size: 11)).foregroundStyle(.green) }
                }
                SecureField(settings.hasKey ? "Enter a new key to replace the saved key" : "Paste your AI Gateway key", text: $key)
                    .textFieldStyle(.roundedBorder)
                Text("Stored securely in macOS Keychain. Your Mac connects directly to AI Gateway.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Link("Get an AI Gateway key", destination: URL(string: "https://vercel.com/ai-gateway")!)
                    .font(.system(size: 12))
            }
            VStack(alignment: .leading, spacing: 9) {
                Label("Gemini 3.8 Live · Voice", systemImage: "waveform")
                Label("Jev · Pet reactions and poses", systemImage: "pawprint")
            }.font(.system(size: 12)).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            if let error = settings.error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                if settings.hasKey {
                    Button("Remove key", role: .destructive) { confirmRemoval = true }.buttonStyle(.borderless)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(settings.hasKey ? "Replace key" : "Save key") {
                    if settings.save(key) { onChange(); key = ""; dismiss() }
                }.buttonStyle(.borderedProminent).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30).frame(width: 490)
        .onDisappear { key = "" }
        .alert("Remove your AI Gateway key?", isPresented: $confirmRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { if settings.remove() { onChange() } }
        } message: { Text("Pet reactions and live conversations will need a new key. Manual poses and the voice demo will keep working.") }
    }
}
