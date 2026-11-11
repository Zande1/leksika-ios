import SwiftUI
import WebKit
import Translation

@main
struct LeksikaApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Shared objects that live for the whole app run.
@MainActor
final class AppModel {
    static let shared = AppModel()
    let translator = Translator()
    lazy var bridge = Bridge(translator: translator)
}

struct RootView: View {
    private var model: AppModel { AppModel.shared }

    var body: some View {
        WebView(bridge: model.bridge)
            .ignoresSafeArea()
            .background(Color(uiColor: .systemBackground))
            // Keeps one on-device EN→RU translation session alive for the bridge.
            .translationTask(model.translator.configuration) { session in
                await AppModel.shared.translator.run(session: session)
            }
    }
}

struct WebView: UIViewRepresentable {
    let bridge: Bridge

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalSchemeHandler(), forURLScheme: "app")
        config.allowsInlineMediaPlayback = true

        let controller = WKUserContentController()
        controller.add(bridge, name: "native")
        Store.keepLegacyCopyIfNeeded()
        let initial = Store.loadValidJSON() ?? "null"
        let lessons = Store.loadLessonsJSON() ?? "null"
        let grammar = Store.loadGrammarJSON() ?? "null"
        controller.addUserScript(WKUserScript(
            source: "window.__NATIVE_DATA=\(initial);window.__NATIVE_LESSONS=\(lessons);window.__NATIVE_GRAMMAR=\(grammar);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true))
        config.userContentController = controller

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = bridge
        web.uiDelegate = bridge
        web.allowsLinkPreview = false
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        web.scrollView.backgroundColor = .systemBackground
        web.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) { web.isInspectable = true }
        bridge.web = web
        web.load(URLRequest(url: URL(string: "app://local/index.html")!))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Serves the bundled web app from the "web" folder under a stable origin (app://local).
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let base = Bundle.main.resourceURL!.appendingPathComponent("web")
        let file = base.appendingPathComponent(String(path.dropFirst()))
        guard file.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime: String
        switch file.pathExtension.lowercased() {
        case "html": mime = "text/html"
        case "js": mime = "text/javascript"
        case "css": mime = "text/css"
        case "json": mime = "application/json"
        case "png": mime = "image/png"
        case "svg": mime = "image/svg+xml"
        default: mime = "application/octet-stream"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "\(mime); charset=utf-8",
                                                      "Cache-Control": "no-cache"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// App data lives in Documents (visible in the Files app):
/// leksika.json — words, progress and stats; leksika.lessons.json — lesson texts,
/// kept apart so that marking a word does not rewrite every text.
enum Store {
    private static let queue = DispatchQueue(label: "leksika.store")
    private static var backedUp = false

    static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("leksika.json")
    }
    static var prevURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("leksika.prev.json")
    }

    static var lessonsURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("leksika.lessons.json")
    }
    /// One-time copy of the old single-file format, made before lessons are split out.
    static var legacyURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("leksika.backup-v1.json")
    }

    static func keepLegacyCopyIfNeeded() {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: lessonsURL.path),
           !fm.fileExists(atPath: legacyURL.path) {
            try? fm.copyItem(at: url, to: legacyURL)
        }
    }

    /// Grammar trainer progress (grammar.html), separate from the reader's data.
    static var grammarURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("leksika.grammar.json")
    }

    static func loadGrammarJSON() -> String? {
        guard let data = try? Data(contentsOf: grammarURL), isValid(data) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveGrammar(_ text: String) {
        queue.async {
            guard let data = text.data(using: .utf8), isValid(data) else { return }
            try? data.write(to: grammarURL, options: .atomic)
        }
    }

    static func loadLessonsJSON() -> String? {
        guard let data = try? Data(contentsOf: lessonsURL), isValid(data) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveLessons(_ text: String) {
        queue.async {
            guard let data = text.data(using: .utf8), isValid(data) else { return }
            try? data.write(to: lessonsURL, options: .atomic)
        }
    }

    private static func isValid(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
    }

    /// Returns the saved JSON text, falling back to the previous copy if the main file is damaged.
    static func loadValidJSON() -> String? {
        for candidate in [url, prevURL] {
            if let data = try? Data(contentsOf: candidate), isValid(data),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    static func save(_ text: String) {
        queue.async {
            guard let data = text.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            let fm = FileManager.default
            // Never replace a file that still holds the lesson texts before they are saved separately.
            if object["lessons"] == nil, !fm.fileExists(atPath: lessonsURL.path) { return }
            if !backedUp, fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: prevURL)
                try? fm.copyItem(at: url, to: prevURL)
                backedUp = true
            }
            try? data.write(to: url, options: .atomic)
        }
    }
}
