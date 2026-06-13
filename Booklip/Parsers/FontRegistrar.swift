import CoreText
import Foundation

// Registers embedded EPUB fonts with the system so they can be used by
// PostScript name. Needed to correctly render font-obfuscated books.
enum FontRegistrar {
    private static var registered: Set<String> = []
    // Keeps temp font files alive for the process lifetime.
    // CTFontManagerRegisterFontsForURL(.process) holds the path reference and
    // reads the file on demand — deleting it immediately causes CoreText to fail
    // with "FontParser could not open filePath". The OS cleans temp files on exit.
    private static var fontFileURLs: [URL] = []

    /// Registers the given font files and returns the PostScript name of the
    /// first one that registered successfully (or was already registered).
    static func registerFirst(_ datas: [Data]) -> String? {
        for data in datas {
            if let name = register(data) { return name }
        }
        return nil
    }

    static func register(_ data: Data) -> String? {
        // Create font descriptors from data to obtain the PostScript name.
        // CTFontManagerCreateFontDescriptorsFromData is the modern replacement
        // for creating font references from in-memory data.
        let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData)
            as? [CTFontDescriptor]
        guard let descriptor = descriptors?.first,
              let psName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        else { return nil }

        if registered.contains(psName) { return psName }

        // Write to a temp file and register via CTFontManagerRegisterFontsForURL.
        // Important: do NOT delete the file after registration — CoreText keeps the
        // URL reference and reads the file lazily, so removing it immediately causes
        // a "FontParser could not open filePath" failure.  The temp directory is
        // cleared automatically when the process exits.
        let ext = isOpenType(data) ? "otf" : "ttf"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "." + ext)
        guard (try? data.write(to: tmp)) != nil else { return nil }

        var cfError: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(tmp as CFURL, .process, &cfError)

        if ok {
            registered.insert(psName)
            fontFileURLs.append(tmp)   // keep the file alive
            return psName
        }
        // Already registered by the system or a previous call → still usable.
        if let err = cfError?.takeRetainedValue(),
           CFErrorGetCode(err) == CTFontManagerError.alreadyRegistered.rawValue {
            registered.insert(psName)
            fontFileURLs.append(tmp)   // keep it; the URL may still be referenced
            return psName
        }
        try? FileManager.default.removeItem(at: tmp)   // registration failed — clean up
        return nil
    }

    // OpenType/CFF fonts begin with the "OTTO" signature; everything else is TrueType.
    private static func isOpenType(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data.prefix(4) == Data([0x4F, 0x54, 0x54, 0x4F])
    }
}
