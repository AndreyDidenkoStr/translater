//
//  translaterApp.swift
//  translater
//
//  Copyright © 2026 AndreyDidenkoStr (https://github.com/AndreyDidenkoStr)
//

import SwiftUI

@main
struct translaterApp: App {
    @StateObject private var translator = HoverTranslator()

    var body: some Scene {
        MenuBarExtra {
            ContentView(translator: translator)
        } label: {
            Image(systemName: translator.isEnabled ? "character.bubble.fill" : "character.bubble")
                .accessibilityLabel(translator.isEnabled ? "Перевод включён" : "Перевод выключен")
        }
        .menuBarExtraStyle(.window)
    }
}
