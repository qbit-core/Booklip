import SwiftUI
import Combine

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

enum PageEffect: String, CaseIterable, Identifiable {
    case verticalSlide = "Vertical Slide"
    case paper         = "Paper Book"
    var id: String { rawValue }
}

class ReadingSettings: ObservableObject {
    @Published var fontName:    String = UserDefaults.standard.string(forKey: "fontName")    ?? "Georgia" { didSet { UserDefaults.standard.set(fontName,    forKey: "fontName") } }
    @Published var fontSize:    Double = UserDefaults.standard.double(forKey: "fontSize").nonZero ?? 18.0   { didSet { UserDefaults.standard.set(fontSize,    forKey: "fontSize") } }
    @Published var lineSpacing: Double = UserDefaults.standard.double(forKey: "lineSpacing").nonZero ?? 8.0 { didSet { UserDefaults.standard.set(lineSpacing, forKey: "lineSpacing") } }
    @Published var presetId:    String = UserDefaults.standard.string(forKey: "presetId")    ?? "default" { didSet { UserDefaults.standard.set(presetId,    forKey: "presetId") } }
    @Published var pageEffect:  PageEffect = PageEffect(rawValue: UserDefaults.standard.string(forKey: "pageEffect") ?? "") ?? .verticalSlide { didSet { UserDefaults.standard.set(pageEffect.rawValue, forKey: "pageEffect") } }
    @Published var useEmbeddedFont: Bool = UserDefaults.standard.object(forKey: "useEmbeddedFont") as? Bool ?? true { didSet { UserDefaults.standard.set(useEmbeddedFont, forKey: "useEmbeddedFont") } }
    @Published var autoScrollSpeed: Double = UserDefaults.standard.double(forKey: "autoScrollSpeed").nonZero ?? 40 { didSet { UserDefaults.standard.set(autoScrollSpeed, forKey: "autoScrollSpeed") } }

    var currentPreset: ColorPreset {
        ColorPreset.all.first { $0.id == presetId } ?? ColorPreset.all[0]
    }

    var preferredColorScheme: ColorScheme? {
        let darkPresets: Set<String> = ["dark", "forest", "ocean"]
        return darkPresets.contains(presetId) ? .dark : .light
    }

    var swiftUIFont: Font {
        Font.custom(fontName, size: fontSize)
    }

    static let availableFonts: [FontOption] = [
        // Latin
        FontOption("Georgia",            "Georgia"),
        FontOption("Times New Roman",    "Times New Roman"),
        FontOption("Palatino",           "Palatino-Roman"),
        FontOption("Baskerville",        "Baskerville"),
        FontOption("Helvetica Neue",     "HelveticaNeue"),
        FontOption("Arial",              "Arial"),
        FontOption("Futura",             "Futura-Medium"),
        FontOption("Gill Sans",          "GillSans"),
        FontOption("American Typewriter","AmericanTypewriter"),
        FontOption("Courier New",        "Courier New"),
        // Korean (한국어)
        FontOption("본고딕 (Apple SD Gothic Neo)", "AppleSDGothicNeo-Regular"),
        FontOption("명조 (Apple Myungjo)",         "AppleMyungjo"),
        FontOption("궁서 (GungSeo)",               "GungSeo"),
    ]
}

struct FontOption: Identifiable, Hashable {
    let displayName: String
    let fontName: String
    var id: String { fontName }
    init(_ displayName: String, _ fontName: String) {
        self.displayName = displayName
        self.fontName = fontName
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
