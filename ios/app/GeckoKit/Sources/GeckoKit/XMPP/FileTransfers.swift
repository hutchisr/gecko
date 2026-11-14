import Foundation

/// HTTP uploads and downloads with progress, for `SwiftCore`. Downloads go to
/// a partial file and pick up where they stopped; transfers cancel by key.
final class FileTransfers: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    typealias Progress = @MainActor (_ transferred: Int64, _ total: Int64?) -> Void

    /// The delegate queue; everything below is only touched on it.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let configuration: URLSessionConfiguration
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)

    private struct Running {
        let task: URLSessionTask
        let key: Int64
        let report: Progress
        let done: (Error?) -> Void
        var lastReport = Date.distantPast
        /// Downloads: the partial file, and how much it held before this request.
        var file: FileHandle?
        var partial: URL?
        var offset: Int64 = 0
    }
    private var running: [Int: Running] = [:]

    init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    /// PUTs `data` (XEP-0363 §5): true when the server stored it.
    func upload(_ data: Data, to slot: FileSharing.Slot, type: String, key: Int64,
                progress: @escaping Progress) async -> Bool {
        var request = URLRequest(url: slot.put)
        request.httpMethod = "PUT"
        request.setValue(type, forHTTPHeaderField: "Content-Type")
        slot.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let task = session.uploadTask(with: request, from: data)
        return await run(task, key: key, progress: progress) { task in
            ((task.response as? HTTPURLResponse)?.statusCode).map { (200...299).contains($0) } ?? false
        }
    }

    /// GETs a shared file into `partial`, asking only for what it lacks; true
    /// once `partial` holds the whole file. A failed or cancelled download
    /// keeps what arrived for the next try.
    func download(_ url: URL, to partial: URL, key: Int64, progress: @escaping Progress) async -> Bool {
        var request = URLRequest(url: url)
        let have = ((try? FileManager.default.attributesOfItem(atPath: partial.path)[.size]) as? Int64) ?? 0
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        return await run(task, key: key, progress: progress, partial: partial, offset: have) { task in
            ((task.response as? HTTPURLResponse)?.statusCode).map { $0 == 200 || $0 == 206 } ?? false
        }
    }

    func cancel(_ key: Int64) {
        queue.addOperation { [self] in
            running.values.filter { $0.key == key }.forEach { $0.task.cancel() }
        }
    }

    private func run(_ task: URLSessionTask, key: Int64, progress: @escaping Progress, partial: URL? = nil,
                     offset: Int64 = 0, succeeded: @escaping (URLSessionTask) -> Bool) async -> Bool {
        await withCheckedContinuation { (finished: CheckedContinuation<Bool, Never>) in
            queue.addOperation { [self] in
                running[task.taskIdentifier] = Running(task: task, key: key, report: progress, done: { error in
                    finished.resume(returning: error == nil && succeeded(task))
                }, partial: partial, offset: offset)
                task.resume()
            }
        }
    }

    // MARK: URLSession

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData _: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        report(task.taskIdentifier, totalBytesSent, totalBytesExpectedToSend)
    }

    /// Appends to the partial file when the server sends the rest (206 from
    /// where it stops), starts it over when it sends everything (200).
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard var transfer = running[dataTask.taskIdentifier], let partial = transfer.partial else {
            return completionHandler(.allow)
        }
        let http = response as? HTTPURLResponse
        let resumes = http?.statusCode == 206
            && http?.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(transfer.offset)-") == true
        guard http?.statusCode == 200 || resumes else { return completionHandler(.cancel) }
        if !resumes {
            transfer.offset = 0
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        } else if !FileManager.default.fileExists(atPath: partial.path) {
            return completionHandler(.cancel)
        }
        guard let file = try? FileHandle(forWritingTo: partial) else { return completionHandler(.cancel) }
        _ = try? file.seekToEnd()
        transfer.file = file
        running[dataTask.taskIdentifier] = transfer
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = running[dataTask.taskIdentifier] else { return }
        try? transfer.file?.write(contentsOf: data)
        let expected = dataTask.countOfBytesExpectedToReceive
        report(dataTask.taskIdentifier, transfer.offset + dataTask.countOfBytesReceived,
               expected > 0 ? transfer.offset + expected : 0)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = running.removeValue(forKey: task.taskIdentifier) else { return }
        try? transfer.file?.close()
        transfer.done(error)
    }

    /// At most a few progress reports a second.
    private func report(_ id: Int, _ done: Int64, _ total: Int64) {
        guard var transfer = running[id] else { return }
        let now = Date()
        if now.timeIntervalSince(transfer.lastReport) < 0.25, done < total { return }
        transfer.lastReport = now
        running[id] = transfer
        let report = transfer.report
        Task { @MainActor in report(done, total > 0 ? total : nil) }
    }
}
