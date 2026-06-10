import CoreGraphics
import CoreText
import Foundation

// Registers embedded EPUB fonts with the system so they can be used by
// PostScript name. Needed to correctly render font-obfuscated books.
enum FontRegistrar {
    private static var registered: Set<String> = []

    /// Registers the given font files and returns the PostScript name of the
    /// first one that registered successfully (or was already registered).
    static func registerFirst(_ datas: [Data]) -> String? {
        for data in datas {
            if let name = register(data) { return name }
        }
        return nil
    }

    static func register(_ data: Data) -> String? {
        guard let provider = CGDataProvider(data: data as CFData),
              let cgFont = CGFont(provider),
              let psName = cgFont.postScriptName as String? else { return nil }

        if registered.contains(psName) { return psName }

        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterGraphicsFont(cgFont, &error) {
            registered.insert(psName)
            return psName
        }
        // Already registered by the system in a previous load → still usable.
        if let err = error?.takeRetainedValue() {
            let code = CFErrorGetCode(err)
            if code == CTFontManagerError.alreadyRegistered.rawValue {
                registered.insert(psName)
                return psName
            }
        }
        return nil
    }
}
