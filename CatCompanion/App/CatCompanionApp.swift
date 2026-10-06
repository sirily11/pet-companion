import SwiftUI

@main
struct CatCompanionApp: App {
    @StateObject private var coordinator = CompanionCoordinator()
    @StateObject private var updates = UpdateService()
    @State private var showingUpdateSettings = false
    var body: some Scene {
        WindowGroup("PetPaw") {
            ContentView(coordinator: coordinator)
                .frame(minWidth: 940, minHeight: 660)
                .onDisappear { coordinator.disconnect() }
                .onAppear { updates.start() }
                .sheet(isPresented: $showingUpdateSettings) {
                    SoftwareUpdateSettingsView(updates: updates)
                }
        }
        .defaultSize(width: 1180, height: 800)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button {
                    updates.checkForUpdates()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!updates.canCheckForUpdates)
                Button {
                    showingUpdateSettings = true
                } label: {
                    Label("Software Update…", systemImage: "arrow.down.circle")
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { coordinator.showingSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button { coordinator.showingImport = true } label: {
                    Label("Import pet companion…", systemImage: "square.and.arrow.down")
                }.keyboardShortcut("i", modifiers: .command).disabled(coordinator.isImporting)
            }
            CommandMenu("Character") {
                ForEach(coordinator.character.poses) { pose in
                    Button(pose.title) { coordinator.character.setPose(pose) }
                }
                Divider()
                Button("Reset Camera") { coordinator.character.resetCamera() }
                Button("Stop Voice") { coordinator.disconnect() }
            }
        }
    }
}
