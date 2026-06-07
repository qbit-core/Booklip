import SwiftUI

// Combined Table of Contents + Bookmarks sheet.
struct ContentsPanel: View {
    @ObservedObject var vm: ReaderViewModel
    let onJump: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .contents

    enum Tab: String, CaseIterable { case contents = "Contents", bookmarks = "Bookmarks" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding()

                if tab == .contents { contentsList } else { bookmarksList }
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
                                        .font(.subheadline).lineLimit(2)
                                    Text("\(Int(mark.progress * 100))%  ·  \(mark.date.formatted(date: .abbreviated, time: .shortened))")
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
}
