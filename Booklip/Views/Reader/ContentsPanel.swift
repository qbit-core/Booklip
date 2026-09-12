import SwiftUI

// Combined Table of Contents + Bookmarks sheet.
struct ContentsPanel: View {
    @ObservedObject var vm: ReaderViewModel
    let onJump: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .contents

    enum Tab: String, CaseIterable { case contents = "Contents", bookmarks = "Bookmarks", highlights = "Highlights" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                switch tab {
                case .contents:   contentsList
                case .bookmarks:  bookmarksList
                case .highlights: highlightsList
                }
            }
            .navigationTitle("Navigate")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .platformTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var contentsList: some View {
        Group {
            if vm.chapters.isEmpty {
                ContentUnavailableView("No Chapters", systemImage: "list.bullet",
                    description: Text("This book has no table of contents."))
            } else {
                List(vm.chapters) { chapter in
                    Button {
                        onJump(chapter.progress); dismiss()
                    } label: {
                        HStack {
                            Text(chapter.title)
                                .font(chapter.level == 0 ? .body : .subheadline)
                                .foregroundStyle(chapter.level == 0 ? .primary : .secondary)
                                .lineLimit(2)
                            Spacer()
                            Text("\(Int(chapter.progress * 100))%")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.leading, CGFloat(chapter.level) * 16)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var bookmarksList: some View {
        Group {
            if vm.bookmarks.isEmpty {
                ContentUnavailableView("No Bookmarks", systemImage: "bookmark",
                    description: Text("Tap the bookmark button while reading to add one."))
            } else {
                List {
                    ForEach(vm.bookmarks) { mark in
                        Button {
                            onJump(mark.progress); dismiss()
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(mark.snippet.isEmpty ? "Bookmark" : mark.snippet)
                                        .font(snippetFont).lineLimit(2)
                                    Text(bookmarkSubtitle(mark))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        offsets.map { vm.bookmarks[$0] }.forEach(vm.deleteBookmark)
                    }
                }
            }
        }
    }

    /// Snippets are slices of the book text. Books that ship a scrambled-
    /// codepoint anti-copy font are only legible in that embedded font, so use
    /// it for snippet text when the book has one.
    private var snippetFont: Font {
        vm.embeddedFontName.map { Font.custom($0, size: 15) } ?? .subheadline
    }

    private func bookmarkSubtitle(_ mark: Bookmark) -> String {
        let pct = "\(Int(mark.progress * 100))%"
        let page = vm.pageNumber(at: mark.progress).map { "p. \($0)  ·  " } ?? ""
        return "\(page)\(pct)  ·  \(mark.date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var highlightsList: some View {
        Group {
            if vm.highlights.isEmpty {
                ContentUnavailableView("No Highlights", systemImage: "highlighter",
                    description: Text("Turn on the highlighter, select text, and choose a color."))
            } else {
                List {
                    ForEach(vm.highlights) { h in
                        Button {
                            onJump(h.progress); dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Circle()
                                    .fill((HighlightColor(rawValue: h.colorName)?.color ?? .yellow).opacity(0.6))
                                    .frame(width: 14, height: 14).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(h.snippet).font(snippetFont).lineLimit(3)
                                    Text("\(Int(h.progress * 100))%")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        offsets.map { vm.highlights[$0] }.forEach(vm.deleteHighlight)
                    }
                }
            }
        }
    }
}
