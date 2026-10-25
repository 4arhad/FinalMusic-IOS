import Foundation
import Network

// Serves InnerTube googlevideo streams over a localhost HTTP server so
// AVPlayer requests ordinary progressive MP4 over http:// while the proxy
// attaches the extracting client's headers to the real upstream requests
// (googlevideo answers AVPlayer's own UA with 503; verified in simulator
// logs). Byte-range requests are forwarded so inspection + playback work.
final class LocalStreamProxy {
    static let shared = LocalStreamProxy()

    private var listener: NWListener?
    private var port: UInt16?
    private var targets: [String: AudioStream] = [:]
    /// Insertion order for `targets`, so only the newest few registrations are
    /// kept (a track's token is useless once the player has moved on).
    private var tokenOrder: [String] = []
    private static let maxTargets = 8
    private let queue = DispatchQueue(label: "lastwave.proxy")
    private let lock = NSLock()

    enum ProxyError: LocalizedError {
        case notListening(String)

        var errorDescription: String? {
            switch self {
            case .notListening(let reason):
                return "Playback could not start (local stream proxy failed: \(reason))"
            }
        }
    }

    /// Registers a stream and waits for the listener's port. Callers are on the
    /// main actor, so the wait must be async — the old `usleep` loop could hold
    /// the main thread for up to 6 s (a hang, not a wait).
    func register(_ stream: AudioStream) async throws -> String {
        let token = String(UUID().uuidString.prefix(12))
        recordRegistration(token: token, stream: stream)
        ensureStarted()
        for attempt in 0..<1200 {
            if let p = lock.withLock({ port }) {
                return "http://127.0.0.1:\(p)/stream/\(token)"
            }
            if attempt == 400 { ensureStarted() } // re-kick after the first listener gave up
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let reason = lock.withLock { lastStateError } ?? "timeout"
        throw ProxyError.notListening(reason)
    }

    private var lastStateError: String?
    private var nextCandidate = 0

    private static let candidatePorts: [UInt16?] = [8219, nil] // fixed, then ephemeral

    private func stream(for token: String) -> AudioStream? {
        lock.lock()
        defer { lock.unlock() }
        return targets[token]
    }

    func ensureStarted() {
        let busy = lock.withLock { listener != nil && port == nil && !bindAttemptActive }
        if busy { return }
        lock.lock()
        guard listener == nil || port == nil else { lock.unlock(); return }
        guard nextCandidate < Self.candidatePorts.count else { lock.unlock(); return }
        let old = listener
        listener = nil
        lock.unlock()
        old?.cancel()

        lock.lock()
        let wantPort = Self.candidatePorts[nextCandidate]
        nextCandidate += 1
        lock.unlock()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let fresh: NWListener?
        if let wantPort, let p = NWEndpoint.Port(rawValue: wantPort) {
            fresh = try? NWListener(using: params, on: p)
        } else {
            fresh = try? NWListener(using: params)
        }
        guard let fresh else {
            lock.lock(); lastStateError = "listener creation failed"; lock.unlock()
            return
        }
        fresh.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        fresh.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                guard let self else { return }
                let resolved = wantPort ?? (fresh.port?.rawValue ?? 0)
                self.lock.lock()
                self.port = resolved == 0 ? nil : resolved
                if self.port == nil { self.lastStateError = "no bound port" }
                self.lock.unlock()
            case .failed(let error):
                guard let self else { return }
                self.lock.lock()
                self.lastStateError = String(describing: error)
                self.listener = nil
                self.lock.unlock()
                fresh.cancel()
            case .setup, .waiting:
                break
            default:
                break
            }
        }
        lock.lock()
        listener = fresh
        lock.unlock()
        fresh.start(queue: queue)
    }

    private var bindAttemptActive = false

    private var upstreamStatuses: [String: Int] = [:]

    // Sync wrapper: NSLock.lock() is noasync, so it must not be called straight
    // from an async context (Swift 6 turns that warning into an error).
    private func recordRegistration(token: String, stream: AudioStream) {
        lock.lock()
        defer { lock.unlock() }
        targets[token] = stream
        tokenOrder.append(token)
        while tokenOrder.count > Self.maxTargets {
            let old = tokenOrder.removeFirst()
            targets.removeValue(forKey: old)
            upstreamStatuses.removeValue(forKey: old)
        }
    }

    // Sync wrapper: NSLock.lock() is noasync, so it must not be called straight
    // from an async context (Swift 6 turns that warning into an error).
    private func recordStatus(_ status: Int, for token: String) {
        lock.lock()
        defer { lock.unlock() }
        upstreamStatuses[token] = status
    }

    /// Status of the most recent upstream response for a token, so callers can
    /// explain a failure ("edge answered HTTP 403") instead of "unknown error".
    func upstreamStatus(for token: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return upstreamStatuses[token]
    }


    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequestHead(connection, buffer: Data())
    }

    private func receiveRequestHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || isComplete || buffer.count > 32_000 {
                connection.cancel()
                return
            }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.process(connection, head: buffer)
            } else {
                self.receiveRequestHead(connection, buffer: buffer)
            }
        }
    }

    private func process(_ connection: NWConnection, head: Data) {
        NSLog("LWPROXY in head: %@", String(decoding: head.prefix(120), as: UTF8.self).replacingOccurrences(of: "\r\n", with: " | "))
        guard let text = String(data: head, encoding: .ascii),
              let requestLine = text.split(separator: "\r\n").first else {
            connection.cancel(); return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            send(connection, status: "405 Method Not Allowed", body: nil)
            return
        }
        let path = String(parts[1])
        let token = path.components(separatedBy: "/").last ?? ""
        guard let target = stream(for: token) else {
            send(connection, status: "404 Not Found", body: nil)
            return
        }

        // Extract the client Range header (AVFoundation always uses ranges
        // for remote MP4 inspection).
        var clientRange: String?
        for line in text.split(separator: "\r\n").dropFirst() {
            if line.lowercased().hasPrefix("range:") {
                clientRange = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            }
        }

        var request = URLRequest(url: target.url)
        request.timeoutInterval = 60
        for (name, value) in target.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let clientRange { request.setValue(clientRange, forHTTPHeaderField: "Range") }

        Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    self.send(connection, status: "502 Bad Gateway", body: nil)
                    return
                }
                self.recordStatus(http.statusCode, for: token)
                let statusText = http.statusCode == 206
                    ? "206 Partial Content" : "\(http.statusCode) OK"
                var headers = "HTTP/1.1 \(statusText)\r\n"
                headers += "Accept-Ranges: bytes\r\n"
                headers += "Connection: close\r\n"
                if let mime = target.mimeType {
                    let baseMime = mime.split(separator: ";").first.map(String.init) ?? mime
                    headers += "Content-Type: \(baseMime)\r\n"
                }
                if let contentRange = http.value(forHTTPHeaderField: "Content-Range") {
                    headers += "Content-Range: \(contentRange)\r\n"
                }
                if let contentLength = http.value(forHTTPHeaderField: "Content-Length") {
                    headers += "Content-Length: \(contentLength)\r\n"
                }
                headers += "\r\n"
                let headData = Data(headers.utf8)
                await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                    connection.send(content: headData, completion: .contentProcessed { _ in k.resume() })
                }

                var buffer = Data(capacity: 128_000)
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count >= 128_000 {
                        await self.pump(connection, buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
                if !buffer.isEmpty { await self.pump(connection, buffer) }
                connection.forceCancel()
            } catch {
                NSLog("LWPROXY upstream error: %@", String(describing: error))
                self.send(connection, status: "502 Bad Gateway", body: nil)
            }
        }
    }

    private func pump(_ connection: NWConnection, _ data: Data) async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in k.resume() })
        }
    }

    private func send(_ connection: NWConnection, status: String, body: String?) {
        var response = "HTTP/1.1 \(status)\r\nConnection: close\r\n"
        if let body {
            response += "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        } else {
            response += "\r\n"
        }
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
