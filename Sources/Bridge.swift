import UIKit
import WebKit
import AVFoundation
import NaturalLanguage
import Translation
import MediaPlayer
import Speech

/// Messages from the page: window.webkit.messageHandlers.native.postMessage({id, type, data}).
/// Replies go back through window.__nb(id, ok, value).
@MainActor
final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var web: WKWebView?
    let translator: Translator
    let speaker = Speaker()
    let voiceRecorder = VoiceRecorder()

    init(translator: Translator) {
        self.translator = translator
        super.init()
        // Listening goes on with the screen locked: the page is spoken from a native queue and
        // progress is reported back to the page as it plays.
        speaker.onSentence = { [weak self] i in self?.web?.evaluateJavaScript("window.__spk&&window.__spk.onSent(\(i))") }
        speaker.onQueueEnd = { [weak self] done in self?.web?.evaluateJavaScript("window.__spk&&window.__spk.onEnd(\(done))") }
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

        case "saveLessons":
            if let text = body["data"] as? String { Store.saveLessons(text) }

        case "saveGrammar":
            if let text = body["data"] as? String { Store.saveGrammar(text) }

        case "voices":
            reply(id, true, speaker.voices())

        case "lemmas":
            // Dictionary forms for a batch of [word, sentence] pairs, found on the device.
            let items = data["items"] as? [[String]] ?? []
            let found: [String] = items.map { pair in
                Lemma.of(pair.first ?? "", in: pair.count > 1 ? pair[1] : "")
            }
            reply(id, true, found)

        case "speak":
            let text = data["text"] as? String ?? ""
            let rate = (data["rate"] as? NSNumber)?.doubleValue ?? 0.9
            speaker.speak(text: text, rate: rate, voiceId: data["voice"] as? String) { [weak self] finished in
                self?.reply(id, finished, finished ? true : ["code": "cancelled"])
            }

        case "stop":
            speaker.stop()

        case "speakQueue":
            let raw = data["items"] as? [[String: Any]] ?? []
            let items: [(Int, String)] = raw.compactMap { item in
                guard let i = (item["i"] as? NSNumber)?.intValue, let t = item["text"] as? String else { return nil }
                return (i, t)
            }
            speaker.speakQueue(items,
                               rate: (data["rate"] as? NSNumber)?.doubleValue ?? 0.9,
                               voiceId: data["voice"] as? String,
                               repeatEach: (data["repeat"] as? Bool) ?? false,
                               title: data["title"] as? String ?? "Лексика")

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

        // Speaking practice: record an answer, then give back what was said as text.
        case "recStart":
            speaker.stop()
            Task { @MainActor in
                do {
                    try await self.voiceRecorder.start()
                    self.reply(id, true, ["ok": true])
                } catch {
                    self.reply(id, false, ["code": "rec_failed", "message": error.localizedDescription])
                }
            }

        case "recStop":
            Task { @MainActor in
                let r = await self.voiceRecorder.stop()
                self.reply(id, true, ["text": r.text, "seconds": r.seconds])
            }

        case "recPlay":
            voiceRecorder.play()
            reply(id, true, ["ok": true])

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

        case "claude":
            let prompt = data["prompt"] as? String ?? ""
            let shortcut = data["shortcut"] as? String ?? "Лексика Claude"
            Task { @MainActor in self.askClaude(id: id, prompt: prompt, shortcut: shortcut) }

        case "share":
            share(filename: data["filename"] as? String ?? "leksika.txt",
                  text: data["data"] as? String ?? "", id: id)

        default:
            reply(id, false, ["code": "unknown"])
        }
    }

    // MARK: Claude through the Shortcuts app
    //
    // The app runs the user's shortcut (an "Ask Claude" action followed by "Stop and Output") with the prompt
    // as its input. Shortcuts opens leksika://claude/ok?id=…&result=… when it finishes; the answer counts
    // towards the user's own Claude plan.

    private static let strict: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Bridge.strict) ?? ""
    }

    @MainActor
    private func askClaude(id: Int, prompt: String, shortcut: String) {
        let back = "leksika://claude"
        let parts = [
            "name=" + encode(shortcut),
            "input=text",
            "text=" + encode(prompt),
            "x-success=" + encode("\(back)/ok?id=\(id)"),
            "x-error=" + encode("\(back)/error?id=\(id)"),
            "x-cancel=" + encode("\(back)/cancel?id=\(id)"),
        ]
        guard let url = URL(string: "shortcuts://x-callback-url/run-shortcut?" + parts.joined(separator: "&")) else {
            reply(id, false, ["code": "bad_prompt"])
            return
        }
        UIApplication.shared.open(url) { [weak self] opened in
            if !opened { self?.reply(id, false, ["code": "no_shortcuts"]) }
        }
    }

    @MainActor
    func handleOpen(_ url: URL) {
        guard url.scheme == "leksika", url.host == "claude",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = Int(items.first(where: { $0.name == "id" })?.value ?? "") else { return }
        let value = { (name: String) in items.first(where: { $0.name == name })?.value ?? "" }
        switch url.path {
        case "/ok":
            let answer = value("result")
            if answer.isEmpty {
                reply(id, false, ["code": "empty"])
            } else {
                reply(id, true, answer)
            }
        case "/cancel":
            reply(id, false, ["code": "cancelled_shortcut"])
        default:
            reply(id, false, ["code": "shortcut_error", "message": value("errorMessage")])
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
        let pos = isPhrase ? "" : WordClass.of(text, in: context)
        // The same word in the same role is answered from the cache: no network, works offline.
        let cacheKey = (isPhrase ? "p|" : "w|") + text.lowercased() + "|" + pos
        if let hit = TranslationCache.shared.get(cacheKey), let tr = hit["tr"], !tr.isEmpty {
            return ["tr": tr, "lemma": hit["lemma"] ?? lemma, "pos": pos, "ipa": hit["ipa"] ?? "", "note": ""]
        }

        var a: String?
        var g: GoogleResult?
        if isPhrase {
            // A phrase needs one translation: the on-device one first, the network only if it fails.
            a = try? await withTimeout(4) { try await self.translator.translate(text) }
            if (a ?? "").isEmpty { g = try? await Google.translate(text, dictionary: false) }
        } else {
            // A single word needs dictionary meanings by part of speech, which only the online
            // dictionary gives, so both are asked at once.
            async let apple: String? = try? await withTimeout(4) { try await self.translator.translate(text) }
            async let google: GoogleResult? = try? await Google.translate(text, dictionary: true)
            a = await apple
            g = await google
        }

        // Dictionary meanings of the same part of speech as in the sentence come first,
        // so a verb in the text is not explained with adjectives and nouns.
        var ordered: [String] = []
        if !pos.isEmpty, let entry = g?.byPos.first(where: { $0.pos == pos }) {
            ordered.append(contentsOf: entry.terms.prefix(3))
        }
        if ordered.isEmpty {
            ordered = [a, g?.main].compactMap { $0 }
            if !isPhrase { ordered.append(contentsOf: g?.alternatives ?? []) }
        }
        // A phrase gets one translation: two machine versions of the same phrase are noise.
        let limit = isPhrase ? 1 : 3
        var options: [String] = []
        var seen = Set<String>()
        for candidate in ordered {
            let t = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = t.lowercased()
            if t.isEmpty || seen.contains(key) || key == text.lowercased() { continue }
            seen.insert(key)
            options.append(t)
            if options.count == limit { break }
        }
        if options.isEmpty { throw TranslateFailure(reason: await Self.failureReason()) }
        let ipa = isPhrase ? "" : await self.transcription(of: lemma.isEmpty ? text : lemma)
        let tr = options.joined(separator: ", ")
        // Cached only when the dictionary answered (or for phrases), so an offline one-word
        // fallback is not kept forever in place of the fuller dictionary entry.
        if isPhrase || g != nil {
            TranslationCache.shared.set(cacheKey, ["tr": tr, "lemma": lemma, "ipa": ipa])
        }
        return ["tr": tr, "lemma": lemma, "pos": pos, "ipa": ipa, "note": ""]
    }

    /// Transcription is looked up once per word and then kept.
    private func transcription(of word: String) async -> String {
        let key = "i|" + word.lowercased()
        if let hit = TranslationCache.shared.get(key)?["ipa"] { return hit }
        guard let ipa = try? await withTimeout(3, { try await Phonetics.of(word) }) else { return "" }
        TranslationCache.shared.set(key, ["ipa": ipa])
        return ipa
    }

    private func translateSentence(_ text: String) async throws -> String {
        if let a = try? await withTimeout(10, { try await self.translator.translate(text) }), !a.isEmpty {
            return a
        }
        do {
            let g = try await Google.translate(text, dictionary: false)
            return g.main
        } catch {
            throw TranslateFailure(reason: await Self.failureReason())
        }
    }

    /// Why nothing could be translated, in words the reader can act on.
    private static func failureReason() async -> String {
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "ru"))
        switch status {
        case .installed:
            return "Не получилось перевести. Попробуй ещё раз."
        case .supported:
            return "Нет интернета, а офлайн-перевод ещё не загружен. Подключись к сети или скачай языки English и Russian в приложении «Перевод» (Настройки → Перевод → Загруженные языки)."
        default:
            return "Офлайн-перевод с английского на русский на этом устройстве недоступен, а интернета нет. Подключись к сети."
        }
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
    /// Utterances of the current page queue and the sentence index each one belongs to.
    private var queued: [ObjectIdentifier: Int] = [:]
    private var lastOfQueue: ObjectIdentifier?
    var onSentence: ((Int) -> Void)?
    var onQueueEnd: ((Bool) -> Void)?

    override init() {
        super.init()
        synth.delegate = self
        let center = MPRemoteCommandCenter.shared()
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.synth.isSpeaking else { return .commandFailed }
            self.synth.pauseSpeaking(at: .word)
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            guard let self, self.synth.isPaused else { return .commandFailed }
            self.synth.continueSpeaking()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.synth.isPaused { self.synth.continueSpeaking() } else if self.synth.isSpeaking { self.synth.pauseSpeaking(at: .word) } else { return .commandFailed }
            return .success
        }
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

    private func utterance(_ text: String, rate: Double, voiceId: String?) -> AVSpeechUtterance {
        let u = AVSpeechUtterance(string: text)
        let r = AVSpeechUtteranceDefaultSpeechRate * Float(rate)
        u.rate = min(max(r, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        if let id = voiceId, let v = AVSpeechSynthesisVoice(identifier: id) {
            u.voice = v
        } else {
            u.voice = AVSpeechSynthesisVoice(language: "en-US")
        }
        return u
    }

    /// Speaks the rest of a page as one queue. With repeatEach every sentence is said, a pause is left
    /// to repeat it aloud, and it is said again (shadowing).
    func speakQueue(_ items: [(Int, String)], rate: Double, voiceId: String?, repeatEach: Bool, title: String) {
        if synth.isSpeaking || synth.isPaused { synth.stopSpeaking(at: .immediate) }
        queued.removeAll()
        lastOfQueue = nil
        guard !items.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title,
                                                           MPMediaItemPropertyArtist: "Лексика"]
        for (i, text) in items {
            let first = utterance(text, rate: rate, voiceId: voiceId)
            let words = Double(text.split(separator: " ").count)
            let gap = min(6.0, 1.2 + words * 0.45)
            queued[ObjectIdentifier(first)] = i
            if repeatEach {
                first.postUtteranceDelay = gap
                let second = utterance(text, rate: rate, voiceId: voiceId)
                second.postUtteranceDelay = gap
                queued[ObjectIdentifier(second)] = i
                synth.speak(first)
                synth.speak(second)
                lastOfQueue = ObjectIdentifier(second)
            } else {
                synth.speak(first)
                lastOfQueue = ObjectIdentifier(first)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let i = self.queued[key] { self.onSentence?(i) }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.callbacks.removeValue(forKey: key)?(true)
            if self.queued.removeValue(forKey: key) != nil, key == self.lastOfQueue {
                self.lastOfQueue = nil
                self.onQueueEnd?(true)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.callbacks.removeValue(forKey: key)?(false)
            if self.queued.removeValue(forKey: key) != nil, self.lastOfQueue != nil {
                self.lastOfQueue = nil
                self.queued.removeAll()
                self.onQueueEnd?(false)
            }
        }
    }
}

// MARK: - Speaking practice (recording + speech-to-text)

@MainActor
final class VoiceRecorder {
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("speaking.m4a")

    func start() async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw TranslateFailure(reason: "Нет доступа к микрофону. Разреши его: Настройки → Лексика → Микрофон.")
        }
        player?.stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        guard rec.record() else {
            throw TranslateFailure(reason: "Не получилось начать запись.")
        }
        recorder = rec
    }

    func stop() async -> (text: String, seconds: Double) {
        guard let rec = recorder else { return ("", 0) }
        let seconds = rec.currentTime
        rec.stop()
        recorder = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        let file = url
        let text = (try? await withTimeout(45) { await Transcriber.text(of: file) }) ?? ""
        return (text, seconds)
    }

    func play() {
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }
}

/// Used so a recognition callback that fires twice resumes the waiting task only once.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

enum Transcriber {
    static func authorized() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                c.resume(returning: status == .authorized)
            }
        }
    }

    /// English text of the recording; empty when recognition is unavailable or not allowed.
    static func text(of url: URL) async -> String {
        guard await authorized(),
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { return "" }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        // On the phone itself there is no one-minute limit, and it works offline.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        let once = ResumeOnce()
        let text = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if once.claim() { c.resume(returning: result.bestTranscription.formattedString) }
                } else if error != nil {
                    if once.claim() { c.resume(returning: "") }
                }
            }
        }
        withExtendedLifetime(recognizer) {}
        return text
    }
}

// MARK: - Translation cache

struct TranslateFailure: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

/// Translations and transcriptions already looked up, kept between launches.
@MainActor
final class TranslationCache {
    static let shared = TranslationCache()
    private var map: [String: [String: String]] = [:]
    private let url: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("translations.json")
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
            map = saved
        }
    }

    func get(_ key: String) -> [String: String]? { map[key] }

    func set(_ key: String, _ value: [String: String]) {
        if map.count > 20000 { map.removeAll() }
        map[key] = value
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if let data = try? JSONSerialization.data(withJSONObject: self.map) {
                try? data.write(to: self.url, options: .atomic)
            }
        }
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

struct PosTerms: Sendable {
    let pos: String
    let terms: [String]
}

struct GoogleResult: Sendable {
    let main: String
    let alternatives: [String]
    let byPos: [PosTerms]
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
        var byPos: [PosTerms] = []
        if dictionary, arr.count > 1, let entries = arr[1] as? [Any] {
            for e in entries {
                if let e = e as? [Any], e.count > 1, let terms = e[1] as? [String] {
                    alts.append(contentsOf: terms.prefix(3))
                    if let name = e[0] as? String {
                        byPos.append(PosTerms(pos: name.lowercased(), terms: terms))
                    }
                }
            }
        }
        if main.isEmpty && alts.isEmpty { throw URLError(.cannotParseResponse) }
        return GoogleResult(main: main, alternatives: alts, byPos: byPos)
    }
}

// MARK: - Pronunciation (free dictionary)

enum Phonetics {
    static func of(_ word: String) async throws -> String {
        let w = word.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? word
        guard let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(w)") else { return "" }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return "" }
        for entry in entries {
            if let p = entry["phonetic"] as? String, !p.isEmpty { return p.trimmingCharacters(in: CharacterSet(charactersIn: "/[] ")) }
            for ph in entry["phonetics"] as? [[String: Any]] ?? [] {
                if let p = ph["text"] as? String, !p.isEmpty { return p.trimmingCharacters(in: CharacterSet(charactersIn: "/[] ")) }
            }
        }
        return ""
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

// MARK: - Part of speech in context (on-device)

enum WordClass {
    /// "noun", "verb", "adjective", "adverb", or "" when the tagger is not sure.
    static func of(_ word: String, in context: String) -> String {
        let source = context.isEmpty ? word : context
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = source
        var result = ""
        tagger.enumerateTags(in: source.startIndex..<source.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            if source[range].lowercased() == word.lowercased() {
                if tag == NLTag.noun { result = "noun" }
                else if tag == NLTag.verb { result = "verb" }
                else if tag == NLTag.adjective { result = "adjective" }
                else if tag == NLTag.adverb { result = "adverb" }
                return false
            }
            return true
        }
        return result
    }
}

// MARK: - Helpers

/// Returns the operation's result, or throws `.timedOut` after `seconds`, whichever comes first.
/// It does not wait for a stuck operation to finish (a task group would), so callers can fall back.
func withTimeout<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = OnceGate<T>()
    return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
        gate.arm(c)
        Task {
            do { gate.finish(.success(try await operation())) } catch { gate.finish(.failure(error)) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            gate.finish(.failure(URLError(.timedOut)))
        }
    }
}

/// Resumes a continuation exactly once; later results are dropped.
final class OnceGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func arm(_ c: CheckedContinuation<T, Error>) {
        lock.lock(); continuation = c; lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
