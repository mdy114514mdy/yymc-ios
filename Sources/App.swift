// YYMC iOS：WKWebView + App 内的回环服务（静态文件 + /rooms 反代 + /rooms/p2p 的 WebSocket 隧道）
// 页面从 http://127.0.0.1:8720 加载 → 同源 http，fetch / Worker / WebAudio 都正常；不需要 JIT、不碰私有 API。
//
// 为什么要这层反代：官方房间服务只认 Origin: https://www.bilibili.com，
// 而 Origin 是浏览器的 forbidden header，页面 JS 改不了，所以必须由 App 在浏览器之外补上。
// 全流程都在设备内完成，不依赖任何云端中转。
import UIKit
import WebKit
import Network

// MARK: - 回环服务

final class LocalServer {

    private let root: URL
    private let port: UInt16
    private var listener: NWListener?

    private let upstreamHost = "xz.honghemc.cn"
    private let upstreamPort: UInt16 = 8443
    private let upOrigin = "https://www.bilibili.com"

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

    // MARK: 读请求头 + body

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                conn.cancel()
                return
            }
            var buf = buffer
            if let d = data {
                buf.append(d)
            }

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

            var contentLength = 0
            for line in lines.dropFirst() {
                if line.lowercased().hasPrefix("content-length:") {
                    contentLength = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }

            let afterHead = buf[sep.upperBound...]
            if afterHead.count < contentLength {
                if error != nil || isComplete {
                    conn.cancel()
                } else {
                    self.readRequest(conn, buffer: buf)
                }
                return
            }
            let needed = min(contentLength, afterHead.count)
            let body = needed > 0 ? Data(afterHead.prefix(needed)) : Data()

            self.dispatch(conn, method: method, target: target, body: body, headers: lines)
        }
    }

    private func dispatch(_ conn: NWConnection, method: String, target: String, body: Data,
                          headers: [String]) {
        var path = target
        if let q = path.firstIndex(of: "?") {
            path = String(path[path.startIndex..<q])
        }

        if path.hasPrefix("/rooms/p2p") {
            rejectTunnel(conn)
            return
        }
        if path.hasPrefix("/rooms/") {
            proxyHTTP(conn, method: method, fullTarget: target, body: body)
            return
        }
        serveFile(conn, target: target, method: method, headers: headers)
    }

    // MARK: /rooms/api/* 反代（URLSession，补 Origin）

    private func proxyHTTP(_ conn: NWConnection, method: String, fullTarget: String, body: Data) {
        let upstreamPath = String(fullTarget.dropFirst("/rooms".count))
        guard let url = URL(string: "https://\(upstreamHost):\(upstreamPort)\(upstreamPath)") else {
            sendResponse(conn, "400 Bad Request", "text/plain; charset=utf-8", Data("bad url".utf8))
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue(upOrigin, forHTTPHeaderField: "Origin")
        req.setValue(upOrigin + "/", forHTTPHeaderField: "Referer")
        req.setValue("YYMC-iOS", forHTTPHeaderField: "User-Agent")
        if !body.isEmpty {
            req.httpBody = body
            req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        }

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else {
                conn.cancel()
                return
            }
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

    // MARK: /rooms/p2p —— 这一版还没做 WebSocket 隧道，明确回 501，别让客户端以为网络挂了
    private func rejectTunnel(_ conn: NWConnection) {
        let msg = "{\"error\":\"联机信令需要 WebSocket 隧道，这一版还没实现（登录/云存档可用）\"}"
        sendResponse(conn, "501 Not Implemented", "application/json; charset=utf-8", Data(msg.utf8))
    }

    // MARK: 静态文件

    private func contentType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
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

    private func serveFile(_ conn: NWConnection, target: String, method: String, headers: [String]) {
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
        for line in headers {
            if line.lowercased().hasPrefix("range:") {
                let value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("bytes=") {
                    let spec = value.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                    if spec.count == 2 {
                        if let a = Int(spec[0]) { start = a }
                        if let b = Int(spec[1]) { end = min(b, data.count - 1) }
                        partial = true
                    }
                }
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

    // MARK: 写响应

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
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
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
