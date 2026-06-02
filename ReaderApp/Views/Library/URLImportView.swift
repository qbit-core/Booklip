import SwiftUI

struct URLImportView: View {
    let onImport: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $urlText)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Direct download URL")
                } footer: {
                    Text("Paste a direct link to a .txt, .epub, .pdf, or .md file.\n\nOneDrive: share → copy link (Anyone with the link) then change ?e=… to &download=1\nGoogle Drive: share → copy link, then replace /view with /uc?export=download")
                        .font(.caption)
                }

                if let error = errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red).font(.caption)
                    }
                }
            }
            .navigationTitle("Import from URL")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .platformTrailing) {
                    if isDownloading {
                        ProgressView()
                    } else {
                        Button("Import") { startDownload() }
                            .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func startDownload() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else {
            errorMessage = "Invalid URL."
            return
        }
        guard url.scheme == "https" || url.scheme == "http" else {
            errorMessage = "URL must start with http:// or https://"
            return
        }
        isDownloading = true
        errorMessage = nil

        Task {
            do {
                let localURL = try await download(url)
                await MainActor.run {
                    onImport(localURL)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func download(_ url: URL) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: url)

        // Determine filename from response or URL
        let suggestedName = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")
            .flatMap { extractFilename(from: $0) }
            ?? url.lastPathComponent

        let ext = (suggestedName as NSString).pathExtension.lowercased()
        guard ["txt", "epub", "pdf", "md", "markdown"].contains(ext) else {
            throw URLImportError.unsupportedFormat(ext.isEmpty ? suggestedName : ext)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: tempURL)
        return tempURL
    }

    private func extractFilename(from header: String) -> String? {
        // Content-Disposition: attachment; filename="book.epub"
        let parts = header.components(separatedBy: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("filename=") {
                return trimmed
                    .dropFirst("filename=".count)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }
}

enum URLImportError: LocalizedError {
    case unsupportedFormat(String)
    var errorDescription: String? {
        "Unsupported file type: \(associatedValue). Supported: .txt .epub .pdf .md"
    }
    private var associatedValue: String {
        if case .unsupportedFormat(let s) = self { return s }
        return ""
    }
}
