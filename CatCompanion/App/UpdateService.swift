import Combine
import Sparkle
import SwiftUI

/// Sparkle schedules, verifies, installs, and presents updates with its native UI.
@MainActor
final class UpdateService: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecks = true {
        didSet { controller.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }
    @Published var automaticallyDownloads = true {
        didSet { controller.updater.automaticallyDownloadsUpdates = automaticallyDownloads }
    }

    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
    private var observation: AnyCancellable?
    private var started = false

    init() {
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }

    func start() {
        guard !started else { return }
        #if DEBUG
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
              !ProcessInfo.processInfo.arguments.contains("--disable-updates") else { return }
        #endif
        started = true
        controller.startUpdater()
    }

    func checkForUpdates() {
        start()
        guard started else { return }
        controller.checkForUpdates(nil)
    }
}

struct SoftwareUpdateSettingsView: View {
    @ObservedObject var updates: UpdateService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Software Update", systemImage: "arrow.down.circle")
                .font(.title2.bold())
            Toggle("Automatically check for updates", isOn: $updates.automaticallyChecks)
            Toggle("Automatically download and install updates", isOn: $updates.automaticallyDownloads)
                .disabled(!updates.automaticallyChecks)
            Text("Updates are verified before installation. PetPaw will ask before restarting when needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    dismiss()
                    updates.checkForUpdates()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!updates.canCheckForUpdates)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}
