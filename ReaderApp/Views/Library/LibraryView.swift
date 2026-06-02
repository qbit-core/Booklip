import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @EnvironmentObject private var settings: ReadingSettings
    @State private var showingFilePicker = false
    @State private var searchText = ""

    private var filteredBooks: [Book] {
        guard !searchText.isEmpty else { return library.books }
        return library.books.filter {
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
                    bookGrid
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
