import AppKit
import Observation
import SwiftUI
import TranscriptCore

// The dictation island: a black bar the app draws in its own panel, growing out of the
// screen's island (or notch) like the Siri bar, with live captions below it.

// MARK: - Layout

enum IslandLayout {
    /// The expanded bar's width; its height depends on the notch (see `expandedHeight`).
    static let expandedWidth: CGFloat = 580
    static let expandedCornerRadius: CGFloat = 30
    /// Gap between the top of the screen and the expanded bar.
    static let expandedTop: CGFloat = 6

    static let horizontalPadding: CGFloat = 28
    static let trailingWidth: CGFloat = 34
    static let spacing: CGFloat = 18
    static let captionSize: CGFloat = 21
    static let lineSpacing: CGFloat = 3
    static var captionLineHeight: CGFloat { captionSize * 1.22 }
    static var captionsHeight: CGFloat { 2 * captionLineHeight + lineSpacing }
    static let bottomPadding: CGFloat = 20

    /// Space above the captions inside the bar. The notch hides whatever is drawn behind it,
    /// so on a Mac with a notch the captions start just below it, like the Siri bar. The band
    /// beside the notch holds the Esc hint (left) and the timer (right).
    static func contentTopPadding(notchHeight: CGFloat) -> CGFloat {
        notchHeight > 0 ? notchHeight - expandedTop + 6 : 34
    }

    /// Where the Esc hint and timer sit, measured from the bar's top: level with the center of
    /// the island (24 pt from the top of the screen on the PROLED MacBook Pro), so they flank it.
    static func topLabelCenter(island: IslandShape, notchHeight: CGFloat) -> CGFloat {
        notchHeight > 0 ? island.top + island.size.height / 2 - expandedTop : 16
    }

    static let topLabelSize: CGFloat = 12

    static func expandedHeight(notchHeight: CGFloat) -> CGFloat {
        contentTopPadding(notchHeight: notchHeight) + captionsHeight + bottomPadding
    }

    /// Room around the bar for its soft shadow.
    static let shadowMargin: CGFloat = 70

    static let captionWidth: CGFloat =
        expandedWidth - 2 * horizontalPadding - trailingWidth - spacing

    /// Whether `text` fits one caption line, measured with the caption font.
    static let captionFits: @Sendable (String) -> Bool = { text in
        let font = NSFont.systemFont(ofSize: captionSize, weight: .medium)
        let width = NSAttributedString(string: text, attributes: [.font: font]).size().width
        return width <= captionWidth - 4
    }
}

/// The shape the bar grows out of and shrinks back into: the screen's island or notch.
struct IslandShape: Equatable {
    var size: CGSize
    /// Distance from the top of the screen.
    var top: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    /// Macs without a notch: a small pill at the top center.
    static let fallback = IslandShape(size: CGSize(width: 120, height: 24), top: 2, topRadius: 12, bottomRadius: 12)

    /// From the free areas either side of the notch that macOS reports.
    static func of(_ screen: NSScreen) -> IslandShape {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return .fallback }
        let width = right.minX - left.maxX
        let notchHeight = screen.safeAreaInsets.top
        if width < 120 {
            // A Dynamic Island: a floating capsule (measured on the PROLED MacBook Pro: 58 × 30,
            // 9 pt from the top, ending just above the bottom of the menu bar).
            let height = min(width * 0.51, notchHeight - 4)
            return IslandShape(
                size: CGSize(width: width - 1, height: height), top: notchHeight - height - 1,
                topRadius: height / 2, bottomRadius: height / 2
            )
        }
        // A classic notch, attached to the top edge, with rounded bottom corners.
        return IslandShape(size: CGSize(width: width, height: notchHeight), top: 0, topRadius: 0, bottomRadius: 10)
    }
}

/// What the island shows when a dictation is over.
struct IslandResult: Equatable {
    enum Kind {
        case inserted, copied, warning, nothing
    }

    var kind: Kind
    /// A few words, shown beside the island.
    var message: String

    init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    init(_ outcome: DeliveryOutcome) {
        switch outcome {
        case .inserted(let appName): self.init(kind: .inserted, message: "Inserted into \(appName)")
        case .copied(accessibilityOff: false): self.init(kind: .copied, message: "Copied · ⌘V to paste")
        case .copied(accessibilityOff: true): self.init(kind: .warning, message: "Copied · Accessibility is off")
        case .nothingHeard: self.init(kind: .nothing, message: "Nothing heard")
        }
    }
}

// MARK: - State

@MainActor
@Observable
final class IslandModel {
    var isVisible = false
    var isExpanded = false
    /// Height of the screen's notch (0 without one); the captions start below it.
    var notchHeight: CGFloat = 0
    /// Where the bar grows from and shrinks back into.
    var island = IslandShape.fallback
    var captions: [Caption] = []
    /// Microphone level, 0…1, smoothed.
    var level: Double = 0
    /// Set when the dictation is over: where the text went, or what went wrong.
    var result: IslandResult?
    /// The timer counts from `startedAt`, and stops at `endedAt` once it's done.
    var startedAt = Date.now
    var endedAt: Date?
}

// MARK: - Controller

/// Shows the island in a borderless, non-activating panel above the menu bar. It never
/// becomes key or takes clicks, so focus stays in the app you're dictating into.
@MainActor
final class IslandPanel {
    let model = IslandModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private let chime: NSSound? = Bundle.main.url(forResource: "start", withExtension: "caf")
        .flatMap { NSSound(contentsOf: $0, byReference: true) }

    /// Opens with a little life; closes with no overshoot, so it lands exactly on the island.
    private static let expand = Animation.spring(response: 0.5, dampingFraction: 0.8)
    private static let collapse = Animation.spring(response: 0.42, dampingFraction: 1.0)

    /// Grows out of the notch and plays a soft chime.
    func show() {
        hideTask?.cancel()
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)

        model.captions = []
        model.result = nil
        model.startedAt = .now
        model.endedAt = nil
        model.level = 0
        model.isExpanded = false
        model.isVisible = true
        panel.orderFrontRegardless()

        chime?.volume = 0.5
        chime?.stop()
        chime?.play()

        // Next turn of the run loop, so the collapsed state is on screen to grow from.
        Task { @MainActor in
            withAnimation(Self.expand) { self.model.isExpanded = true }
        }
    }

    func update(captions: [Caption]) {
        guard captions != model.captions else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            model.captions = captions
        }
    }

    /// Raw level, 0…1, from the microphone tap (~10–40 times a second).
    func setLevel(_ level: Double) {
        // Rise quickly, fall slowly.
        model.level = level > model.level ? 0.5 * level + 0.5 * model.level : 0.8 * model.level + 0.2 * level
    }

    /// Shows the result for `lingering`, then shrinks back into the notch.
    func finish(_ result: IslandResult, lingering: Duration = .milliseconds(1100)) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            model.result = result
            model.endedAt = .now
            model.level = 0
        }
        hide(after: lingering)
    }

    /// Shrinks back into the notch (right away by default).
    func hide(after delay: Duration = .zero) {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let self, !Task.isCancelled else { return }
            withAnimation(Self.collapse) { self.model.isExpanded = false }
            try? await Task.sleep(for: .milliseconds(480))  // until it has settled on the island
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { self.model.isVisible = false }
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled else { return }
            self.panel?.orderOut(nil)
        }
    }

    // MARK: Panel

    private var panelSize: NSSize {
        NSSize(
            width: IslandLayout.expandedWidth + 2 * IslandLayout.shadowMargin,
            height: IslandLayout.expandedTop + IslandLayout.expandedHeight(notchHeight: model.notchHeight)
                + IslandLayout.shadowMargin
        )
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the bar draws its own, softer shadow
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Above the menu bar, so the bar can sit over it and merge with the notch.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let hosting = NSHostingView(rootView: IslandView(model: model))
        hosting.sizingOptions = []
        panel.contentView = hosting
        return panel
    }

    /// Top center of the screen with the notch (else the main screen), centered on the notch.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        model.notchHeight = screen.safeAreaInsets.top
        model.island = IslandShape.of(screen)
        let frame = screen.frame
        var centerX = frame.midX
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            centerX = (left.maxX + right.minX) / 2
        }
        let size = panelSize
        panel.setFrame(
            NSRect(x: centerX - size.width / 2, y: frame.maxY - size.height, width: size.width, height: size.height),
            display: true
        )
    }
}

// MARK: - Views

struct IslandView: View {
    let model: IslandModel

    var body: some View {
        let expanded = model.isExpanded
        let expandedSize = CGSize(
            width: IslandLayout.expandedWidth,
            height: IslandLayout.expandedHeight(notchHeight: model.notchHeight)
        )
        let island = model.island
        let size = expanded ? expandedSize : island.size
        // Each corner animates on its own: from the island's (a capsule, or a notch's square
        // top and rounded bottom) to the bar's.
        let topRadius = expanded ? IslandLayout.expandedCornerRadius : island.topRadius
        let bottomRadius = expanded ? IslandLayout.expandedCornerRadius : island.bottomRadius
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: topRadius, bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius, topTrailingRadius: topRadius,
            style: .continuous
        )

        // The shape is sized exactly (not by a container), so while small it really is the
        // island's capsule; the bar-sized content sits in an overlay clipped to it.
        shape
            .fill(.black)
            .frame(width: size.width, height: size.height)
            .overlay {
                IslandContent(model: model)
                    .frame(width: expandedSize.width, height: expandedSize.height)
                    .opacity(expanded ? 1 : 0)
                    .scaleEffect(expanded ? 1 : 0.9)
                    .blur(radius: expanded ? 0 : 8)
                    .animation(.easeOut(duration: expanded ? 0.28 : 0.12).delay(expanded ? 0.1 : 0), value: expanded)
            }
            .overlay {
                // A faint rim of light along the top edge, for depth.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.16), .white.opacity(0.04), .white.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .opacity(expanded ? 1 : 0)
            }
            .clipShape(shape)
            // Layered, soft shadows: a wide ambient one and a tighter contact one.
            .shadow(color: .black.opacity(expanded ? 0.42 : 0), radius: 38, y: 20)
            .shadow(color: .black.opacity(expanded ? 0.22 : 0), radius: 10, y: 5)
            .padding(.top, expanded ? IslandLayout.expandedTop : island.top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(model.isVisible ? 1 : 0)
    }
}

struct IslandContent: View {
    let model: IslandModel

    var body: some View {
        HStack(spacing: IslandLayout.spacing) {
            CaptionsView(captions: model.captions, placeholder: "Listening…")
                .frame(width: IslandLayout.captionWidth, alignment: .leading)

            ZStack {
                if let result = model.result {
                    ResultMark(kind: result.kind)
                        .accessibilityLabel(result.message)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    LiveWaveform(level: model.level)
                        .transition(.opacity)
                }
            }
            .frame(width: IslandLayout.trailingWidth)
        }
        .padding(.horizontal, IslandLayout.horizontalPadding)
        .padding(.top, IslandLayout.contentTopPadding(notchHeight: model.notchHeight))
        .padding(.bottom, IslandLayout.bottomPadding)
        .overlay(alignment: .top) {
            TopLabels(model: model)
        }
    }
}

/// The band beside the notch: a muted Esc hint on the left (aligned with the captions) and a
/// small timer on the right (aligned with the waveform), level with the center of the island.
struct TopLabels: View {
    let model: IslandModel

    var body: some View {
        HStack {
            ZStack(alignment: .leading) {
                HStack(spacing: 5) {
                    KeyCap(label: "esc")
                    Text("to finish")
                        .foregroundStyle(.white.opacity(0.32))
                }
                .opacity(model.result == nil ? 1 : 0)
                // When it's over, the same spot says where the text went, or what went wrong.
                Text(model.result?.message ?? "")
                    .foregroundStyle(.white.opacity(0.6))
                    .opacity(model.result == nil ? 0 : 1)
            }
            .animation(.easeOut(duration: 0.2), value: model.result)
            Spacer()
            Text(
                timerInterval: model.startedAt...Date.distantFuture,
                pauseTime: model.endedAt,
                countsDown: false,
                showsHours: false
            )
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.5))
            .multilineTextAlignment(.trailing)
            .frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: IslandLayout.topLabelSize, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, IslandLayout.horizontalPadding)
        // Centered on `topLabelCenter`: a frame twice that tall, content in its middle.
        .frame(height: 2 * IslandLayout.topLabelCenter(island: model.island, notchHeight: model.notchHeight))
    }
}

/// A key label, like an HTML `<kbd>`: small text in a softly outlined, slightly lit rounded box.
struct KeyCap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: IslandLayout.topLabelSize - 1, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.75)
            )
    }
}

/// Two caption lines. Each line keeps its identity (where it starts in the transcript), so
/// new words write in at the end of the bottom line, and when it fills, the lines roll up:
/// the top line slides out, the bottom one moves up, and the new one slides in.
struct CaptionsView: View {
    let captions: [Caption]
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: IslandLayout.lineSpacing) {
            if captions.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.white.opacity(0.42))
                    .transition(.opacity)
            }
            ForEach(Array(captions.enumerated()), id: \.element.id) { index, caption in
                Text(caption.text)
                    .foregroundStyle(.white.opacity(index == captions.count - 1 ? 1 : 0.5))
                    // A cross-fade: words already there overlap exactly, so only new words fade
                    // in. (`.interpolate` morphed letter shapes and could leave them garbled.)
                    .contentTransition(.opacity)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            }
        }
        .font(.system(size: IslandLayout.captionSize, weight: .medium))
        .lineLimit(1)
        .frame(height: IslandLayout.captionsHeight, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

/// Five white bars that follow the microphone level, with a gentle idle motion.
struct LiveWaveform: View {
    let level: Double
    private let weights: [Double] = [0.55, 0.85, 1.0, 0.8, 0.5]

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<weights.count, id: \.self) { index in
                    let wobble = 0.6 + 0.4 * sin(t * 7.5 + Double(index) * 1.4)
                    let amount = min(1, level * weights[index] * (0.7 + 0.5 * wobble) + 0.1 * wobble)
                    Capsule()
                        .fill(.white)
                        .frame(width: 3.5, height: 5 + 21 * amount)
                }
            }
            .frame(height: 28)
        }
        .accessibilityLabel("Listening")
    }
}

struct ResultMark: View {
    let kind: IslandResult.Kind

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(color)
    }

    private var symbol: String {
        switch kind {
        case .inserted: "checkmark.circle.fill"
        case .copied: "doc.on.clipboard.fill"
        case .warning: "exclamationmark.circle.fill"
        case .nothing: "minus.circle.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .inserted: .green
        case .copied: .white.opacity(0.85)
        case .warning: .orange
        case .nothing: .secondary
        }
    }
}
