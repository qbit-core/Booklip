import Foundation
#if os(iOS)
import UIKit
#endif

/// Downloads cloud files through a background `URLSession`, so a transfer keeps
/// going when the app is suspended (previously `URLSession.shared.data` stalled
/// until the app came back to the foreground). Callers await the finished file;
/// if the app was terminated mid-transfer the system relaunches it, the task's
/// stored metadata (file name + target folder) is read back and the file is
/// handed to `orphanHandler` so the import still completes.
nonisolated final class BackgroundDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = BackgroundDownloader()
    static let sessionIdentifier = "qbit-core.Booklip.downloads"

    struct Metadata: Codable {
        var name: String
        var folderName: String?
    }

    enum DownloadError: LocalizedError {
        case httpStatus(Int)
        case noResponse
        var errorDescription: String? {
            switch self {
            case .httpStatus(let code): return "File download failed (HTTP \(code))."
            case .noResponse:           return "File download failed."
            }
        }
    }

    /// Set by the app on launch: receives files whose awaiting caller no longer
    /// exists (the app was relaunched by the system to finish a transfer).
    nonisolated(unsafe) var orphanHandler: ((URL, Metadata) -> Void)?
    /// iOS hands us a completion handler when it relaunches the app for this
    /// session; it must be called once all delegate events were delivered.
    nonisolated(unsafe) var backgroundCompletionHandler: (() -> Void)?

    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<URL, Error>] = [:]

    private var sessionStorage: URLSession?
    /// Created on first use (a `lazy var` is not allowed on a nonisolated class).
    private var session: URLSession {
        lock.lock(); defer { lock.unlock() }
        if let existing = sessionStorage { return existing }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true
        let created = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        sessionStorage = created
        return created
    }

    private override init() { super.init() }

    /// Creates the session early so a relaunch-for-background-events can attach
    /// to the pending tasks before any UI asks for a download.
    func warmUp() { _ = session }

    /// Downloads `request` and returns a temp-file URL named `name` (spaces and
    /// slashes preserved as-is except "/" which the file system forbids).
    func download(_ request: URLRequest, name: String, folderName: String?) async throws -> URL {
        let task = session.downloadTask(with: request)
        let meta = Metadata(name: name, folderName: folderName)
        task.taskDescription = (try? JSONEncoder().encode(meta)).flatMap { String(data: $0, encoding: .utf8) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                lock.lock()
                continuations[task.taskIdentifier] = cont
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let meta = downloadTask.taskDescription
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
            ?? Metadata(name: downloadTask.response?.suggestedFilename ?? "download", folderName: nil)

        // `location` is deleted when this method returns — move it now.
        let dest = Self.tempURL(for: meta.name)
        try? FileManager.default.removeItem(at: dest)
        let moved: Result<URL, Error>
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                try? FileManager.default.removeItem(at: dest)
                moved = .failure(DownloadError.httpStatus(http.statusCode))
            } else {
                moved = .success(dest)
            }
        } catch {
            moved = .failure(error)
        }

        lock.lock()
        let cont = continuations.removeValue(forKey: downloadTask.taskIdentifier)
        lock.unlock()
        if let cont {
            cont.resume(with: moved)
        } else if case .success(let url) = moved, let handler = orphanHandler {
            // Nobody is awaiting this task: the app was relaunched by the system.
            DispatchQueue.main.async { handler(url, meta) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuations.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let cont else { return }     // success path already resumed it
        cont.resume(throwing: error ?? DownloadError.noResponse)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [self] in
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }

    // MARK: - Helpers

    private static func tempURL(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(safe)
    }
}
