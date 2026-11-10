import UIKit
import WebKit
import AVFoundation
import NaturalLanguage
import Translation

/// Messages from the page: window.webkit.messageHandlers.native.postMessage({id, type, data}).
/// Replies go back through window.__nb(id, ok, value).
@MainActor
final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var web: WKWebView?
    let translator: Translator
    let speaker = Speaker()

    init(translator: Translator) {
        self.translator = translator
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let id = (body["id"] as? NSNumber)?.intValue ?? 0
        let data = body["data"] as? [String: Any] ?? [:]

        switch type {
        case "save":
            if let text = body["data"] as? String { Store.save(text) }

        case "voices":
            reply(id, true, speaker.voices())

        case "speak":
            let text = data["text"] as? String ?? ""
            let rate = (data["rate"] as? NSNumber)?.doubleValue ?? 0.9
            speaker.speak(text: text, rate: rate, voiceId: data["voice"] as? String) { [weak self] finished in
                self?.reply(id, finished, finished ? true : ["code": "cancelled"])
            }

        case "stop":
            speaker.stop()

        case "translate":
            let text = data["text"] as? String ?? ""
            let ctx = data["ctx"] as? String ?? ""
            let isPhrase = (data["isPhrase"] as? Bool) ?? false
            Task { @MainActor in
                do {
                    let result = try await self.translateWord(text, context: ctx, isPhrase: isPhrase)
                    self.reply(id, true, result)
                } catch {
                    self.reply(id, false, ["code": "translate_failed", "message": error.localizedDescription])
                }
            }

        case "translateSentence":
            let text = data["text"] as? String ?? ""
            Task { @MainActor in
                do {
                    let tr = try await self.translateSentence(text)
                    self.reply(id, true, ["tr": tr])
                } catch {
                    self.reply(id, false, ["code": "translate_failed", "message": error.localizedDescription])
                }
            }

        case "share":
            share(filename: data["filename"] as? String ?? "leksika.txt",
                  text: data["data"] as? String ?? "", id: id)

        default:
            reply(id, false, ["code": "unknown"])
        }
    }

    private func reply(_ id: Int, _ ok: Bool, _ value: Any) {
        guard id != 0 else { return }
        let payload = (try? JSONSerialization.data(withJSONObject: ["v": value]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"v\":null}"
        web?.evaluateJavaScript("window.__nb(\(id),\(ok ? "true" : "false"),(\(payload)).v)")
    }

    // MARK: Translation

    private func translateWord(_ text: String, context: String, isPhrase: Bool) async throws -> [String: Any] {
        let lemma = isPhrase ? "" : Lemma.of(text, in: context)
        async let apple: String? = try? await withTimeout(8) { try await self.translator.translate(text) }
        async let google: GoogleResult? = try? await Google.translate(text, dictionary: !isPhrase)
        let a = await apple
        let g = await google

        var options: [String] = []
        var seen = Set<String>()
        for candidate in [a, g?.main].compactMap({ $0 }) + (g?.alternatives ?? []) {
            let t = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = t.lowercased()
            if t.isEmpty || seen.contains(key) || key == text.lowercased() { continue }
            seen.insert(key)
            options.append(t)
            if options.count == 3 { break }
        }
        if options.isEmpty { throw URLError(.cannotParseResponse) }
        return ["tr": options.joined(separator: ", "), "lemma": lemma, "ipa": "", "note": ""]
    }

    private func translateSentence(_ text: String) async throws -> String {
        if let a = try? await withTimeout(10, { try await self.translator.translate(text) }), !a.isEmpty {
            return a
        }
        let g = try await Google.translate(text, dictionary: false)
        return g.main
    }

    // MARK: Share / save files

    private func share(filename: String, text: String, id: Int) {
        let safeName = filename.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do { try text.data(using: .utf8)?.write(to: url, options: .atomic) } catch {
            reply(id, false, ["code": "write_failed"]); return
        }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.completionWithItemsHandler = { [weak self] _, completed, _, _ in
            self?.reply(id, completed, completed ? true : ["code": "declined"])
        }
        if let pop = vc.popoverPresentationController, let w = web {
            pop.sourceView = w
            pop.sourceRect = CGRect(x: w.bounds.midX, y: w.bounds.midY, width: 1, height: 1)
        }
        topViewController()?.present(vc, animated: true)
    }

    private func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.rootViewController
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    // MARK: Links open in Safari

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        if ["app", "about", "blob", "data"].contains(url.scheme ?? "") { return .allow }
        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            await UIApplication.shared.open(url)
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { UIApplication.shared.open(url) }
        return nil
    }
}

// MARK: - Speech (uses every installed voice, including Premium / Enhanced)

@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var callbacks: [ObjectIdentifier: (Bool) -> Void] = [:]

    override init() {
        super.init()
        synth.delegate = self
        // .playback lets speech play even when the silent switch is on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    func voices() -> [[String: Any]] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .map { v in
                let q: Int
                switch v.quality {
                case .premium: q = 3
                case .enhanced: q = 2
                default: q = 0
                }
                return ["id": v.identifier, "name": v.name, "lang": v.language, "q": q]
            }
    }

    func speak(text: String, rate: Double, voiceId: String?, done: @escaping (Bool) -> Void) {
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        let r = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
        u.rate = min(max(r, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        if let id = voiceId, let v = AVSpeechSynthesisVoice(identifier: id) {
            u.voice = v
        } else {
            u.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        callbacks[ObjectIdentifier(u)] = done
        synth.speak(u)
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.callbacks.removeValue(forKey: key)?(true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.callbacks.removeValue(forKey: key)?(false) }
    }
}

// MARK: - On-device translation (Apple Translation framework)

@MainActor
final class Translator {
    let configuration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "ru"))

    struct Job {
        let text: String
        let done: (Result<String, Error>) -> Void
    }

    private var continuation: AsyncStream<Job>.Continuation?
    private var queued: [Job] = []

    func translate(_ text: String) async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            let job = Job(text: text) { c.resume(with: $0) }
            if let continuation { continuation.yield(job) } else { queued.append(job) }
        }
    }

    /// Called from .translationTask; processes jobs for as long as the session lives.
    func run(session: TranslationSession) async {
        let (stream, cont) = AsyncStream.makeStream(of: Job.self)
        continuation = cont
        for job in queued { cont.yield(job) }
        queued.removeAll()
        for await job in stream {
            do {
                let response = try await session.translate(job.text)
                job.done(.success(response.targetText))
            } catch {
                job.done(.failure(error))
            }
        }
        continuation = nil
    }
}

// MARK: - Online dictionary alternatives (fallback / extra meanings)

struct GoogleResult: Sendable {
    let main: String
    let alternatives: [String]
}

enum Google {
    static func translate(_ text: String, dictionary: Bool) async throws -> GoogleResult {
        var c = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        var items = [URLQueryItem(name: "client", value: "gtx"),
                     URLQueryItem(name: "sl", value: "en"),
                     URLQueryItem(name: "tl", value: "ru"),
                     URLQueryItem(name: "dt", value: "t")]
        if dictionary { items.append(URLQueryItem(name: "dt", value: "bd")) }
        items.append(URLQueryItem(name: "q", value: text))
        c.queryItems = items
        var req = URLRequest(url: c.url!)
        req.timeoutInterval = 6
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw URLError(.cannotParseResponse)
        }
        let main = ((arr.first as? [Any]) ?? [])
            .compactMap { ($0 as? [Any])?.first as? String }
            .joined()
        var alts: [String] = []
        if dictionary, arr.count > 1, let entries = arr[1] as? [Any] {
            for e in entries {
                if let e = e as? [Any], e.count > 1, let terms = e[1] as? [String] {
                    alts.append(contentsOf: terms.prefix(3))
                }
            }
        }
        if main.isEmpty && alts.isEmpty { throw URLError(.cannotParseResponse) }
        return GoogleResult(main: main, alternatives: alts)
    }
}

// MARK: - Dictionary form (on-device)

enum Lemma {
    static func of(_ word: String, in context: String) -> String {
        let source = context.isEmpty ? word : context
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = source
        var result = ""
        tagger.enumerateTags(in: source.startIndex..<source.endIndex, unit: .word, scheme: .lemma,
                             options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            if source[range].lowercased() == word.lowercased() {
                result = tag?.rawValue ?? ""
                return false
            }
            return true
        }
        if result.isEmpty && !context.isEmpty { return of(word, in: "") }
        return result.lowercased()
    }
}

// MARK: - Helpers

func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw URLError(.timedOut) }
        return first
    }
}
