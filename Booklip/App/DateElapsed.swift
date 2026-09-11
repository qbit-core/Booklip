import Foundation
import os.signpost
#if canImport(UIKit)
import UIKit
#endif

nonisolated(unsafe) let booklipSpLog = OSLog(subsystem: "com.booklip", category: "TextLayout")

extension Date {
    /// Milliseconds elapsed since self. Safe from any concurrency context.
    func elapsedMs() -> Double { -timeIntervalSinceNow * 1000 }
}

#if canImport(UIKit)
/// Boxes NSAttributedString (non-Sendable) for one-way transfer across actor boundary.
/// The box is written once on the producer side and read once on MainActor — no races.
final class UncheckedSendableAttrStr: @unchecked Sendable {
    nonisolated(unsafe) let value: NSAttributedString
    nonisolated init(_ v: NSAttributedString) { value = v }
}
#endif
