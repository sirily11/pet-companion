import SwiftUI

struct LocalModelSettingsView: View {
    @ObservedObject var models: OpenJevModelStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRemoval = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Local Open-Jev", systemImage: "pawprint").font(.system(size: 24, weight: .medium, design: .serif))
            Text("Download the trained Open-Jev 2B model to choose reactions and poses on this Mac. Local decisions work without a Gateway key.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            HStack {
                Label("Open-Jev 2B", systemImage: "cpu")
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: models.manifest.totalBytes, countStyle: .decimal)).foregroundStyle(.secondary)
            }.font(.system(size: 13, weight: .medium))
            Text("Apple Silicon · 16 GB memory recommended. Model files download separately and stay on this Mac.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if models.phase == .downloading || models.phase == .verifying || models.phase == .paused {
                ProgressView(value: models.progress)
                Text("\(ByteCountFormatter.string(fromByteCount: models.downloadedBytes, countStyle: .decimal)) of \(ByteCountFormatter.string(fromByteCount: models.manifest.totalBytes, countStyle: .decimal))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Label(status, systemImage: models.isInstalled ? "checkmark.circle" : "arrow.down.circle")
                .font(.system(size: 12)).foregroundStyle(models.isInstalled ? .green : .secondary)
            if let error = models.error { Text(error).font(.system(size: 12)).foregroundStyle(.red) }
            HStack(spacing: 16) {
                Link("Model and license", destination: URL(string: "https://huggingface.co/ZefanCai/Open-Jev-2B")!)
                Link("Qwen base model", destination: URL(string: "https://huggingface.co/Qwen/Qwen3.5-2B")!)
            }.font(.system(size: 11))
            Divider()
            HStack {
                if models.phase != .notInstalled {
                    Button(role: .destructive) { confirmRemoval = true } label: { Label("Remove", systemImage: "trash") }
                        .disabled(models.phase == .removing)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                if models.phase == .downloading || models.phase == .verifying {
                    Button { models.pause() } label: { Label("Cancel download", systemImage: "pause.circle") }
                } else if !models.isInstalled && models.phase != .removing {
                    Button { models.startDownload() } label: {
                        Label(models.phase == .notInstalled ? "Download · 4.6 GB" : "Resume download", systemImage: "arrow.down.circle")
                    }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(28).frame(width: 510)
        .alert("Remove the local Open-Jev model?", isPresented: $confirmRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { Task { await models.remove() } }
        } message: { Text("Local decisions will need another download. Cloud JEV remains available in AI Settings.") }
    }
    private var status: String {
        switch models.phase {
        case .notInstalled: "Not downloaded"
        case .downloading: "Downloading…"
        case .paused: "Download paused. Resume when you’re ready."
        case .verifying: "Verifying model files…"
        case .ready: "Installed and ready"
        case .removing: "Removing model…"
        case .failed: "Download needs attention"
        }
    }
}
