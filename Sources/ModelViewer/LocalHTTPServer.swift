import Combine
import Foundation
import Network

final class LocalHTTPServer: ObservableObject, @unchecked Sendable {
    @Published private(set) var baseURL: URL?

    private let queue = DispatchQueue(label: "com.tangbinhe.modelviewer.http")
    private let port: NWEndpoint.Port = 8765
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var resources: [String: Data] = [:]
    private var pendingCommands: [[String: Any]] = []
    private var statusData = Data("{\"ready\":false}".utf8)

    func start() {
        guard listener == nil else { return }
        loadResources()
        do {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            let listener = try NWListener(using: parameters, on: port)
            self.listener = listener
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("Local HTTP server failed: %@", error.localizedDescription)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            baseURL = URL(string: "http://127.0.0.1:\(port.rawValue)/")
        } catch {
            NSLog("Unable to start local HTTP server: %@", error.localizedDescription)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.connections.removeValue(forKey: identifier)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 1_048_576 {
                self.respond(to: connection, status: 413, body: self.jsonData(["ok": false, "error": "Request too large"]))
                return
            }
            if let request = self.parseRequest(buffer) {
                self.handle(request, connection: connection)
                return
            }
            if complete || error != nil {
                connection.cancel()
                self.connections.removeValue(forKey: ObjectIdentifier(connection))
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private func parseRequest(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8))?.lowerBound else { return nil }
        guard let header = String(data: data[..<headerEnd], encoding: .utf8) else { return nil }
        var lines = header.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3 else { return nil }
        var contentLength = 0
        for line in lines {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, pair[0].lowercased() == "content-length" else { continue }
            contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let bodyStart = headerEnd + 4
        guard data.count >= bodyStart + contentLength else { return nil }
        return Request(
            method: String(parts[0]),
            target: String(parts[1]),
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    private func handle(_ request: Request, connection: NWConnection) {
        let path = URLComponents(string: request.target)?.path ?? request.target
        if request.method == "OPTIONS", path.hasPrefix("/api/") {
            respond(to: connection, status: 204)
            return
        }
        if path == "/api/health", request.method == "GET" {
            respond(to: connection, body: jsonData(["ok": true]))
            return
        }
        if path == "/api/status", request.method == "GET" {
            respond(to: connection, body: statusData)
            return
        }
        if path == "/api/status", request.method == "POST" {
            guard let object = try? JSONSerialization.jsonObject(with: request.body), object is [String: Any] else {
                respond(to: connection, status: 400, body: jsonData(["ok": false, "error": "Invalid status JSON"]))
                return
            }
            statusData = request.body
            respond(to: connection, body: jsonData(["ok": true]))
            return
        }
        if path == "/api/command", request.method == "POST" {
            guard pendingCommands.count < 100 else {
                respond(to: connection, status: 429, body: jsonData(["ok": false, "error": "Command queue is full"]))
                return
            }
            guard let command = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                respond(to: connection, status: 400, body: jsonData(["ok": false, "error": "Request body must be a JSON object"]))
                return
            }
            if let validationError = validate(command) {
                respond(to: connection, status: 400, body: jsonData(["ok": false, "error": validationError]))
                return
            }
            let identifier = UUID().uuidString
            pendingCommands.append(["id": identifier, "command": command])
            respond(to: connection, status: 202, body: jsonData(["ok": true, "id": identifier]))
            return
        }
        if path == "/api/commands/poll", request.method == "GET" {
            let commands = pendingCommands
            pendingCommands.removeAll()
            respond(to: connection, body: jsonData(commands))
            return
        }
        guard request.method == "GET" else {
            respond(to: connection, status: 405, body: jsonData(["ok": false, "error": "Method not allowed"]))
            return
        }
        let relative = path == "/" ? "index.html" : String(path.dropFirst())
        guard !relative.contains(".."), let data = resources[relative] else {
            respond(to: connection, status: 404, body: Data("Not found".utf8), contentType: "text/plain; charset=utf-8")
            return
        }
        respond(to: connection, body: data, contentType: mimeType(for: relative))
    }

    private func validate(_ command: [String: Any]) -> String? {
        let allowedKeys: Set<String> = ["expression", "action", "duration", "weight", "background", "view", "clean"]
        guard command.keys.allSatisfy({ allowedKeys.contains($0) }) else { return "Unknown command field" }
        guard command.keys.contains(where: { ["expression", "action", "background", "view", "clean"].contains($0) }) else {
            return "Command must include expression, action, background, view, or clean"
        }
        if let expression = command["expression"] {
            guard let value = expression as? String, value.count <= 64 else { return "Invalid expression" }
        }
        if let action = command["action"] {
            guard let value = action as? String, ["idle", "nod", "wave", "bow", "spin", "stop"].contains(value) else {
                return "Invalid action"
            }
        }
        if let background = command["background"] {
            guard let value = background as? String, value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
                return "Background must use #RRGGBB"
            }
        }
        if let view = command["view"] {
            guard let value = view as? String, ["front", "right", "left", "back", "top", "perspective", "fit"].contains(value) else {
                return "Invalid view"
            }
        }
        if let duration = command["duration"] {
            guard let value = duration as? NSNumber, value.doubleValue >= 0.2, value.doubleValue <= 30 else {
                return "Duration must be between 0.2 and 30 seconds"
            }
        }
        if let weight = command["weight"] {
            guard let value = weight as? NSNumber, value.doubleValue >= 0, value.doubleValue <= 1 else {
                return "Weight must be between 0 and 1"
            }
        }
        if let clean = command["clean"], !(clean is Bool) { return "Clean must be a boolean" }
        return nil
    }

    private func respond(
        to connection: NWConnection,
        status: Int = 200,
        body: Data = Data(),
        contentType: String = "application/json; charset=utf-8"
    ) {
        let phrases = [200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed", 413: "Payload Too Large", 429: "Too Many Requests"]
        var data = Data("HTTP/1.1 \(status) \(phrases[status] ?? "OK")\r\n".utf8)
        data.append(Data("Content-Length: \(body.count)\r\n".utf8))
        data.append(Data("Content-Type: \(contentType)\r\n".utf8))
        data.append(Data("Cache-Control: no-store\r\n".utf8))
        data.append(Data("Access-Control-Allow-Origin: *\r\n".utf8))
        data.append(Data("Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n".utf8))
        data.append(Data("Access-Control-Allow-Headers: Content-Type\r\n".utf8))
        data.append(Data("X-Content-Type-Options: nosniff\r\n".utf8))
        data.append(Data("Connection: close\r\n\r\n".utf8))
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.connections.removeValue(forKey: ObjectIdentifier(connection))
        })
    }

    private func jsonData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{\"ok\":false}".utf8)
    }

    private func loadResources() {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true),
              let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == false else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            resources[relative] = try? Data(contentsOf: url)
        }
    }

    private func mimeType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "glb": return "model/gltf-binary"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    private struct Request {
        let method: String
        let target: String
        let body: Data
    }
}
