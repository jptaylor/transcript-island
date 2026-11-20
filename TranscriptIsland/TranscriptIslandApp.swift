import SwiftUI

@main
struct TranscriptIslandApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel("Transcript Island")
        }
        .menuBarExtraStyle(.window)
    }
}

extension AppModel {
    var menuBarSymbol: String {
        switch phase {
        case .idle: "waveform"
        case .preparing: "ellipsis"
        case .listening: "record.circle"
        case .finishing: "ellipsis"
        case .done(.nothingHeard): "waveform.slash"
        case .done: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }
}
