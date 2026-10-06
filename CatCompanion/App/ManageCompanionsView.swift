import SwiftUI

struct ManageCompanionsView: View {
    @ObservedObject var coordinator: CompanionCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var petToRemove: CompanionPackage?
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("Manage Pets", systemImage: "pawprint")
                    .font(.title2.weight(.medium))
                Spacer()
                Text("\(coordinator.companions.count) saved")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Choose the pet to keep you company, or add another to your collection.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if coordinator.companions.isEmpty {
                    ContentUnavailableView("No saved pets", systemImage: "pawprint",
                        description: Text("Import a companion ZIP or folder to start your collection."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(coordinator.companions, id: \.root) { package in
                                petRow(package)
                            }
                        }
                        .padding(2)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 320)

            if let error = coordinator.petManagementError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button { coordinator.showingImport = true } label: {
                    Label("Import pet…", systemImage: "square.and.arrow.down")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .disabled(coordinator.isImporting)
        }
        .padding(28).frame(width: 620)
        .interactiveDismissDisabled(coordinator.isImporting)
        .sheet(isPresented: $coordinator.showingImport) {
            ImportCompanionView(coordinator: coordinator)
        }
        .alert("Remove pet?", isPresented: $confirmingRemoval, presenting: petToRemove) { package in
            Button("Cancel", role: .cancel) { petToRemove = nil }
            Button("Remove", role: .destructive) {
                coordinator.removeCompanion(package)
                petToRemove = nil
            }
        } message: { package in
            Text("Remove \(package.manifest.name) from your saved pets? You can import this pet again from its original ZIP or folder." +
                 (coordinator.character.package?.root == package.root
                  ? "\n\nThis ends the current conversation and selects another available pet. If none are available, the desktop pet will be hidden."
                  : ""))
        }
        .overlay(alignment: .top) {
            if let notice = coordinator.petNotice {
                CompanionNoticeView(message: notice)
            }
        }
    }

    private func petRow(_ package: CompanionPackage) -> some View {
        let isActive = coordinator.character.package?.root == package.root
        return HStack(spacing: 14) {
            Image(systemName: "pawprint.fill")
                .font(.title2).foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(package.manifest.name).font(.headline)
                if !package.personality.description.isEmpty {
                    Text(package.personality.description)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.secondary).fixedSize()
            } else {
                Button { coordinator.selectCompanion(package) } label: {
                    Label("Use pet", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityLabel("Switch to \(package.manifest.name)")
                .fixedSize()
            }
            Button(role: .destructive) {
                petToRemove = package
                confirmingRemoval = true
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .accessibilityLabel("Remove \(package.manifest.name)")
            .fixedSize()
        }
        .buttonStyle(.bordered)
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: 1)
        }
        .disabled(coordinator.isImporting)
    }
}
