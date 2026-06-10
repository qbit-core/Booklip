import SwiftUI

struct StatsView: View {
    @EnvironmentObject private var library: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    private var total: Int { library.books.count }
    private var finished: Int { library.books.filter { $0.progress >= 0.95 }.count }
    private var reading: Int { library.books.filter { $0.progress > 0 && $0.progress < 0.95 }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                    StatCard(title: "Time Read", value: timeString, icon: "clock", tint: .blue)
                    StatCard(title: "Day Streak", value: "\(ReadingStats.currentStreak)", icon: "flame", tint: .orange)
                    StatCard(title: "Books", value: "\(total)", icon: "books.vertical", tint: .indigo)
                    StatCard(title: "Reading", value: "\(reading)", icon: "book", tint: .teal)
                    StatCard(title: "Finished", value: "\(finished)", icon: "checkmark.seal", tint: .green)
                }
                .padding()
            }
            .navigationTitle("Reading Stats")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .platformTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private var timeString: String {
        let s = Int(ReadingStats.totalSeconds)
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint)
            Text(value).font(.title.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
