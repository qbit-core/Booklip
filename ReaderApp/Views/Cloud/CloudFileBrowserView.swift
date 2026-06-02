import SwiftUI

// Generic file browser used by both OneDrive and Google Drive.
struct CloudFileBrowserView: View {
    let title: String
    let service: CloudBrowserService
    let onImport: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var files: [CloudFile] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var folderStack: [(id: String?, name: String)] = [(nil, "Root")]
    @State private var importingFile: CloudFile?

    private var currentFolderID: String? { folderStack.last?.id ?? nil }
    private var currentFolderName: String { folderStack.last?.name ?? title }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView("Error", systemImage: "exclamationmark.triangle",
                        description: Text(error))
                } else if files.isEmpty {
                    ContentUnavailableView("No Supported Files", systemImage: "doc.questionmark",
                        description: Text("This folder has no .txt, .epub, .pdf, or .md files."))
                } else {
                    List(files) { file in
                        fileRow(file)
                    }
                }
            }
            .navigationTitle(currentFolderName)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if folderStack.count > 1 {
                        Button { folderStack.removeLast(); load() } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .task { load() }
        .overlay {
            if importingFile != nil {
                ZStack {
                    Color.black.opacity(0.3).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Importing…").foregroundStyle(.white)
                    }
                }
            }
        }
    }

    private func fileRow(_ file: CloudFile) -> some View {
        Button {
            if file.isFolder {
                folderStack.append((file.id, file.name))
                load()
            } else if file.isSupportedBook {
                importFile(file)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: file.formatIcon)
                    .foregroundStyle(file.isFolder ? .yellow : .accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .foregroundStyle(file.isSupportedBook || file.isFolder ? .primary : .secondary)
                        .lineLimit(2)
                    if let size = file.size, !file.isFolder {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if file.isFolder {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                } else if !file.isSupportedBook {
                    Text("Unsupported").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!file.isSupportedBook && !file.isFolder)
    }

    private func load() {
        isLoading = true
        error = nil
        files = []
        Task {
            do {
                files = try await service.files(folderID: currentFolderID)
                    .sorted { f1, f2 in
                        if f1.isFolder != f2.isFolder { return f1.isFolder }
                        return f1.name.localizedCaseInsensitiveCompare(f2.name) == .orderedAscending
                    }
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    private func importFile(_ file: CloudFile) {
        importingFile = file
        Task {
            do {
                let url = try await service.download(file)
                await MainActor.run {
                    onImport(url)
                    importingFile = nil
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    importingFile = nil
                }
            }
        }
    }
}

// Protocol so both services share one browser view
protocol CloudBrowserService {
    func files(folderID: String?) async throws -> [CloudFile]
    func download(_ file: CloudFile) async throws -> URL
}

extension OneDriveService: CloudBrowserService {}
extension GoogleDriveService: CloudBrowserService {
    func files(folderID: String?) async throws -> [CloudFile] {
        try await files(folderID: folderID ?? "root")
    }
}
