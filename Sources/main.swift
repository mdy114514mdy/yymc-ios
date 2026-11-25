// YYMC iOS：WKWebView + App 内回环 HTTP 服务（与安卓版同一思路）
// 页面从 http://127.0.0.1:8720 加载，所以是同源 http，fetch / Worker / WebAudio 都正常。
import UIKit
import WebKit
import Network

// MARK: - 极简静态文件服务器（只读 bundle 里的 site/，支持 Range）

final class LocalServer {

    private let root: URL
    private let port: UInt16
    private var listener: NWListener?

    init(root: URL, port: UInt16) {
        self.root = root
        self.port = port
    }

    func start() throws {
        guard let p = NWEndpoint.Port(rawValue: port) else { return }
        let l = try NWListener(using: .tcp, on: p)
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInitiated))
            self?.readHead(conn, buffer: Data())
        }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }

    private func readHead(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if let r = buf.range(of: Data([13, 10, 13, 10])) {
                let head = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
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

    private func mime(_ path: String) -> String {
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
        guard let first = lines.first else { return conn.cancel() }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return conn.cancel() }

        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[path.startIndex..<q]) }
        if path == "/" || path.isEmpty { path = "/index.html" }
        while path.hasPrefix("/") { path.removeFirst() }
        if path.contains("..") { return send(conn, "403 Forbidden", "text/plain", Data("forbidden".utf8)) }

        let fileURL = root.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: fileURL) else {
            return send(conn, "404 Not Found", "text/plain", Data("404 \(path)".utf8))
        }

        var start = 0
        var end = data.count - 1
        var partial = false
        for l in lines.dropFirst() {
            let low = l.lowercased()
            if low.hasPrefix("range:") {
                let v = l.dropFirst(6).trimmingCharacters(in: .whitespaces)
                if v.hasPrefix("bytes=") {
                    let spec = v.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
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
                return send(conn, "416 Range Not Satisfiable", "text/plain", Data("range".utf8))
            }
            let sub = data.subdata(in: start...(end))
            send(conn, "206 Partial Content", mime(path), sub,
                 extra: "Content-Range: bytes \(start)-\(end)/\(data.count)\r\n")
        } else {
            send(conn, "200 OK", mime(path), data)
        }
    }

    private func send(_ conn: NWConnection, _ status: String, _ type: String, _ body: Data,
                      extra: String = "") {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Cache-Control: \(type.hasPrefix("text/html") ? "no-cache" : "public, max-age=31536000")\r\n"
        head += extra
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

// MARK: - 页面

final class ViewController: UIViewController {

    private var web: WKWebView!
    private var server: LocalServer?
    private let port: UInt16 = 8720

    override var prefersStatusBarHidden: Bool { return true }
    override var prefersHomeIndicatorAutoHidden: Bool { return true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        web = WKWebView(frame: view.bounds, configuration: cfg)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.isOpaque = false
        web.backgroundColor = .black
        view.addSubview(web)

        if let site = Bundle.main.resourceURL?.appendingPathComponent("site") {
            let s = LocalServer(root: site, port: port)
            do {
                try s.start()
                server = s
            } catch {
                showError("本地服务启动失败：\(error)")
            }
        } else {
            showError("安装包内没有 site/ 资源")
        }

        if let url = URL(string: "http://127.0.0.1:\(port)/index.html") {
            web.load(URLRequest(url: url))
        }
    }

    private func showError(_ msg: String) {
        let label = UILabel(frame: view.bounds)
        label.text = msg
        label.textColor = .systemRed
        label.backgroundColor = .black
        label.numberOfLines = 0
        label.textAlignment = .center
        view.addSubview(label)
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
