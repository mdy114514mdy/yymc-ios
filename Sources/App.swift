// YYMC iOS：WKWebView + App 内的回环服务
//   · 静态资源：bundle 里的 site/（支持 Range）
//   · /rooms/api/*：用 URLSession 反代到官方房间服务，补 Origin 白名单头
//   · /rooms/p2p：WebSocket 隧道（本地替浏览器完成握手，再与上游对接，之后原样搬字节）
//
// 为什么要这层：官方服务只认 Origin: https://www.bilibili.com，而 Origin 是浏览器的 forbidden header，
// 页面 JS 改不了（WebSocket 握手也无法设置 header），所以必须在浏览器之外补。全程在设备内，不依赖云端。
import UIKit
import WebKit
import Network
import CryptoKit
import Security

private let kOrigin = "https://www.bilibili.com"
private let kUpHost = "xz.honghemc.cn"
private let kUpPort: UInt16 = 8443
private let kWsGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// MARK: - 回环服务

final class LocalServer {

    private let root: URL
    private let port: UInt16
    private var listener: NWListener?

    init(root: URL, port: UInt16) {
        self.root = root
        self.port = port
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let l = try NWListener(using: .tcp, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: DispatchQueue.global(qos: .userInitiated))
            self?.readRequest(conn, buffer: Data())
        }
        l.start(queue: DispatchQueue.global(qos: .userInitiated))
        listener = l
    }

    // MARK: - 读请求

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                conn.cancel()
                return
            }
            var buf = buffer
            if let d = data { buf.append(d) }

            guard let sep = buf.range(of: Data([13, 10, 13, 10])) else {
                if error != nil || isComplete || buf.count > 65536 {
                    conn.cancel()
                } else {
                    self.readRequest(conn, buffer: buf)
                }
                return
            }

            let headText = String(decoding: buf[buf.startIndex..<sep.lowerBound], as: UTF8.self)
            let lines = headText.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                conn.cancel()
                return
            }
            let parts = requestLine.split(separator: " ")
            if parts.count < 2 {
                conn.cancel()
                return
            }
            let method = String(parts[0])
            let target = String(parts[1])

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }

            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            let remainder = Data(buf[sep.upperBound...])

            if remainder.count < contentLength {
                if error != nil || isComplete {
                    conn.cancel()
                } else {
                    self.readRequest(conn, buffer: buf)
                }
                return
            }
            let body = contentLength > 0 ? Data(remainder.prefix(contentLength)) : Data()
            let afterBody = contentLength > 0 ? Data(remainder.dropFirst(contentLength)) : remainder

            self.dispatch(conn, method: method, target: target, headers: headers, body: body, carried: afterBody)
        }
    }

    private func dispatch(_ conn: NWConnection, method: String, target: String,
                          headers: [String: String], body: Data, carried: Data) {
        var path = target
        if let q = path.firstIndex(of: "?") { path = String(path[path.startIndex..<q]) }

        if path == "/rooms/p2p" {
            let key = headers["sec-websocket-key"] ?? ""
            if key.isEmpty {
                sendResponse(conn, "400 Bad Request", "text/plain; charset=utf-8", Data("no ws key".utf8))
                return
            }
            tunnel(conn, target: target, clientKey: key, carried: carried)
            return
        }
        if path.hasPrefix("/rooms/") {
            proxyHTTP(conn, method: method, fullTarget: target, body: body)
            return
        }
        serveFile(conn, target: target, headers: headers)
    }

    // MARK: - /rooms/api/* HTTP 反代

    private func proxyHTTP(_ conn: NWConnection, method: String, fullTarget: String, body: Data) {
        let upstreamPath = String(fullTarget.dropFirst("/rooms".count))
        guard let url = URL(string: "https://\(kUpHost):\(kUpPort)\(upstreamPath)") else {
            sendResponse(conn, "400 Bad Request", "text/plain; charset=utf-8", Data("bad url".utf8))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue(kOrigin, forHTTPHeaderField: "Origin")
        req.setValue(kOrigin + "/", forHTTPHeaderField: "Referer")
        req.setValue("YYMC-iOS", forHTTPHeaderField: "User-Agent")
        if !body.isEmpty {
            req.httpBody = body
            req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        }

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { conn.cancel(); return }
            if let error = error {
                let msg = "{\"error\":\"relay: \(error.localizedDescription)\"}"
                self.sendResponse(conn, "502 Bad Gateway", "application/json; charset=utf-8", Data(msg.utf8))
                return
            }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 502
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json; charset=utf-8"
            self.sendResponse(conn, "\(code) Relay", type, data ?? Data())
        }.resume()
    }

    // MARK: - /rooms/p2p WebSocket 隧道

    private func tunnel(_ conn: NWConnection, target: String, clientKey: String, carried: Data) {
        var path = target
        if path.hasPrefix("/rooms") { path = String(path.dropFirst("/rooms".count)) }
        if path.isEmpty { path = "/p2p" }

        guard let nwPort = NWEndpoint.Port(rawValue: kUpPort) else {
            sendResponse(conn, "500 Tunnel", "text/plain; charset=utf-8", Data("bad port".utf8))
            return
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        let up = NWConnection(host: NWEndpoint.Host(kUpHost), port: nwPort, using: params)

        // 浏览器那侧要的 accept：base64(sha1(它的 key + GUID))
        let accept = Self.accept(for: clientKey)

        up.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                let hs = "GET \(path) HTTP/1.1\r\n"
                    + "Host: \(kUpHost):\(kUpPort)\r\n"
                    + "Upgrade: websocket\r\n"
                    + "Connection: Upgrade\r\n"
                    + "Sec-WebSocket-Version: 13\r\n"
                    + "Sec-WebSocket-Key: \(Self.randomKey())\r\n"
                    + "Origin: \(kOrigin)\r\n"
                    + "Referer: \(kOrigin)/\r\n"
                    + "\r\n"
                up.send(content: Data(hs.utf8), completion: .contentProcessed { err in
                    if err != nil {
                        self.sendResponse(conn, "502 Tunnel", "text/plain; charset=utf-8", Data("send failed".utf8))
                        up.cancel()
                        return
                    }
                    self.waitUpstreamHandshake(conn, up: up, accept: accept, carried: carried)
                })
            case .failed, .cancelled:
                self.sendResponse(conn, "502 Tunnel", "text/plain; charset=utf-8", Data("upstream unavailable".utf8))
            default:
                break
            }
        }
        up.start(queue: DispatchQueue.global(qos: .userInitiated))
    }

    private func waitUpstreamHandshake(_ conn: NWConnection, up: NWConnection, accept: String, carried: Data) {
        up.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, error in
            guard let self = self else { up.cancel(); conn.cancel(); return }
            if error != nil || data == nil {
                self.sendResponse(conn, "502 Tunnel", "text/plain; charset=utf-8", Data("no upstream response".utf8))
                up.cancel()
                return
            }
            let text = String(decoding: data!, as: UTF8.self)
            guard text.hasPrefix("HTTP/1.1 101") || text.contains(" 101 ") else {
                let firstLine = text.components(separatedBy: "\r\n").first ?? "?"
                self.sendResponse(conn, "502 Tunnel", "text/plain; charset=utf-8",
                                  Data("upstream refused: \(firstLine)".utf8))
                up.cancel()
                return
            }

            var resp = "HTTP/1.1 101 Switching Protocols\r\n"
            resp += "Upgrade: websocket\r\n"
            resp += "Connection: Upgrade\r\n"
            resp += "Sec-WebSocket-Accept: \(accept)\r\n"
            resp += "\r\n"

            conn.send(content: Data(resp.utf8), completion: .contentProcessed { err in
                if err != nil {
                    up.cancel()
                    conn.cancel()
                    return
                }
                // 握手包里可能已经带了上游的首帧（以及客户端提前发来的字节），先各自转发再开始泵
                if let r = data!.range(of: Data([13, 10, 13, 10])) {
                    let tail = Data(data![r.upperBound...])
                    if !tail.isEmpty { conn.send(content: tail, completion: .contentProcessed { _ in }) }
                }
                if !carried.isEmpty { up.send(content: carried, completion: .contentProcessed { _ in }) }
                self.pump(from: up, to: conn)
                self.pump(from: conn, to: up)
            })
        }
    }

    private func pump(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let d = data, !d.isEmpty {
                to.send(content: d, completion: .contentProcessed { err in
                    if err != nil {
                        from.cancel()
                        to.cancel()
                        return
                    }
                    self.pump(from: from, to: to)
                })
                return
            }
            if error != nil || isComplete {
                from.cancel()
                to.cancel()
            } else {
                self.pump(from: from, to: to)
            }
        }
    }

    private static func accept(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + kWsGuid).utf8))
        return Data(digest).base64EncodedString()
    }

    private static func randomKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }

    // MARK: - 静态文件

    private func contentType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "ico": return "image/x-icon"
        case "m4a", "mp4": return "audio/mp4"
        case "ogg": return "audio/ogg"
        case "txt": return "text/plain; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    private func serveFile(_ conn: NWConnection, target: String, headers: [String: String]) {
        var path = target
        if let q = path.firstIndex(of: "?") { path = String(path[path.startIndex..<q]) }
        if let h = path.firstIndex(of: "#") { path = String(path[path.startIndex..<h]) }
        if path.isEmpty || path == "/" { path = "/index.html" }
        while path.hasPrefix("/") { path.removeFirst() }
        if path.contains("..") {
            sendResponse(conn, "403 Forbidden", "text/plain; charset=utf-8", Data("forbidden".utf8))
            return
        }

        let fileURL = root.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            sendResponse(conn, "404 Not Found", "text/plain; charset=utf-8", Data("404 \(path)".utf8))
            return
        }

        var start = 0
        var end = data.count - 1
        var partial = false
        if let rangeHeader = headers["range"], rangeHeader.hasPrefix("bytes=") {
            let spec = rangeHeader.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if spec.count == 2 {
                if let a = Int(spec[0]) { start = a }
                if let b = Int(spec[1]) { end = min(b, data.count - 1) }
                partial = true
            }
        }

        if partial {
            if start < 0 || start >= data.count || start > end {
                sendResponse(conn, "416 Range Not Satisfiable", "text/plain; charset=utf-8", Data("range".utf8))
                return
            }
            let sub = data.subdata(in: start..<(end + 1))
            let extra = "Content-Range: bytes \(start)-\(end)/\(data.count)\r\n"
            sendResponse(conn, "206 Partial Content", contentType(for: path), sub, extra: extra)
        } else {
            sendResponse(conn, "200 OK", contentType(for: path), data)
        }
    }

    // MARK: - 写响应

    private func sendResponse(_ conn: NWConnection, _ status: String, _ type: String, _ body: Data,
                              extra: String = "") {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += extra
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - 页面

final class ViewController: UIViewController, WKNavigationDelegate {

    private var web: WKWebView!
    private var server: LocalServer?
    private let port: UInt16 = 8720

    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        web = WKWebView(frame: view.bounds, configuration: config)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.isOpaque = false
        web.backgroundColor = .black
        web.navigationDelegate = self
        view.addSubview(web)

        guard let site = Bundle.main.resourceURL?.appendingPathComponent("site") else {
            showError("安装包里没有 site/ 资源")
            return
        }
        let s = LocalServer(root: site, port: port)
        do {
            try s.start()
            server = s
        } catch {
            showError("本地服务启动失败：\(error.localizedDescription)")
            return
        }
        if let url = URL(string: "http://127.0.0.1:\(port)/index.html") {
            web.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError("页面加载失败：\(error.localizedDescription)")
    }

    private func showError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let label = UILabel(frame: self.view.bounds)
            label.text = message
            label.textColor = UIColor(red: 1, green: 0.5, blue: 0.5, alpha: 1)
            label.backgroundColor = .black
            label.numberOfLines = 0
            label.textAlignment = .center
            label.font = UIFont.systemFont(ofSize: 14)
            self.view.addSubview(label)
        }
    }
}

// MARK: - App

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.rootViewController = ViewController()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}
