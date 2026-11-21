import AppKit
import ApplicationServices
import Combine
import NaturalLanguage
import SwiftUI
import Translation

struct LanguagePair: Hashable {
    let sourceID: String
    let targetID: String

    var source: Locale.Language { Locale.Language(identifier: sourceID) }
    var target: Locale.Language { Locale.Language(identifier: targetID) }
}

@MainActor
final class HoverTranslator: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsAccessibility = false
    @Published private(set) var needsScreenCapture = false
    @Published private(set) var targetLanguageID = UserDefaults.standard.string(forKey: "targetLanguage") ?? "ru"
    @Published private(set) var targetLanguages: [String] = []
    @Published private(set) var missingLanguages: LanguagePair?

    private struct Cursor {
        let location: CGPoint
        let display: CGRect
        let desktopTop: CGFloat
        let visibleFrame: CGRect

        static func current() -> Cursor? {
            let location = NSEvent.mouseLocation
            let screens = NSScreen.screens
            guard let primary = screens.first, let screen = screens.first(where: { $0.frame.contains(location) }) else {
                return nil
            }
            let desktopTop = primary.frame.maxY
            let frame = screen.frame
            return Cursor(
                location: CGPoint(x: location.x, y: desktopTop - location.y),
                display: CGRect(x: frame.minX, y: desktopTop - frame.maxY, width: frame.width, height: frame.height),
                desktopTop: desktopTop,
                visibleFrame: screen.visibleFrame
            )
        }
    }

    private struct CacheKey: Hashable {
        let word: String
        let pair: LanguagePair
    }

    private let lookup = WordLookup()
    private let tooltip = TooltipPanel()
    private let languageAvailability = LanguageAvailability()
    private var translationCache: [CacheKey: String] = [:]
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var hoverTask: Task<Void, Never>?
    private var hoverID: UUID?
    private var anchor: CGPoint?
    private var hoveredWord: HoverWord?
    private var downloadWindow: NSWindow?

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            needsAccessibility = !AXIsProcessTrustedWithOptions(options)
            guard !needsAccessibility else { return }
            isEnabled = true
            startMonitoring()
        } else {
            isEnabled = false
            stopMonitoring()
            needsScreenCapture = false
            missingLanguages = nil
            downloadWindow?.close()
        }
    }

    func loadLanguages() async {
        guard targetLanguages.isEmpty else { return }
        let languages = await languageAvailability.supportedLanguages
        guard !Task.isCancelled else { return }
        targetLanguages = Set(languages.map(\.minimalIdentifier)).sorted {
            languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending
        }
        if !targetLanguages.contains(targetLanguageID),
           let fallback = targetLanguages.contains("ru") ? "ru" : targetLanguages.first {
            setTargetLanguage(fallback)
        }
    }

    func languageName(_ id: String) -> String {
        Locale(identifier: "ru").localizedString(forIdentifier: id) ?? id
    }

    func setTargetLanguage(_ id: String) {
        guard id != targetLanguageID else { return }
        targetLanguageID = id
        UserDefaults.standard.set(id, forKey: "targetLanguage")
        missingLanguages = nil
        cancelHover()
        downloadWindow?.close()
    }

    func requestScreenCapture() {
        cancelHover()
        needsScreenCapture = !CGRequestScreenCaptureAccess()
    }

    func downloadLanguages() {
        guard let pair = missingLanguages else { return }
        cancelHover()
        downloadWindow?.close()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 125),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Языки перевода"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: LanguageDownloadView(
            pair: pair,
            title: "\(languageName(pair.sourceID)) → \(languageName(pair.targetID))"
        ) { [weak self, weak window] in
            if self?.missingLanguages == pair {
                self?.missingLanguages = nil
            }
            window?.close()
        })
        downloadWindow = window
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === downloadWindow {
            downloadWindow = nil
        }
    }

    private func startMonitoring() {
        let events: NSEvent.EventTypeMask = [
            .mouseMoved, .scrollWheel,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseUp, .rightMouseUp, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
        ]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            self?.handle(event)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.cancelHover()
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelHover()
            }
        }
    }

    private func stopMonitoring() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        activationObserver = nil
        cancelHover()
    }

    private func handle(_ event: NSEvent) {
        guard isEnabled, let cursor = Cursor.current() else {
            cancelHover()
            return
        }
        switch event.type {
        case .mouseMoved:
            if let hoveredWord {
                guard !hoveredWord.bounds.contains(cursor.location) else { return }
            } else if let anchor {
                guard hypot(cursor.location.x - anchor.x, cursor.location.y - anchor.y) > 3 else { return }
            }
            waitForHover(at: cursor.location)
        case .scrollWheel, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            waitForHover(at: cursor.location)
        default:
            cancelHover()
        }
    }

    private func waitForHover(at point: CGPoint) {
        cancelHover()
        anchor = point
        let id = UUID()
        hoverID = id
        hoverTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            await self?.findWord(for: id, anchor: point)
        }
    }

    private func cancelHover() {
        hoverID = nil
        anchor = nil
        hoveredWord = nil
        hoverTask?.cancel()
        hoverTask = nil
        tooltip.hide()
    }

    private func findWord(for id: UUID, anchor: CGPoint) async {
        guard isEnabled, hoverID == id, !Task.isCancelled, let cursor = Cursor.current(),
              hypot(cursor.location.x - anchor.x, cursor.location.y - anchor.y) <= 3 else { return }
        guard AXIsProcessTrusted() else {
            setEnabled(false)
            needsAccessibility = true
            return
        }

        let result = await lookup.word(at: cursor.location, on: cursor.display)
        guard hoverID == id, !Task.isCancelled else { return }
        if needsScreenCapture, CGPreflightScreenCaptureAccess() {
            needsScreenCapture = false
        }
        switch result {
        case .word(let word):
            guard Cursor.current().map({ word.bounds.contains($0.location) }) == true else { return }
            hoveredWord = word
            await translate(word, for: id)
        case .screenCaptureUnavailable:
            needsScreenCapture = true
        case .noWord:
            break
        }
    }

    private func translate(_ word: HoverWord, for id: UUID) async {
        guard let source = NLLanguageRecognizer.dominantLanguage(for: word.context)
            ?? NLLanguageRecognizer.dominantLanguage(for: word.text) else { return }
        let sourceID = Locale.Language(identifier: source.rawValue).minimalIdentifier
        let pair = LanguagePair(sourceID: sourceID, targetID: targetLanguageID)
        guard sourceID != targetLanguageID else { return }

        let key = CacheKey(word: word.text, pair: pair)
        if let cached = translationCache[key] {
            finishTranslation(cached, key: key, word: word, id: id)
            return
        }

        let availability = await languageAvailability.status(from: pair.source, to: pair.target)
        guard let cursor = cursorOver(word, for: id), !Task.isCancelled else { return }
        switch availability {
        case .installed:
            if missingLanguages == pair { missingLanguages = nil }
        case .supported:
            missingLanguages = pair
            showTooltip(TooltipContent(word: word.text, detail: "Откройте меню, чтобы загрузить языки."), word: word, cursor: cursor)
            return
        case .unsupported:
            return
        @unknown default:
            return
        }

        let content = TranslatingTooltip(word: word.text, pair: pair) { [weak self] translation in
            self?.finishTranslation(translation, key: key, word: word, id: id)
        }
        showTooltip(content, word: word, cursor: cursor)
    }

    private func cursorOver(_ word: HoverWord, for id: UUID) -> Cursor? {
        guard isEnabled, hoverID == id, let cursor = Cursor.current(), word.bounds.contains(cursor.location) else {
            return nil
        }
        return cursor
    }

    private func finishTranslation(_ translation: String?, key: CacheKey, word: HoverWord, id: UUID) {
        guard let cursor = cursorOver(word, for: id) else { return }
        guard let translation else {
            tooltip.hide()
            return
        }
        if translationCache[key] == nil {
            if translationCache.count >= 128 { translationCache.removeAll(keepingCapacity: true) }
            translationCache[key] = translation
        }
        showTooltip(TooltipContent(word: word.text, detail: translation), word: word, cursor: cursor)
    }

    private func showTooltip<Content: View>(_ content: Content, word: HoverWord, cursor: Cursor) {
        let pointer = CGPoint(x: cursor.location.x, y: cursor.desktopTop - cursor.location.y)
        let wordFrame = CGRect(
            x: word.bounds.minX,
            y: cursor.desktopTop - word.bounds.maxY,
            width: word.bounds.width,
            height: word.bounds.height
        )
        tooltip.show(content, near: pointer, wordFrame: wordFrame, visibleFrame: cursor.visibleFrame)
    }
}
