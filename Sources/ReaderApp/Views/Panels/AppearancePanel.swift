import SwiftUI

struct AppearancePanel: View {
    @ObservedObject var settings: ReadingSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Theme
                    PanelSection(title: "Theme") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(ColorPreset.all) { preset in
                                    presetButton(preset)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }

                    // feature 1 & 2: display mode (scroll = continuous, paper = single page)
                    PanelSection(title: "View Mode") {
                        Picker("View Mode", selection: $settings.displayMode) {
                            Label("Scroll", systemImage: "scroll").tag(ReaderDisplayMode.scroll)
                            Label("Paper", systemImage: "doc.plaintext").tag(ReaderDisplayMode.paper)
                        }
                        .pickerStyle(.segmented)
                    }

                    // Font
                    PanelSection(title: "Font") {
                        Picker(selection: $settings.fontName, label: EmptyView()) {
                            ForEach(ReadingSettings.availableFonts, id: \.self) { name in
                                Text(name).font(.custom(name, size: 16)).tag(name)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Size
                    PanelSection(title: "Size") {
                        LabeledSlider(value: $settings.fontSize, range: 12...32, unit: "pt")
                    }

                    // Line Spacing
                    PanelSection(title: "Line Spacing") {
                        LabeledSlider(value: $settings.lineSpacing, range: 0...24, unit: "pt")
                    }

                    // Preview
                    PanelSection(title: "Preview") {
                        Text("The quick brown fox jumps over the lazy dog.")
                            .font(settings.swiftUIFont)
                            .foregroundStyle(settings.currentPreset.text)
                            .lineSpacing(settings.lineSpacing)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(settings.currentPreset.background)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("Appearance")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .platformTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func presetButton(_ preset: ColorPreset) -> some View {
        Button {
            settings.presetId = preset.id
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(preset.background)
                        .frame(width: 56, height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    settings.presetId == preset.id ? Color.accentColor : Color.secondary.opacity(0.3),
                                    lineWidth: settings.presetId == preset.id ? 2.5 : 1
                                )
                        )
                    Text("Aa")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(preset.text)
                }
                Text(preset.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct LabeledSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String

    var body: some View {
        HStack {
            Slider(value: $value, in: range, step: 1)
                .tint(.accentColor)
            Text("\(Int(value))\(unit)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}
