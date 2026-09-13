import SwiftUI

// Generic file browser used by Dropbox, OneDrive and Google Drive.
//
// Select mode: files AND folders can be picked (tap, or sweep with a drag),
// "All" toggles everything. Importing a folder creates a library folder of the
// same name and puts every supported book found in it (subfolders included)
// there; loose files land unfiled, as before.
struct CloudFileBrowserView: View {
    let title: String
    let service: CloudBrowserService
    /// (temp file URL, library folder name or nil for unfiled)
    let onImport: (URL, String?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var files: [CloudFile] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var folderStack: [(id: String?, name: String)] = [(nil, "Root")]

    // Selection / import progress
    @State private var isSelecting = false
    @State private var selected: Set<String> = []      // file + folder ids
    @State private var importProgress: String?          // e.g. "Importing 2 of 5…"

    private var currentFolderID: String? { folderStack.last?.id ?? nil }
    private var currentFolderName: String { folderStack.last?.name ?? title }
    private var selectableFiles: [CloudFile] { files.filter { $0.isSupportedBook || $0.isFolder } }
    private var allSelected: Bool {
        !selectableFiles.isEmpty && selectableFiles.allSatisfy { selected.contains($0.id) }
    }

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
                    // A ScrollView rather than List: UITableView swallows the
                    // horizontal pan that drives sweep selection.
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(files) { file in
                                fileRow(file).dragSelectItem(file.id)
                                if file.id != files.last?.id {
                                    Divider().padding(.leading, isSelecting ? 84 : 56)
                                }
                            }
                        }
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .padding()
                    }
                    .dragSelection(enabled: isSelecting,
                                   isSelected: { (id: String) in selected.contains(id) },
                                   setSelected: { (id: String, on: Bool) in
                                       if on { selected.insert(id) } else { selected.remove(id) }
                                   })
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
                .disabled(isSelecting)
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
            Button(allSelected ? "None" : "All") {
                if allSelected { selected.removeAll() }
                else { selected = Set(selectableFiles.map(\.id)) }
            }
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
        let selectable = file.isSupportedBook || file.isFolder
        return Button {
            if isSelecting {
                if selectable { toggle(file) }
            } else if file.isFolder {
                folderStack.append((file.id, file.name)); load()
            } else if file.isSupportedBook {
                importSingle(file)
            }
        } label: {
            HStack(spacing: 12) {
                if isSelecting && selectable {
                    Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected.contains(file.id) ? Color.accentColor : .secondary)
                }
                Image(systemName: file.formatIcon)
                    .foregroundStyle(file.isFolder ? .yellow : .accentColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .foregroundStyle(selectable ? .primary : .secondary)
                        .lineLimit(2)
                    if let size = file.size, !file.isFolder {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    } else if file.isFolder && isSelecting {
                        Text("Import as a folder").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if file.isFolder && !isSelecting {
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.caption)
                } else if !selectable {
                    Text("Unsupported").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
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
                let url = try await service.download(file, folderName: nil)
                await MainActor.run { onImport(url, nil); importProgress = nil; dismiss() }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; importProgress = nil }
            }
        }
    }

    /// One download job: a book and the library folder it should land in.
    private struct Job { let file: CloudFile; let folderName: String? }

    private func importSelected() {
        let picked = selectableFiles.filter { selected.contains($0.id) }
        guard !picked.isEmpty else { return }
        importProgress = "Preparing…"
        Task {
            // Expand folders first so the count in the progress text is final.
            var jobs: [Job] = []
            var listingFailures = 0
            for item in picked {
                if item.isFolder {
                    do {
                        let books = try await collectBooks(in: item)
                        jobs += books.map { Job(file: $0, folderName: item.name) }
                    } catch {
                        listingFailures += 1
                    }
                } else {
                    jobs.append(Job(file: item, folderName: nil))
                }
            }

            var failures = 0
            for (index, job) in jobs.enumerated() {
                await MainActor.run { importProgress = "Importing \(index + 1) of \(jobs.count)…" }
                do {
                    let url = try await service.download(job.file, folderName: job.folderName)
                    await MainActor.run { onImport(url, job.folderName) }
                } catch {
                    failures += 1
                }
            }
            await MainActor.run {
                importProgress = nil
                if failures > 0 || listingFailures > 0 {
                    var parts: [String] = []
                    if failures > 0 { parts.append("\(failures) of \(jobs.count) file(s) failed to import.") }
                    if listingFailures > 0 { parts.append("\(listingFailures) folder(s) could not be read.") }
                    error = parts.joined(separator: " ")
                } else if jobs.isEmpty {
                    error = "The selected folder(s) contain no supported books."
                } else {
                    dismiss()
                }
            }
        }
    }

    /// Every supported book inside `folder`, subfolders included (depth-first,
    /// capped so a pathological tree can't run forever).
    private func collectBooks(in folder: CloudFile, depth: Int = 0) async throws -> [CloudFile] {
        guard depth < 8 else { return [] }
        var result: [CloudFile] = []
        let entries = try await service.files(folderID: folder.id)
        for entry in entries.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            if entry.isFolder {
                result += try await collectBooks(in: entry, depth: depth + 1)
            } else if entry.isSupportedBook {
                result.append(entry)
            }
        }
        return result
    }
}

// Protocol so all services share one browser view
protocol CloudBrowserService {
    func files(folderID: String?) async throws -> [CloudFile]
    /// `folderName` is recorded with the transfer so a download finished after
    /// an app relaunch can still be filed into the right library folder.
    func download(_ file: CloudFile, folderName: String?) async throws -> URL
}

extension OneDriveService: CloudBrowserService {}
extension DropboxService: CloudBrowserService {}
extension GoogleDriveService: CloudBrowserService {
    func files(folderID: String?) async throws -> [CloudFile] {
        try await files(folderID: folderID ?? "root")
    }
}
