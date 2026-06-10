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

    // Selection / import progress
    @State private var isSelecting = false
    @State private var selected: Set<String> = []      // file ids
    @State private var importProgress: String?          // e.g. "Importing 2 of 5…"

    private var currentFolderID: String? { folderStack.last?.id ?? nil }
    private var currentFolderName: String { folderStack.last?.name ?? title }
    private var selectableFiles: [CloudFile] { files.filter { $0.isSupportedBook } }

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
                    List(files) { file in fileRow(file) }
                }
            }
            .navigationTitle(currentFolderName)
            .inlineNavigationTitle()
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) {
                if isSelecting { importBar }
            }
        }
        .task { load() }
        .overlay {
            if let importProgress {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(importProgress).foregroundStyle(.white)
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if folderStack.count > 1 {
                Button { folderStack.removeLast(); load() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            } else {
                Button("Cancel") { dismiss() }
            }
        }
        ToolbarItem(placement: .platformTrailing) {
            if !selectableFiles.isEmpty {
                Button(isSelecting ? "Done" : "Select") {
                    isSelecting.toggle()
                    if !isSelecting { selected.removeAll() }
                }
            }
        }
    }

    private var importBar: some View {
        HStack(spacing: 16) {
            Text("\(selected.count) selected").font(.subheadline.weight(.medium))
            Spacer()
            Button {
                selected = Set(selectableFiles.map(\.id))
            } label: { Text("All") }
            Button {
                importSelected()
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func fileRow(_ file: CloudFile) -> some View {
        Button {
            if isSelecting {
                if file.isSupportedBook { toggle(file) }
            } else if file.isFolder {
                folderStack.append((file.id, file.name)); load()
            } else if file.isSupportedBook {
                importSingle(file)
            }
        } label: {
            HStack(spacing: 12) {
                if isSelecting && file.isSupportedBook {
                    Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(file.id) ? Color.accentColor : .secondary)
                }
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
                if file.isFolder && !isSelecting {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                } else if !file.isSupportedBook && !file.isFolder {
                    Text("Unsupported").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSelecting ? !file.isSupportedBook : (!file.isSupportedBook && !file.isFolder))
    }

    private func toggle(_ file: CloudFile) {
        if selected.contains(file.id) { selected.remove(file.id) }
        else { selected.insert(file.id) }
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

    private func importSingle(_ file: CloudFile) {
        importProgress = "Importing…"
        Task {
            do {
                let url = try await service.download(file)
                await MainActor.run { onImport(url); importProgress = nil; dismiss() }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; importProgress = nil }
            }
        }
    }

    private func importSelected() {
        let toImport = selectableFiles.filter { selected.contains($0.id) }
        guard !toImport.isEmpty else { return }
        Task {
            var failures = 0
            for (index, file) in toImport.enumerated() {
                await MainActor.run { importProgress = "Importing \(index + 1) of \(toImport.count)…" }
                do {
                    let url = try await service.download(file)
                    await MainActor.run { onImport(url) }
                } catch {
                    failures += 1
                }
            }
            await MainActor.run {
                importProgress = nil
                if failures > 0 {
                    error = "\(failures) of \(toImport.count) file(s) failed to import."
                } else {
                    dismiss()
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
