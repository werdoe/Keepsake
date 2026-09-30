import Foundation
import UIKit

/// Downloads through a background URLSession, so transfers keep going after you leave the app
/// (iOS runs them in its own process and wakes Keepsake when they finish).
/// Swiping Keepsake away in the app switcher still cancels them; that's an iOS rule.
final class BackgroundDownloader: NSObject, MediaDownloading, URLSessionDownloadDelegate {
    static let shared = BackgroundDownloader()

    private struct Pending {
        let continuation: CheckedContinuation<URL, Error>
        let progress: (Double) -> Void
        let fileExtension: String
        var result: Result<URL, Error>?
    }

    private var sessions: [String: URLSession] = [:]
    private var pending: [String: Pending] = [:]
    private var completionHandlers: [String: () -> Void] = [:]
    private let lock = NSLock()

    private static func identifier(wifiOnly: Bool) -> String {
        "com.rai.igsaver.downloads." + (wifiOnly ? "wifi" : "any")
    }

    private func session(identifier: String) -> URLSession {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[identifier] { return existing }
        let wifiOnly = identifier.hasSuffix(".wifi")
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.allowsCellularAccess = !wifiOnly
        config.allowsExpensiveNetworkAccess = !wifiOnly
        config.allowsConstrainedNetworkAccess = !wifiOnly
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        sessions[identifier] = session
        return session
    }

    /// Called from the app delegate when iOS wakes the app for finished downloads.
    func reconnect(identifier: String, completion: @escaping () -> Void) {
        lock.lock()
        completionHandlers[identifier] = completion
        lock.unlock()
        _ = session(identifier: identifier)
    }

    func download(_ source: MediaSource, url: URL, fileExtension: String, wifiOnly: Bool,
                  progress: @escaping (Double) -> Void) async throws -> URL {
        let session = session(identifier: Self.identifier(wifiOnly: wifiOnly))
        let task = session.downloadTask(with: request(for: url, headers: source.headers))
        let key = Self.key(task, session)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pending[key] = Pending(continuation: continuation, progress: progress, fileExtension: fileExtension)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private static func key(_ task: URLSessionTask, _ session: URLSession) -> String {
        "\(session.configuration.identifier ?? "")#\(task.taskIdentifier)"
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let handler = pending[Self.key(downloadTask, session)]?.progress
        lock.unlock()
        handler?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let key = Self.key(downloadTask, session)
        lock.lock()
        let fileExtension = pending[key]?.fileExtension
        lock.unlock()
        guard let fileExtension else {
            // The app was relaunched and nobody is waiting for this file any more.
            return
        }
        // The temporary file disappears when this method returns, so move it now.
        let result: Result<URL, Error>
        do {
            result = .success(try Downloads.accept(location, response: downloadTask.response, fileExtension: fileExtension))
        } catch {
            result = .failure(error)
        }
        lock.lock()
        pending[key]?.result = result
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let key = Self.key(task, session)
        lock.lock()
        let entry = pending.removeValue(forKey: key)
        lock.unlock()
        guard let entry else { return }
        if let error {
            entry.continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : KeepsakeError.from(error))
        } else if let result = entry.result {
            entry.continuation.resume(with: result)
        } else {
            entry.continuation.resume(throwing: KeepsakeError.downloadFailed)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        lock.lock()
        let handler = completionHandlers.removeValue(forKey: identifier)
        lock.unlock()
        DispatchQueue.main.async { handler?() }
    }
}

/// Receives the "downloads finished" wake-up from iOS.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundDownloader.shared.reconnect(identifier: identifier, completion: completionHandler)
    }
}
