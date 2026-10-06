import SwiftUI
import UniformTypeIdentifiers

struct ImportCompanionView: View {
    @ObservedObject var coordinator: CompanionCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFile = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Import pet companion", systemImage: "square.and.arrow.down")
                .font(.title2.weight(.medium))
            Text("Choose a companion ZIP or folder containing its personality, poses, and 3D models.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Your pet will be added to your saved pets and selected. Switch between them from the Pets menu.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let package = coordinator.character.package {
                Label("Current companion: \(package.manifest.name)", systemImage: "pawprint")
                    .font(.callout)
            }
            if let error = coordinator.importError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if coordinator.isImporting {
                ProgressView("Importing companion…").controlSize(.small)
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(coordinator.isImporting)
                Spacer()
                Button { choosingFile = true } label: {
                    Label("Choose ZIP or folder…", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(coordinator.isImporting)
            }
        }
        .padding(28).frame(width: 480)
        .interactiveDismissDisabled(coordinator.isImporting)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.zip, .folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        if await coordinator.importCompanion(from: url) { dismiss() }
                    }
                }
            case .failure(let error): coordinator.importError = error.localizedDescription
            }
        }
    }
}
