import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var translator: HoverTranslator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Перевод при наведении", isOn: Binding(
                get: { translator.isEnabled },
                set: { translator.setEnabled($0) }
            ))
            .toggleStyle(.switch)

            Picker("Переводить на", selection: Binding(
                get: { translator.targetLanguageID },
                set: { translator.setTargetLanguage($0) }
            )) {
                ForEach(translator.targetLanguages.isEmpty ? [translator.targetLanguageID] : translator.targetLanguages, id: \.self) { id in
                    Text(translator.languageName(id)).tag(id)
                }
            }

            if translator.needsAccessibility {
                Text("Разрешите доступ в «Системные настройки → Конфиденциальность и безопасность → Универсальный доступ», затем снова включите перевод.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if translator.needsScreenCapture {
                Button("Разрешить распознавание с экрана", action: translator.requestScreenCapture)
                Text("Для распознавания слова нужен доступ к записи экрана. Его можно выдать в «Конфиденциальность и безопасность». После этого macOS может попросить перезапустить утилиту.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let pair = translator.missingLanguages {
                Button("Загрузить языки", action: translator.downloadLanguages)
                Text("\(translator.languageName(pair.sourceID)) → \(translator.languageName(pair.targetID))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Завершить приложение") {
                translator.setEnabled(false)
                NSApplication.shared.terminate(nil)
            }

            Text("Разработчик · @AndreyDidenkoStr")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 295)
        .task { await translator.loadLanguages() }
    }
}
