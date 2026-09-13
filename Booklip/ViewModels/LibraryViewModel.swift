import SwiftUI
import Combine
import PDFKit

class LibraryViewModel: ObservableObject {
    @Published var books: [Book] = []
    @Published var folders: [BookFolder] = []
    @Published var sortOption: SortOption = .dateAdded
    @Published var importError: String?
    @Published var showingImportError = false

    // View mode (persisted)
    @Published var viewMode: ViewMode = .mediumGrid {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }

    // Multi-select state
    @Published var isSelecting = false
    @Published var selectedBookIDs: Set<UUID> = []
    @Published var isImporting = false

    // Book currently open in the reader (presented as a full-screen cover)
    @Published var openBook: Book?

    init() {
        books = BookStore.load()
        folders = BookStore.loadFolders()
        if let raw = UserDefaults.standard.string(forKey: "viewMode"),
           let mode = ViewMode(rawValue: raw) {
            viewMode = mode
        }
        migrateUUIDTitles()
        syncFromCloud()
        ProgressSync.startObserving { [weak self] in self?.syncFromCloud() }
    }

    // MARK: - iCloud progress sync

    func syncFromCloud() {
        var changed = false
        for i in books.indices {
            if let cloud = ProgressSync.newerProgress(for: books[i],
                                                      localUpdated: books[i].progressUpdated ?? .distantPast) {
                books[i].progress = cloud
                books[i].progressUpdated = Date()
                changed = true
            }
        }
        if changed { BookStore.save(books) }
    }

    // MARK: - Selection

    func toggleSelection(_ id: UUID) {
        if selectedBookIDs.contains(id) { selectedBookIDs.remove(id) }
        else { selectedBookIDs.insert(id) }
    }

    func setSelecting(_ on: Bool) {
        isSelecting = on
        if !on { selectedBookIDs.removeAll() }
    }

    func setSelected(_ id: UUID, _ on: Bool) {
        if on { selectedBookIDs.insert(id) } else { selectedBookIDs.remove(id) }
    }

    /// Select-all toggle over the books currently on screen: selects them all,
    /// or clears the selection when every one of them is already selected.
    func toggleSelectAll(_ visible: [Book]) {
        let ids = Set(visible.map(\.id))
        if !ids.isEmpty && ids.isSubset(of: selectedBookIDs) {
            selectedBookIDs.subtract(ids)
        } else {
            selectedBookIDs.formUnion(ids)
        }
    }

    func allSelected(_ visible: [Book]) -> Bool {
        !visible.isEmpty && visible.allSatisfy { selectedBookIDs.contains($0.id) }
    }

    /// Books shown on the All Books tab for a search string.
    func filteredBooks(search: String) -> [Book] {
        filter(sorted(books), search: search)
    }

    /// Title/author match; an empty query keeps everything.
    func filter(_ list: [Book], search: String) -> [Book] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.author.localizedCaseInsensitiveContains(q)
        }
    }

    /// Folders to show for a query: name matches, or the folder holds a
    /// matching book.
    func filteredFolders(search: String) -> [BookFolder] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return folders }
        return folders.filter { f in
            f.name.localizedCaseInsensitiveContains(q) || !filter(books(in: f), search: q).isEmpty
        }
    }

    func moveSelected(to folder: BookFolder?) {
        for i in books.indices where selectedBookIDs.contains(books[i].id) {
            books[i].folderID = folder?.id
        }
        BookStore.save(books)
        setSelecting(false)
    }

    func deleteSelected() {
        let ids = selectedBookIDs
        ids.forEach { id in
            if let book = books.first(where: { $0.id == id }) { BookStore.delete(book: book) }
        }
        books.removeAll { ids.contains($0.id) }
        BookStore.save(books)
        setSelecting(false)
    }

    // MARK: - Sorting

    func sorted(_ list: [Book]) -> [Book] {
        switch sortOption {
        case .dateAdded: return list.sorted { $0.dateAdded > $1.dateAdded }
        case .title:     return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .author:    return list.sorted { $0.author.localizedCaseInsensitiveCompare($1.author) == .orderedAscending }
        case .progress:  return list.sorted { $0.progress > $1.progress }
        case .format:    return list.sorted { $0.format.displayName < $1.format.displayName }
        }
    }

    // MARK: - Folder queries

    func books(in folder: BookFolder) -> [Book] {
        sorted(books.filter { $0.folderID == folder.id })
    }

    var unfolderedBooks: [Book] {
        sorted(books.filter { $0.folderID == nil })
    }

    // MARK: - Folder management

    func createFolder(named name: String) {
        let folder = BookFolder(name: name)
        folders.append(folder)
        BookStore.saveFolders(folders)
    }

    func renameFolder(_ folder: BookFolder, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[i].name = name
        BookStore.saveFolders(folders)
    }

    func deleteFolder(_ folder: BookFolder) {
        // Move books in this folder back to unfoldered
        for i in books.indices where books[i].folderID == folder.id {
            books[i].folderID = nil
        }
        folders.removeAll { $0.id == folder.id }
        BookStore.save(books)
        BookStore.saveFolders(folders)
    }

    func moveBook(_ book: Book, to folder: BookFolder?) {
        guard let i = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[i].folderID = folder?.id
        BookStore.save(books)
    }

    /// The folder called `name` (case-insensitive), created on first use — a
    /// cloud folder imported twice lands in the same library folder.
    func folder(named name: String) -> BookFolder {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let existing = folders.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        let folder = BookFolder(name: trimmed.isEmpty ? "Untitled" : trimmed)
        folders.append(folder)
        BookStore.saveFolders(folders)
        return folder
    }

    // MARK: - Import

    /// Cloud import entry point: `folderName` nil files the book as unfiled.
    func importBook(from url: URL, intoFolderNamed folderName: String?) {
        importBook(from: url, into: folderName.map { folder(named: $0) })
    }

    func importBook(from url: URL, into folder: BookFolder? = nil) {
        isImporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let format = BookFormat.from(url: url) else {
                    throw ImportError.unsupportedFormat(url.pathExtension)
                }
                let originalName = url.deletingPathExtension().lastPathComponent
                let fileName = try BookStore.importFile(from: url)
                // Cloud downloads land in our temp directory; the copy above
                // is the keeper, so drop the original instead of letting
                // multi-MB files pile up in tmp.
                if url.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                let fileURL = BookStore.documentsDirectory.appendingPathComponent(fileName)
                let parsed = try ParserFactory.parse(url: fileURL, format: format)
                let fileNameStem = (fileName as NSString).deletingPathExtension
                let title = parsed.title.isEmpty || parsed.title == fileNameStem ? originalName : parsed.title
                var book = Book(title: title, author: parsed.author, format: format, fileName: fileName)
                book.wordCount = parsed.wordCount
                book.folderID = folder?.id
                if let cover = parsed.coverImage {
                    book.coverFileName = BookStore.saveCover(cover, for: fileName)
                }
                DispatchQueue.main.async {
                    self.books.append(book)
                    BookStore.save(self.books)
                    self.isImporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.importError = error.localizedDescription
                    self.showingImportError = true
                    self.isImporting = false
                }
            }
        }
    }

    func delete(book: Book) {
        BookStore.delete(book: book)
        books.removeAll { $0.id == book.id }
        BookStore.save(books)
    }

    func delete(at offsets: IndexSet, in list: [Book]) {
        let ids = offsets.map { list[$0].id }
        ids.forEach { id in
            if let book = books.first(where: { $0.id == id }) { BookStore.delete(book: book) }
        }
        books.removeAll { ids.contains($0.id) }
        BookStore.save(books)
    }

    /// `charIndex` nil = "not known" (PDF, or text not loaded yet) → keep the
    /// stored value. A non-nil 0 is a real position (start of the book) and IS
    /// stored — treating 0 as "missing" left a stale index that won on reopen.
    func updateProgress(for bookID: UUID, progress: Double, charIndex: Int? = nil) {
        guard let i = books.firstIndex(where: { $0.id == bookID }) else { return }
        books[i].progress = progress
        books[i].progressUpdated = Date()
        if let charIndex { books[i].charIndex = charIndex }
        BookStore.save(books)
        ProgressSync.push(books[i])
    }

    // MARK: - Migration

    private func migrateUUIDTitles() {
        // Run only once — opening PDFDocument for every PDF on every launch is slow.
        let key = "uuidTitleMigrationDone"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var changed = false
        for i in books.indices where looksLikeUUID(books[i].title) {
            if books[i].format == .pdf,
               let doc = PDFDocument(url: books[i].fileURL),
               let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
               !title.isEmpty {
                books[i].title = title
                changed = true
            }
        }
        if changed { BookStore.save(books) }
        UserDefaults.standard.set(true, forKey: key)
    }

    private func looksLikeUUID(_ string: String) -> Bool { UUID(uuidString: string) != nil }
}

enum ImportError: LocalizedError {
    case unsupportedFormat(String)
    var errorDescription: String? {
        if case .unsupportedFormat(let ext) = self {
            return "Unsupported file format: .\(ext). Supported formats: .txt, .epub, .pdf, .md"
        }
        return nil
    }
}
