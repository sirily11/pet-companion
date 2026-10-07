import SwiftUI

struct GatewaySettingsView: View {
    @ObservedObject var settings: GatewaySettings
    @ObservedObject var models: OpenJevModelStore
    let onChange: () -> Void
    let onDecisionChange: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var confirmRemoval = false
    @State private var showingModels = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("AI Settings", systemImage: "sparkles").font(.system(size: 25, weight: .medium, design: .serif))
            Text("Connect voice conversations and cloud decisions with your own Vercel AI Gateway key.")
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
                Label("Gemini Live and GPT Realtime · Voice", systemImage: "waveform")
                Picker("Pet reactions and poses", selection: $settings.decisionBackend) {
                    ForEach(DecisionBackend.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.menu)
                Button { showingModels = true } label: { Label("Manage local model…", systemImage: "internaldrive") }
                if settings.decisionBackend == .local {
                    Text(models.isInstalled ? "Local decisions stay on this Mac. Voice conversations still use Gateway." : "Download Open-Jev in Manage local model before using local decisions.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
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
        .onChange(of: settings.decisionBackend) { _, _ in onDecisionChange() }
        .sheet(isPresented: $showingModels) { LocalModelSettingsView(models: models) }
        .alert("Remove your AI Gateway key?", isPresented: $confirmRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { if settings.remove() { onChange() } }
        } message: { Text("Cloud decisions and live conversations will need a new key. Local Open-Jev, manual poses, and the voice demo will keep working.") }
    }
}
