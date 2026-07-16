import SwiftUI
import Combine

// feature 1 & 2: scroll = continuous scroll, paper = single page no-scroll
enum ReaderDisplayMode: String, Codable {
    case scroll
    case paper
}

struct ColorPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let background: Color
    let text: Color

    static let all: [ColorPreset] = [
        ColorPreset(id: "default",  name: "Default", background: .white,                                                         text: .black),
        ColorPreset(id: "sepia",    name: "Sepia",   background: Color(r: 0.97, g: 0.94, b: 0.86), text: Color(r: 0.30, g: 0.20, b: 0.10)),
        ColorPreset(id: "dark",     name: "Dark",    background: Color(r: 0.10, g: 0.10, b: 0.12), text: Color(r: 0.90, g: 0.90, b: 0.90)),
        ColorPreset(id: "forest",   name: "Forest",  background: Color(r: 0.12, g: 0.18, b: 0.12), text: Color(r: 0.82, g: 0.92, b: 0.80)),
        ColorPreset(id: "ocean",    name: "Ocean",   background: Color(r: 0.07, g: 0.11, b: 0.22), text: Color(r: 0.78, g: 0.92, b: 1.00)),
        ColorPreset(id: "rose",     name: "Rose",    background: Color(r: 0.99, g: 0.95, b: 0.96), text: Color(r: 0.35, g: 0.15, b: 0.20)),
    ]
}

private extension Color {
    init(r: Double, g: Double, b: Double) {
        self.init(red: r, green: g, blue: b)
    }
}

class ReadingSettings: ObservableObject {
    @Published var fontName:    String = UserDefaults.standard.string(forKey: "fontName")    ?? "Georgia" { didSet { UserDefaults.standard.set(fontName,    forKey: "fontName") } }
    @Published var fontSize:    Double = UserDefaults.standard.double(forKey: "fontSize").nonZero ?? 18.0   { didSet { UserDefaults.standard.set(fontSize,    forKey: "fontSize") } }
    @Published var lineSpacing: Double = UserDefaults.standard.double(forKey: "lineSpacing").nonZero ?? 8.0 { didSet { UserDefaults.standard.set(lineSpacing, forKey: "lineSpacing") } }
    @Published var presetId:    String = UserDefaults.standard.string(forKey: "presetId")    ?? "default" { didSet { UserDefaults.standard.set(presetId,    forKey: "presetId") } }
    @Published var displayMode: ReaderDisplayMode = {
        ReaderDisplayMode(rawValue: UserDefaults.standard.string(forKey: "displayMode") ?? "") ?? .scroll
    }() { didSet { UserDefaults.standard.set(displayMode.rawValue, forKey: "displayMode") } }

    var currentPreset: ColorPreset {
        ColorPreset.all.first { $0.id == presetId } ?? ColorPreset.all[0]
    }

    // feature 3: map preset to system color scheme so entire app UI adapts
    var preferredColorScheme: ColorScheme? {
        switch presetId {
        case "dark", "forest", "ocean": return .dark
        default: return .light
        }
    }

    var swiftUIFont: Font {
        Font.custom(fontName, size: fontSize)
    }

    static let availableFonts: [String] = [
        "Georgia", "Times New Roman", "Palatino-Roman", "Baskerville",
        "HelveticaNeue", "Arial", "Futura-Medium", "GillSans",
        "AmericanTypewriter", "Courier New",
    ]
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
