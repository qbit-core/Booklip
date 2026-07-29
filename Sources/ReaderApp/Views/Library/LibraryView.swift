import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var settings: ReadingSettings
    @State private var showingFilePicker = false
    @State private var showingCloudConnect = false
    @State private var showingStats = false
    @State private var searchText = ""
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var selectedTab: LibraryTab = .all

    enum LibraryTab: Hashable { case all, folders }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $selectedTab) {
                    Text("All Books").tag(LibraryTab.all)
                    Text("Folders").tag(LibraryTab.folders)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .disabled(library.isSelecting)

                if selectedTab == .all {
                    AllBooksView(showingFilePicker: $showingFilePicker, searchText: $searchText)
                } else {
                    FoldersView(showingFilePicker: $showingFilePicker)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if library.isSelecting { SelectionBar() }
            }
            .navigationTitle("Library")
            .toolbar { toolbarContent }
            .searchable(text: $searchText, prompt: "Search books")
            .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { urls.forEach { library.importBook(from: $0) } }
            }
            .alert("Import Error", isPresented: $library.showingImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.importError ?? "")
            }
            .sheet(isPresented: $showingCloudConnect) {
                CloudConnectView { url in library.importBook(from: url) }
            }
            .sheet(isPresented: $showingStats) { StatsView() }
            .readerCover(item: $library.openBook) { book in
                ReaderView(book: book)
#if os(macOS)
                // The standalone window breaks the SwiftUI environment chain;
                // re-inject the app-level objects so ReaderView can find them.
                    .environmentObject(library)
                    .environmentObject(settings)
#endif
            }
            .alert("New Folder", isPresented: $showingNewFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") {
                    let name = newFolderName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { library.createFolder(named: name) }
                    newFolderName = ""
                }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .platformTrailing) {
            if library.isSelecting {
                Button("Done") { library.setSelecting(false) }
            } else {
                HStack(spacing: 12) {
                    ViewModeMenu()
                    SortMenu()

                    Button { showingStats = true } label: {
                        Image(systemName: "chart.bar")
                    }

                    // Select
                    Button { library.setSelecting(true) } label: {
                        Image(systemName: "checkmark.circle")
                    }

                    if selectedTab == .folders {
                        Button { showingNewFolder = true } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                    }

                    // Add
                    Menu {
                        Button { showingFilePicker = true } label: {
                            Label("Browse Files", systemImage: "folder")
                        }
                        Button { showingCloudConnect = true } label: {
                            Label("Cloud Storage…", systemImage: "cloud")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

}

// MARK: - Selection action bar (shared)

struct SelectionBar: View {
    @EnvironmentObject private var library: LibraryViewModel

    var body: some View {
        HStack(spacing: 16) {
            Text("\(library.selectedBookIDs.count) selected")
                .font(.subheadline.weight(.medium))
            Spacer()
            Menu {
                Button("No Folder") { library.moveSelected(to: nil) }
                if !library.folders.isEmpty { Divider() }
                ForEach(library.folders) { folder in
                    Button(folder.name) { library.moveSelected(to: folder) }
                }
            } label: {
                Label("Move", systemImage: "folder")
            }
            .disabled(library.selectedBookIDs.isEmpty)

            Button(role: .destructive) { library.deleteSelected() } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(library.selectedBookIDs.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Reusable selection toolbar + bar (for folder detail / unfiled)

struct BookSelectionModifier: ViewModifier {
    @EnvironmentObject private var library: LibraryViewModel

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if library.isSelecting { SelectionBar() }
            }
            .toolbar {
                ToolbarItem(placement: .platformTrailing) {
                    if library.isSelecting {
                        Button("Done") { library.setSelecting(false) }
                    } else {
                        HStack(spacing: 12) {
                            ViewModeMenu()
                            SortMenu()
                            Button { library.setSelecting(true) } label: {
                                Image(systemName: "checkmark.circle")
                            }
                        }
                    }
                }
            }
    }
}

extension View {
    func bookSelection() -> some View { modifier(BookSelectionModifier()) }
}

// MARK: - Reusable view-mode & sort menus

struct ViewModeMenu: View {
    @EnvironmentObject private var library: LibraryViewModel
    var body: some View {
        Menu {
            ForEach(ViewMode.allCases) { mode in
                Button {
                    library.viewMode = mode
                } label: {
                    Label(mode.rawValue, systemImage: library.viewMode == mode ? "checkmark" : mode.icon)
                }
            }
        } label: {
            Image(systemName: library.viewMode.icon)
        }
    }
}

struct SortMenu: View {
    @EnvironmentObject private var library: LibraryViewModel
    var body: some View {
        Menu {
            ForEach(SortOption.allCases) { option in
                Button {
                    library.sortOption = option
                } label: {
                    if library.sortOption == option {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }
}

// MARK: - Shared books collection (grid or list, with selection)

struct BooksCollection: View {
    @EnvironmentObject private var library: LibraryViewModel
    let books: [Book]

    var body: some View {
        ScrollView {
            if let minWidth = library.viewMode.minCellWidth {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 16)], spacing: 16) {
                    ForEach(books) { BookCardLink(book: $0) }
                }
                .padding()
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(books) { BookCardLink(book: $0) }
                }
                .padding()
            }
        }
    }
}

// MARK: - All Books

private struct AllBooksView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @Binding var showingFilePicker: Bool
    @Binding var searchText: String

    private var filtered: [Book] {
        let base = library.sorted(library.books)
        guard !searchText.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.author.localizedCaseInsensitiveContains(searchText) ||
            $0.contentSnippet.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        if filtered.isEmpty {
            VStack(spacing: 20) {
                Image(systemName: "books.vertical").font(.system(size: 60)).foregroundStyle(.tertiary)
                Text("No Books Yet").font(.title2.bold())
                Text("Tap + to import .txt, .epub, .pdf, or .md files.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Import Book") { showingFilePicker = true }.buttonStyle(.borderedProminent)
            }
            .padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            BooksCollection(books: filtered)
        }
    }
}

// MARK: - Folders

private struct FoldersView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @Binding var showingFilePicker: Bool
    @State private var folderToRename: BookFolder?
    @State private var renameText = ""

    var body: some View {
        ScrollView {
            if let minWidth = library.viewMode.minCellWidth {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 16)], spacing: 16) {
                    folderItems(asRow: false)
                }
                .padding()
            } else {
                LazyVStack(spacing: 8) {
                    folderItems(asRow: true)
                }
                .padding()
            }
        }
        .overlay {
            if library.folders.isEmpty && library.unfolderedBooks.isEmpty {
                ContentUnavailableView("No Folders", systemImage: "folder",
                    description: Text("Tap the folder+ button to create one."))
            }
        }
        .alert("Rename Folder", isPresented: Binding(
            get: { folderToRename != nil },
            set: { if !$0 { folderToRename = nil } }
        )) {
            TextField("Folder name", text: $renameText)
            Button("Rename") {
                if let f = folderToRename {
                    library.renameFolder(f, to: renameText.trimmingCharacters(in: .whitespaces))
                }
                folderToRename = nil
            }
            Button("Cancel", role: .cancel) { folderToRename = nil }
        }
    }

    @ViewBuilder
    private func folderItems(asRow: Bool) -> some View {
        ForEach(library.folders) { folder in
            NavigationLink(destination: FolderDetailView(folder: folder)) {
                if asRow {
                    FolderRow(name: folder.name, count: library.books(in: folder).count, icon: "folder.fill")
                } else {
                    FolderCard(folder: folder, count: library.books(in: folder).count)
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button { folderToRename = folder; renameText = folder.name } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) { library.deleteFolder(folder) } label: {
                    Label("Delete Folder", systemImage: "trash")
                }
            }
        }

        if !library.unfolderedBooks.isEmpty {
            NavigationLink(destination: UnfiledBooksView()) {
                if asRow {
                    FolderRow(name: "Unfiled", count: library.unfolderedBooks.count, icon: "tray")
                } else {
                    FolderCard(folder: BookFolder(name: "Unfiled"),
                               count: library.unfolderedBooks.count, systemIcon: "tray")
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Folder Detail

struct FolderDetailView: View {
    @EnvironmentObject private var library: LibraryViewModel
    let folder: BookFolder

    var body: some View {
        Group {
            if library.books(in: folder).isEmpty {
                ContentUnavailableView("No Books", systemImage: "folder",
                    description: Text("Select books and choose Move to put them here."))
            } else {
                BooksCollection(books: library.books(in: folder))
            }
        }
        .navigationTitle(folder.name)
        .bookSelection()
    }
}

struct UnfiledBooksView: View {
    @EnvironmentObject private var library: LibraryViewModel
    var body: some View {
        BooksCollection(books: library.unfolderedBooks)
            .navigationTitle("Unfiled")
            .bookSelection()
    }
}

// MARK: - BookCardLink (card/row + selection)

struct BookCardLink: View {
    @EnvironmentObject private var library: LibraryViewModel
    let book: Book

    private var isSelected: Bool { library.selectedBookIDs.contains(book.id) }
    private var isList: Bool { library.viewMode == .list }

    var body: some View {
        Button {
            if library.isSelecting {
                library.toggleSelection(book.id)
            } else {
                library.openBook = book   // opens as a full-screen cover
            }
        } label: {
            cell
        }
        .buttonStyle(.plain)
        .contextMenu { if !library.isSelecting { contextMenu } }
    }

    @ViewBuilder private var cell: some View {
        Group {
            if isList {
                BookRow(book: book)
            } else {
                BookCard(book: book)
            }
        }
        .overlay(alignment: .topLeading) {
            if library.isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .padding(6)
                    .background(.ultraThinMaterial, in: Circle())
                    .padding(6)
            }
        }
    }

    @ViewBuilder private var contextMenu: some View {
        Menu {
            Button("No Folder") { library.moveBook(book, to: nil) }
            if !library.folders.isEmpty { Divider() }
            ForEach(library.folders) { folder in
                Button(folder.name) { library.moveBook(book, to: folder) }
            }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }
        Button(role: .destructive) { library.delete(book: book) } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

// MARK: - List row

private struct BookRow: View {
    let book: Book

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let cover = BookCover.image(for: book) {
                    cover.resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(coverColor)
                        .overlay(Text(book.format.displayName.prefix(1))
                            .font(.caption.bold()).foregroundStyle(.white))
                }
            }
            .frame(width: 40, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if book.progress > 0 {
                    ProgressView(value: book.progress).tint(.accentColor)
                }
            }
            Spacer()
            Text("\(Int(book.progress * 100))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var coverColor: Color {
        let colors: [Color] = [.indigo, .teal, .orange, .pink, .purple, .green, .blue]
        return colors[abs(book.title.hashValue) % colors.count]
    }
}

// MARK: - FolderCard

private struct FolderRow: View {
    let name: String
    let count: Int
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(count) book\(count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct FolderCard: View {
    let folder: BookFolder
    let count: Int
    var systemIcon: String = "folder.fill"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemIcon)
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            Text(folder.name)
                .font(.headline)
                .lineLimit(2)
            Text("\(count) book\(count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(height: 140)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
