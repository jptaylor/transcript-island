import Carbon.HIToolbox
import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            status
            transcript

            if !model.isBusy {
                Button("Start Dictation", action: model.start)
                    .buttonStyle(.borderedProminent)
            } else if model.escapeRegistered {
                Text("Press Esc to finish")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // Another app holds Esc, so offer the only other way out.
                Button("Finish") { model.finish(by: .menu) }
                    .buttonStyle(.borderedProminent)
            }

            Divider()

            LabeledContent("Shortcut") {
                ShortcutRecorder(
                    shortcut: model.shortcut,
                    onBegin: model.beginRecordingShortcut,
                    onEnd: model.endRecordingShortcut
                )
            }
            if !model.shortcutRegistered {
                Text("Another app is using \(model.shortcut.displayString). Pick a different shortcut.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(model.autoFinish
                 ? "Press it to start dictating. It finishes when you pause for 2 seconds, or press Esc."
                 : "Press it to start dictating, then press Esc when you're done.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Finish when I pause", isOn: $model.autoFinish)

            Toggle("Paste into the app I'm using", isOn: $model.pasteIntoApp)
            Text("Otherwise the text is only copied to the clipboard. It's always copied there as a backup.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            PermissionRow(
                title: "Microphone",
                isGranted: model.microphone == .granted,
                actionTitle: model.microphone == .notDetermined ? "Allow" : "Open Settings",
                action: model.requestMicrophone
            )
            PermissionRow(
                title: "Accessibility",
                detail: "Needed to paste into other apps",
                isGranted: model.accessibilityTrusted,
                actionTitle: "Grant…",
                action: model.requestAccessibility
            )

            Divider()

            HStack {
                Spacer()
                Button("Quit Transcript Island") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { model.refreshPermissions() }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 8) {
            Image(systemName: model.menuBarSymbol)
                .foregroundStyle(statusColor)
            Text(statusText)
                .font(.headline)
                .foregroundStyle(statusColor)
        }
    }

    @ViewBuilder
    private var transcript: some View {
        let isLive = model.phase == .listening || model.phase == .finishing
        if isLive || model.lastTranscript != nil {
            VStack(alignment: .leading, spacing: 6) {
                Text(isLive ? (model.liveText.isEmpty ? "Waiting for speech…" : model.liveText)
                            : model.lastTranscript ?? "")
                    .font(.callout)
                    .foregroundStyle(isLive && model.liveText.isEmpty ? .secondary : .primary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !isLive {
                    Button("Copy Last Transcript", action: model.copyLastTranscript)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
        }
    }

    private var statusText: String {
        switch model.phase {
        case .idle: "Press \(model.shortcut.displayString) to dictate"
        case .preparing(let message): message
        case .listening: "Listening…"
        case .finishing: "Finishing…"
        case .done(.pasted(let appName)): "Pasted into \(appName)"
        case .done(.copied(accessibilityOff: false)): "Copied to the clipboard"
        case .done(.copied(accessibilityOff: true)): "Copied. Turn on Accessibility to paste"
        case .done(.nothingHeard): "Didn't catch anything"
        case .failed(let message): message
        }
    }

    private var statusColor: Color {
        switch model.phase {
        case .listening: .red
        case .done(.nothingHeard): .secondary
        case .done: .green
        case .failed: .orange
        default: .primary
        }
    }
}

private struct PermissionRow: View {
    let title: String
    var detail: String?
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(isGranted ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !isGranted {
                Button(actionTitle, action: action)
            }
        }
    }
}

/// Click, then press the new shortcut. Esc cancels.
private struct ShortcutRecorder: View {
    let shortcut: Shortcut
    let onBegin: () -> Void
    let onEnd: (Shortcut?) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(isRecording ? "Press keys…" : shortcut.displayString) {
            if isRecording { finish(nil) } else { begin() }
        }
        .monospaced()
        .onDisappear { finish(nil) }
    }

    private func begin() {
        isRecording = true
        onBegin()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                finish(nil)
            } else if let newShortcut = Shortcut(event: event) {
                finish(newShortcut)
            } else {
                NSSound.beep()  // needs ⌘, ⌥ or ⌃
            }
            return nil
        }
    }

    private func finish(_ newShortcut: Shortcut?) {
        guard isRecording else { return }
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
        onEnd(newShortcut)
    }
}
