import SwiftUI

// @State is also a macro in this SDK, and its plugin ships only with Xcode. The alias picks the
// plain property wrapper, so Lyps still builds with just the Command Line Tools.
typealias LocalState<Value> = SwiftUI.State<Value>

struct IslandView: View {
    static let width: CGFloat = 420
    static let height: CGFloat = 64

    let model: AppModel
    let settings: Settings

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LocalState private var hovering = false
    @LocalState private var shown = false

    private var entrance: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.32, bounce: 0.22)
    }

    var body: some View {
        HStack(spacing: 12) {
            if settings.showArtwork { artwork }
            lyrics
                .padding(.trailing, hovering ? 32 : 0)
                .overlay(alignment: .trailing) { if hovering { hideButton } }
        }
        .padding(.horizontal, 10)
        .frame(width: Self.width, height: Self.height)
        .contentShape(.rect(cornerRadius: 24))
        .glassEffect(.regular.tint(model.tint.opacity(0.22)), in: .rect(cornerRadius: 24))
        .environment(\.colorScheme, .dark)
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown || reduceMotion ? 1 : 0.92)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { over in
            withAnimation(.easeOut(duration: 0.18)) { hovering = over }
        }
        .onChange(of: model.isVisible, initial: true) { _, visible in
            withAnimation(visible ? entrance : .easeOut(duration: 0.22)) { shown = visible }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.1))
            if let image = model.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(.rect(cornerRadius: 14, style: .continuous))
        .animation(.easeInOut(duration: 0.22), value: model.artwork)
    }

    private var hideButton: some View {
        Button(action: model.toggleShown) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Hide lyrics")
        .accessibilityLabel("Hide lyrics")
        .padding(.trailing, 4)
        .transition(.opacity)
    }

    // MARK: Lyrics

    @ViewBuilder
    private var lyrics: some View {
        ZStack {
            switch model.status {
            case .found where reduceMotion:
                staticRows(first: text(at: model.lineIndex), second: captionText ?? nextRow)
                    .id(model.lineIndex)
                    .transition(.opacity)
            case .found:
                slidingLines
            case .loading:
                staticRows(first: model.track?.title ?? "", second: model.track?.artist ?? "")
            case .unavailable:
                staticRows(first: model.track?.title ?? "", second: "No synced lyrics")
            }
            if !reduceMotion, let captionText {
                caption(captionText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.42, bounce: 0.1), value: model.lineIndex)
        .animation(.easeOut(duration: 0.18), value: model.nudgeLabel)
    }

    /// Takes the next line's place for a moment: the nudge confirmation, or the song while hovering.
    private var captionText: String? {
        if let label = model.nudgeLabel { return label }
        return hovering && model.status == .found && settings.showNextLine ? songDescription : nil
    }

    private var reservesSecondRow: Bool { settings.showNextLine || model.nudgeLabel != nil }

    /// Each line keeps its identity as it moves up, so next grows smoothly into current.
    private var slidingLines: some View {
        let current = model.lineIndex
        return ForEach(max(current - 1, -1)...min(current + 2, model.lines.count - 1), id: \.self) { index in
            lineRow(index: index, offsetFromCurrent: index - current)
        }
    }

    private func lineRow(index: Int, offsetFromCurrent delta: Int) -> some View {
        let string = text(at: index)
        let rightToLeft = isRightToLeft(string)
        let showNext = settings.showNextLine && captionText == nil
        let currentY: CGFloat = reservesSecondRow ? -9 : 0

        let y: CGFloat, scale: CGFloat, opacity: Double, blur: CGFloat
        switch delta {
        case 0: (y, scale, opacity, blur) = (currentY, 1, 1, 0)
        case 1: (y, scale, opacity, blur) = (currentY + 21, 0.8, showNext ? 0.45 : 0, 0)
        case let d where d < 0: (y, scale, opacity, blur) = (currentY - 22, 0.92, 0, 3)
        default: (y, scale, opacity, blur) = (currentY + 40, 0.8, 0, 0)
        }

        return Text(string)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: rightToLeft ? .trailing : .leading)
            .scaleEffect(scale, anchor: rightToLeft ? .trailing : .leading)
            .blur(radius: blur)
            .opacity(opacity)
            .offset(y: y)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.6))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(y: 12)
            .transition(.opacity)
    }

    private func staticRows(first: String, second: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(first)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.75)
            if reservesSecondRow, !second.isEmpty {
                Text(second)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: isRightToLeft(first) ? .trailing : .leading)
    }

    private var nextRow: String {
        model.lineIndex + 1 < model.lines.count ? text(at: model.lineIndex + 1) : ""
    }

    private func text(at index: Int) -> String {
        guard model.lines.indices.contains(index), !model.lines[index].text.isEmpty else { return "♪" }
        return model.lines[index].text
    }

    private var songDescription: String {
        [model.track?.title, model.track?.artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var accessibilityText: String {
        model.status == .found ? text(at: model.lineIndex) : songDescription
    }
}
