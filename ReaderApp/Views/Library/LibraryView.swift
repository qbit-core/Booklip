import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var settings: ReadingSettings
    @State private var showingFilePicker = false
    @State private var showingURLImport = false
    @State private var showingCloudConnect = false
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

                if selectedTab == .all {
                    AllBooksView(showingFilePicker: $showingFilePicker, searchText: $searchText)
                } else {
                    FoldersView(showingFilePicker: $showingFilePicker)
                }
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .platformTrailing) {
            HStack(spacing: 12) {
                Menu {
                    ForEach(SortOption.allCases) { option in
                        Button {
                            library.sortOption = option
                        } label: {
                            Label(option.rawValue,
                                  systemImage: library.sortOption == option ? "checkmark" : "")
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }

                if selectedTab == .folders {
                    Button { showingNewFolder = true } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }

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
            $0.author.localizedCaseInsensitiveContains(searchText)
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
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                    ForEach(filtered) { book in BookCardLink(book: book) }
                }
                .padding()
            }
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                ForEach(library.folders) { folder in
                    NavigationLink(destination: FolderDetailView(folder: folder)) {
                        FolderCard(folder: folder, count: library.books(in: folder).count)
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
                        FolderCard(folder: BookFolder(name: "Unfiled"),
                                   count: library.unfolderedBooks.count,
                                   systemIcon: "tray")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
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
}

// MARK: - Folder Detail

struct FolderDetailView: View {
    @EnvironmentObject private var library: LibraryViewModel
    let folder: BookFolder

    var body: some View {
        Group {
            if library.books(in: folder).isEmpty {
                ContentUnavailableView("No Books", systemImage: "folder",
                    description: Text("Right-click a book and choose Move to Folder."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                        ForEach(library.books(in: folder)) { book in BookCardLink(book: book) }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(folder.name)
    }
}

struct UnfiledBooksView: View {
    @EnvironmentObject private var library: LibraryViewModel
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                ForEach(library.unfolderedBooks) { book in BookCardLink(book: book) }
            }
            .padding()
        }
        .navigationTitle("Unfiled")
    }
}

// MARK: - BookCardLink

struct BookCardLink: View {
    @EnvironmentObject private var library: LibraryViewModel
    let book: Book

    var body: some View {
        NavigationLink(destination: ReaderView(book: book)) {
            BookCard(book: book)
        }
        .buttonStyle(.plain)
        .contextMenu {
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
}

// MARK: - FolderCard

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
