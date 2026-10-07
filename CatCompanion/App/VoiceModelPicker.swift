import SwiftUI

struct VoiceModelPicker: View {
    @ObservedObject var settings: GatewaySettings
    @ObservedObject var catalog: ModelCatalog
    @ObservedObject var coordinator: CompanionCoordinator
    private var locked: Bool { coordinator.live.state != .disconnected || coordinator.isRequestingMicrophone }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Provider", systemImage: "waveform").font(.system(size: 10)).foregroundStyle(.secondary)
                    Picker("Provider", selection: $settings.provider) {
                        ForEach(LiveChatProvider.allCases) { provider in
                            Text(provider == .gemini ? "Gemini" : "GPT").tag(provider)
                        }
                    }.labelsHidden().frame(width: 105)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model").font(.system(size: 10)).foregroundStyle(.secondary)
                    Picker("Model", selection: Binding(get: { settings.selectedModel }, set: {
                        settings.selectModel($0); coordinator.voiceSelectionDidChange()
                    })) {
                        if !catalog.contains(settings.selectedModel, provider: settings.provider) {
                            Text("\(settings.selectedModel) · Unavailable").tag(settings.selectedModel)
                        }
                        ForEach(catalog.models(for: settings.provider)) { model in Text(model.name).tag(model.id) }
                    }.labelsHidden().frame(maxWidth: .infinity)
                }
                Button { Task { await catalog.refresh(force: true) } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }.buttonStyle(.plain).help("Refresh models").disabled(catalog.isRefreshing).padding(.top, 22)
            }.pickerStyle(.menu).disabled(locked)
            if let error = catalog.error { Text(error).font(.system(size: 10)).foregroundStyle(.secondary) }
            if !catalog.contains(settings.selectedModel, provider: settings.provider) {
                Text("Choose an available model before starting.").font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        .onChange(of: settings.provider) { _, _ in coordinator.voiceSelectionDidChange() }
        .task { await catalog.refresh() }
    }
}
