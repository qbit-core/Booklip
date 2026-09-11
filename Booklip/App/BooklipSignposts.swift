import Foundation
import os.signpost



// Persists open-book signpost IDs and timing anchors on the main actor so
// begin (ReaderViewModel) and end (Coordinator.didLayout) can share them.
@MainActor
final class OpenSignpostState {
    static let shared = OpenSignpostState()
    private init() {}
    var endToEndID: OSSignpostID = OSSignpostID(log: booklipSpLog)
    var firstLayoutID: OSSignpostID = OSSignpostID(log: booklipSpLog)
    // CFAbsoluteTime anchors for [TIME] prints — no Date.elapsedMs() needed.
    var endToEndT0: CFAbsoluteTime = 0
    var firstLayoutT0: CFAbsoluteTime = 0
}
