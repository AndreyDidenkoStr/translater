import ApplicationServices
import Foundation
import NaturalLanguage
import ScreenCaptureKit
import Vision

struct HoverWord: Sendable {
    let text: String
    let context: String
    let bounds: CGRect
}

enum WordLookupResult: Sendable {
    case word(HoverWord)
    case noWord
    case screenCaptureUnavailable
}

actor WordLookup {
    private enum AccessibilityHit {
        case word(HoverWord)
        case excluded
        case unresolved
    }

    private lazy var systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.15)
        return element
    }()

    func word(at point: CGPoint, on display: CGRect) async -> WordLookupResult {
        guard !Task.isCancelled else { return .noWord }

        switch accessibilityHit(at: point) {
        case .word(let word):
            return .word(word)
        case .excluded:
            return .noWord
        case .unresolved:
            break
        }

        guard !Task.isCancelled else { return .noWord }
        guard CGPreflightScreenCaptureAccess() else { return .screenCaptureUnavailable }

        let area = CGRect(x: point.x - 200, y: point.y - 64, width: 400, height: 128)
            .intersection(display).integral.intersection(display)
        guard !area.isEmpty, !area.isNull else { return .noWord }

        do {
            let image = try await SCScreenshotManager.captureImage(in: area)
            try Task.checkCancellation()
            if let word = try recognizedWord(in: image, area: area, at: point) {
                return .word(word)
            }
        } catch {
            return .noWord
        }
        return .noWord
    }

    private func accessibilityHit(at point: CGPoint) -> AccessibilityHit {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &element) == .success,
              let hit = element else { return .unresolved }

        var pid: pid_t = 0
        AXUIElementGetPid(hit, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return .excluded }

        var current: AXUIElement? = hit
        for _ in 0..<5 {
            guard let candidate = current, !Task.isCancelled else { break }
            let role = attribute(kAXRoleAttribute, of: candidate) as? String
            let subrole = attribute(kAXSubroleAttribute, of: candidate) as? String
            if subrole == kAXSecureTextFieldSubrole || role == kAXSecureTextFieldSubrole ||
                role == kAXMenuBarRole || role == kAXMenuBarItemRole || role == kAXMenuRole ||
                role == kAXMenuItemRole {
                return .excluded
            }
            if role == kAXWindowRole || role == kAXApplicationRole { break }

            if let word = rangeWord(in: candidate, at: point) ?? markerWord(in: candidate, at: point) {
                return .word(word)
            }
            guard let parent = attribute(kAXParentAttribute, of: candidate),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            current = (parent as! AXUIElement)
        }
        return .unresolved
    }

    private func rangeWord(in element: AXUIElement, at point: CGPoint) -> HoverWord? {
        var position = point
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let indexedRange = parameterized(kAXRangeForPositionParameterizedAttribute, of: element, with: positionValue),
              let index = range(from: indexedRange)?.location else { return nil }

        let count = attribute(kAXNumberOfCharactersAttribute, of: element) as? Int
        let offset: Int
        let context: String
        if let count, index < count {
            let start = max(0, index - 160)
            let end = index + min(161, count - index)
            var span = CFRange(location: start, length: end - start)
            if let spanValue = AXValueCreate(.cfRange, &span),
               let text = parameterized(kAXStringForRangeParameterizedAttribute, of: element, with: spanValue) as? String,
               text.utf16.count == span.length {
                offset = start
                context = text
            } else {
                guard let value = attribute(kAXValueAttribute, of: element) as? String else { return nil }
                offset = 0
                context = value
            }
        } else {
            guard let value = attribute(kAXValueAttribute, of: element) as? String else { return nil }
            offset = 0
            context = value
        }

        let localIndex = index - offset
        guard localIndex < context.utf16.count, context.utf16.count <= 20_000 else { return nil }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = context
        var hit: HoverWord?
        tokenizer.enumerateTokens(in: context.startIndex..<context.endIndex) { token, _ in
            let wordRange = NSRange(token, in: context)
            if wordRange.location > localIndex { return false }
            guard NSLocationInRange(localIndex, wordRange) else { return true }

            var span = CFRange(location: offset + wordRange.location, length: wordRange.length)
            if let spanValue = AXValueCreate(.cfRange, &span),
               let boundsValue = self.parameterized(kAXBoundsForRangeParameterizedAttribute, of: element, with: spanValue),
               let bounds = self.rectangle(from: boundsValue), bounds.contains(point),
               let text = self.wordText(context[token]) {
                let start = context.index(token.lowerBound, offsetBy: -120, limitedBy: context.startIndex) ?? context.startIndex
                let end = context.index(token.upperBound, offsetBy: 120, limitedBy: context.endIndex) ?? context.endIndex
                hit = HoverWord(text: text, context: String(context[start..<end]), bounds: bounds)
            }
            return false
        }
        return hit
    }

    private func markerWord(in element: AXUIElement, at point: CGPoint) -> HoverWord? {
        var position = point
        guard let positionValue = AXValueCreate(.cgPoint, &position),
              let marker = parameterized("AXTextMarkerForPosition", of: element, with: positionValue) else { return nil }

        // WebKit can return a marker between two words. Check the actual on-screen bounds.
        for name in ["AXRightWordTextMarkerRangeForTextMarker", "AXLeftWordTextMarkerRangeForTextMarker"] {
            guard let wordRange = parameterized(name, of: element, with: marker),
                  let boundsValue = parameterized("AXBoundsForTextMarkerRange", of: element, with: wordRange),
                  let bounds = rectangle(from: boundsValue), bounds.contains(point),
                  let value = parameterized("AXStringForTextMarkerRange", of: element, with: wordRange) as? String,
                  let text = wordText(value.trimmingCharacters(in: .whitespacesAndNewlines)[...]) else { continue }

            let sentence = parameterized("AXSentenceTextMarkerRangeForTextMarker", of: element, with: marker)
            let context = sentence.flatMap {
                parameterized("AXStringForTextMarkerRange", of: element, with: $0) as? String
            }
            return HoverWord(text: text, context: context ?? text, bounds: bounds)
        }
        return nil
    }

    private func recognizedWord(in image: CGImage, area: CGRect, at point: CGPoint) throws -> HoverWord? {
        let request = VNRecognizeTextRequest()
        // Character bounds help avoid treating the space between words as a hit.
        request.recognitionLevel = .fast
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])

        let normalizedPoint = CGPoint(
            x: (point.x - area.minX) / area.width,
            y: 1 - (point.y - area.minY) / area.height
        )
        for observation in request.results ?? [] where observation.boundingBox.contains(normalizedPoint) {
            guard let line = observation.topCandidates(1).first else { continue }
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = line.string
            let tokens = tokenizer.tokens(for: line.string.startIndex..<line.string.endIndex)
            for token in tokens {
                guard let box = (try? line.boundingBox(for: token))?.boundingBox,
                      box.contains(normalizedPoint),
                      let text = wordText(line.string[token]) else { continue }
                let bounds = CGRect(
                    x: area.minX + box.minX * area.width,
                    y: area.minY + (1 - box.maxY) * area.height,
                    width: box.width * area.width,
                    height: box.height * area.height
                )
                return HoverWord(text: text, context: line.string, bounds: bounds)
            }
        }
        return nil
    }

    private func wordText(_ token: Substring) -> String? {
        guard token.count <= 64,
              token.rangeOfCharacter(from: .letters) != nil,
              token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return String(token)
    }

    private func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private func parameterized(_ name: String, of element: AXUIElement, with parameter: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result) == .success else {
            return nil
        }
        return result
    }

    private func range(from value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &result) && result.location >= 0 && result.location != NSNotFound
            ? result : nil
    }

    private func rectangle(from value: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var result = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &result) ? result : nil
    }
}
