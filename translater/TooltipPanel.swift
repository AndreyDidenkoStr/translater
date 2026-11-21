import AppKit
import SwiftUI
import Translation

@MainActor
final class TooltipPanel {
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        return panel
    }()

    func show<Content: View>(_ content: Content, near pointer: CGPoint, wordFrame: CGRect, visibleFrame: CGRect) {
        let host = NSHostingView(rootView: content)
        panel.contentView = host
        panel.setFrame(Self.frame(
            size: host.fittingSize,
            near: pointer,
            wordFrame: wordFrame,
            visibleFrame: visibleFrame
        ), display: true)
        panel.invalidateShadow()
        panel.orderFrontRegardless()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
    }

    static func frame(size: CGSize, near pointer: CGPoint, wordFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let display = visibleFrame.insetBy(dx: 6, dy: 6)
        let width = min(ceil(size.width), display.width)
        let height = min(ceil(size.height), display.height)
        let x = min(max(pointer.x + 12, display.minX), display.maxX - width)
        let below = min(pointer.y - 12, wordFrame.minY - 6) - height
        let above = max(pointer.y + 12, wordFrame.maxY + 6)
        let y = below >= display.minY ? below : min(max(above, display.minY), display.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct TooltipContent: View {
    let word: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: word)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let detail {
                Text(verbatim: detail)
                    .font(.body.weight(.medium))
                    .lineLimit(3)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Перевод")
            }
        }
        .frame(maxWidth: 250, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct TranslatingTooltip: View {
    let word: String
    let pair: LanguagePair
    let complete: @MainActor (String?) -> Void

    var body: some View {
        TooltipContent(word: word, detail: nil)
            .translationTask(source: pair.source, target: pair.target) { session in
                do {
                    try Task.checkCancellation()
                    let response = try await session.translate(word)
                    try Task.checkCancellation()
                    complete(response.targetText)
                } catch {
                    if !Task.isCancelled { complete(nil) }
                }
            }
    }
}

struct LanguageDownloadView: View {
    let pair: LanguagePair
    let title: String
    let onReady: @MainActor () -> Void

    @State private var status = "Ожидание загрузки…"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).font(.headline)
            Text(verbatim: status)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .translationTask(source: pair.source, target: pair.target) { session in
            do {
                try Task.checkCancellation()
                try await session.prepareTranslation()
                let availability = await LanguageAvailability().status(from: pair.source, to: pair.target)
                try Task.checkCancellation()
                if availability == .installed {
                    onReady()
                } else {
                    status = "Загрузка началась. Перевод будет доступен после её завершения."
                }
            } catch {
                if !Task.isCancelled {
                    status = "Языки пока не загружены. Попробуйте ещё раз из меню утилиты."
                }
            }
        }
    }
}
