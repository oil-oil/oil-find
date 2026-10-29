import Foundation

public final class UpdateClient {
    public static let latestURL = URL(string: "https://find.oiloil.org/updates/latest-v2.json")!
    private let manifestURL: URL
    private let version: String
    private let allowLocalhost: Bool
    public init(version: String, manifestURL: URL = UpdateClient.latestURL, allowLocalhost: Bool = false) {
        self.version = version; self.manifestURL = manifestURL; self.allowLocalhost = allowLocalhost
    }
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
        config.httpAdditionalHeaders = ["User-Agent": "OilFind/" + version, "Accept-Language": ""]
        return config
    }
    public func check() async throws -> UpdateManifest {
        guard UpdateManifest.validURL(manifestURL, allowLocalhost: allowLocalhost) else { throw UpdateFailure.other }
        let session = URLSession(configuration: configuration(), delegate: UpdateNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(from: manifestURL) }
        catch { throw UpdateFailure.network }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure.network }
        let manifest = try UpdateManifest.parse(data, allowLocalhost: allowLocalhost)
        guard manifest.url.host == manifestURL.host else { throw UpdateFailure.other }
        return manifest
    }
    // The returned directory belongs to the caller and must be removed after use.
    public func download(_ manifest: UpdateManifest, progress: @escaping (Double) -> Void) async throws -> URL {
        guard UpdateManifest.validURL(manifest.url, allowLocalhost: allowLocalhost) else { throw UpdateFailure.other }
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = UpdateDownload(size: manifest.size, progress: progress) { continuation.resume(with: $0) }
            let session = URLSession(configuration: configuration(), delegate: delegate, delegateQueue: nil)
            session.downloadTask(with: manifest.url).resume()
        }
    }
}

private class UpdateNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class UpdateDownload: UpdateNoRedirect, URLSessionDownloadDelegate {
    private let size: Int64
    private let progress: (Double) -> Void
    private var completion: ((Result<URL, Error>) -> Void)?
    private var failure: UpdateFailure?
    init(size: Int64, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.size = size; self.progress = progress; self.completion = completion
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > size { failure = .integrity; downloadTask.cancel() }
        else { progress(min(1, Double(totalBytesWritten) / Double(size))) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { finish(session, .failure(UpdateFailure.network)); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oilfind-download-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let archive = directory.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: location, to: archive)
            finish(session, .success(archive))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            finish(session, .failure(UpdateFailure.other))
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(session, .failure(failure ?? (error is URLError ? UpdateFailure.network : UpdateFailure.other))) }
    }
    private func finish(_ session: URLSession, _ result: Result<URL, Error>) {
        let callback = completion; completion = nil
        callback?(result); session.finishTasksAndInvalidate()
    }
}
