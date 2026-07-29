import SwiftUI
import UniformTypeIdentifiers

// feature 4: filter books by reading status
enum LibraryFilter: String, CaseIterable {
    case all = "All"
    case reading = "Reading"
    case read = "Read"
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var settings: ReadingSettings
    @State private var showingFilePicker = false
    @State private var searchText = ""
    @State private var filter: LibraryFilter = .all

    private var filteredBooks: [Book] {
        let base: [Book]
        switch filter {
        case .all:
            base = library.books
        case .reading:
            // books that have been started but not finished
            base = library.books.filter { $0.progress > 0 && !$0.isFinished }
        case .read:
            // feature 4: finished books (progress ≥ 99%)
            base = library.books.filter { $0.isFinished }
        }
        guard !searchText.isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.author.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 0) {
                        Picker("Filter", selection: $filter) {
                            ForEach(LibraryFilter.allCases, id: \.self) { f in
                                Text(f.rawValue).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.top, 8)

                        if filteredBooks.isEmpty {
                            Spacer()
                            Text(filter == .read ? "No finished books yet" : "No books in progress")
                                .foregroundStyle(.secondary)
                                .padding()
                            Spacer()
                        } else {
                            bookGrid
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .platformTrailing) {
                    Button { showingFilePicker = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search books")
            .fileImporter(
                isPresented: $showingFilePicker,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    urls.forEach { library.importBook(from: $0) }
                }
            }
            .alert("Import Error", isPresented: $library.showingImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(library.importError ?? "")
            }
        }
        // feature 3: apply color scheme to whole navigation stack
        .preferredColorScheme(settings.preferredColorScheme)
    }

    private var bookGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                ForEach(filteredBooks) { book in
                    NavigationLink(destination: ReaderView(book: book)) {
                        BookCard(book: book)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            if let index = library.books.firstIndex(where: { $0.id == book.id }) {
                                library.delete(at: IndexSet(integer: index))
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "books.vertical")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)
            Text("No Books Yet")
                .font(.title2.bold())
            Text("Tap + to import .txt, .epub, .pdf, or .md files\nfrom Files, iCloud Drive, OneDrive, or Google Drive.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Import Book") { showingFilePicker = true }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
