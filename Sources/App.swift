// YYMC iOS：WKWebView + App 内的回环静态服务
// 页面从 http://127.0.0.1:8720 加载 → 同源 http，fetch / Worker / WebAudio 都正常；不需要 JIT、不碰私有 API。
import UIKit
import WebKit
import Network

// MARK: - 极简静态文件服务器（只读 bundle 里的 site/，支持 Range）

final class LocalServer {

    private let root: URL
    private let port: UInt16
    private var listener: NWListener?
    private(set) var running = false

    init(root: URL, port: UInt16) {
        self.root = root
        self.port = port
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let l = try NWListener(using: .tcp, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: DispatchQueue.global(qos: .userInitiated))
            self?.readHead(conn, buffer: Data())
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.running = true }
        }
        l.start(queue: DispatchQueue.global(qos: .userInitiated))
        listener = l
    }

    private func readHead(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                conn.cancel()
                return
            }
            var buf = buffer
            if let d = data {
                buf.append(d)
            }
            if let sep = buf.range(of: Data([13, 10, 13, 10])) {
                let head = String(decoding: buf[buf.startIndex..<sep.lowerBound], as: UTF8.self)
                self.respond(conn, head: head)
                return
            }
            if error != nil || isComplete || buf.count > 65536 {
                conn.cancel()
                return
            }
            self.readHead(conn, buffer: buf)
        }
    }

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

    private func respond(_ conn: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        if lines.isEmpty {
            conn.cancel()
            return
        }
        let parts = lines[0].split(separator: " ")
        if parts.count < 2 {
            conn.cancel()
            return
        }

        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") {
            path = String(path[path.startIndex..<q])
        }
        if let h = path.firstIndex(of: "#") {
            path = String(path[path.startIndex..<h])
        }
        if path.isEmpty || path == "/" {
            path = "/index.html"
        }
        while path.hasPrefix("/") {
            path.removeFirst()
        }
        if path.contains("..") {
            send(conn, "403 Forbidden", "text/plain; charset=utf-8", Data("forbidden".utf8))
            return
        }

        let fileURL = root.appendingPathComponent(path)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            send(conn, "404 Not Found", "text/plain; charset=utf-8", Data("404 \(path)".utf8))
            return
        }
        if data.isEmpty {
            send(conn, "404 Not Found", "text/plain; charset=utf-8", Data("empty \(path)".utf8))
            return
        }

        var start = 0
        var end = data.count - 1
        var partial = false
        for line in lines.dropFirst() {
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
                send(conn, "416 Range Not Satisfiable", "text/plain; charset=utf-8", Data("range".utf8))
                return
            }
            let sub = data.subdata(in: start..<(end + 1))
            let extra = "Content-Range: bytes \(start)-\(end)/\(data.count)\r\n"
            send(conn, "206 Partial Content", contentType(for: path), sub, extra: extra)
        } else {
            send(conn, "200 OK", contentType(for: path), data)
        }
    }

    private func send(_ conn: NWConnection, _ status: String, _ type: String, _ body: Data, extra: String = "") {
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
        showError("页面加载失败：\(error.localizedDescription)\n确认 site/ 里有 index.html")
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
