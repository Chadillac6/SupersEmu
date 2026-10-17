import SupersEmuKit
import SwiftUI

enum GameGridLayout {
    static func columns(compact: Bool, regularSpacing: CGFloat = 16) -> [GridItem] {
        if compact {
            return [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 10)]
        }
        return [GridItem(.adaptive(minimum: 170), spacing: regularSpacing)]
    }

    static func rowSpacing(compact: Bool, regularSpacing: CGFloat = 20) -> CGFloat {
        compact ? 14 : regularSpacing
    }
}

/// Logo wordmark, the console chips and the theme's brand stripe.
struct SystemSelectorBar: View {
    let theme: SystemTheme
    let systems: [SystemID]
    @Binding var selection: SystemID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ThemeLogo(theme: theme, height: 38)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("home-logo")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(SystemTheme.all)
                    ForEach(systems, id: \.self) { chip(SystemTheme.theme(for: $0)) }
                }
                .padding(.horizontal, 20)
            }
            HStack(spacing: 0) {
                ForEach(theme.stripe.indices, id: \.self) { theme.stripe[$0] }
            }
            .frame(height: 4)
            .clipShape(Capsule())
            .padding(.leading, 20)
            .padding(.trailing, 20)
        }
    }

    private func chip(_ chip: SystemTheme) -> some View {
        let isSelected = chip.system == selection
        return Button { selection = chip.system } label: {
            Text(chip.chip)
                .font(.subheadline.bold())
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundStyle(isSelected ? .white : .primary)
                .background {
                    if isSelected { Capsule().fill(chip.accent) } else { Capsule().fill(.white.opacity(0.1)) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("system-chip-\(chip.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The featured game: cover art, logo or title, and its primary action.
struct HomeHero: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let item: LibraryItem
    let theme: SystemTheme
    let primaryTitle: String
    let primary: () -> Void
    let details: () -> Void

    var body: some View {
        WideArt(item: item, preferCover: true)
            // Scaled artwork can extend beyond its clipped frame and intercept selector clicks.
            .allowsHitTesting(false)
            .frame(height: height)
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                    .allowsHitTesting(false)
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.lastPlayed != nil ? "CONTINUE PLAYING" : "IN YOUR LIBRARY")
                            .font(.caption.bold()).tracking(1.5).foregroundStyle(theme.accent)
                        let title = Text(item.title).font(.system(size: compact ? 26 : 32, weight: .heavy)).lineLimit(2)
                        if let logo = item.logoPath {
                            RemoteArtwork(gameID: item.id, path: logo, contentMode: .fit) { title }
                                .frame(maxWidth: 320, maxHeight: compact ? 64 : 90, alignment: .leading)
                                .accessibilityLabel(item.title)
                        } else {
                            title
                        }
                        Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.8))
                        Button(action: primary) { Label(primaryTitle, systemImage: "play.fill").padding(.horizontal, 6) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(compact ? .regular : .large)
                            .accessibilityIdentifier("hero-primary")
                    }
                    .foregroundStyle(.white)
                    .padding(compact ? 16 : 24)
                    .frame(maxWidth: min(480, geometry.size.width * (1 - WideArt.heroCoverFraction)), maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .contentShape(RoundedRectangle(cornerRadius: 22))
            .onTapGesture { details() }
            .padding(.leading, 20)
            .padding(.trailing, 20)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-hero")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens game details")
            .accessibilityAction { details() }
    }

    private var height: CGFloat {
        #if os(iOS)
        compact ? 240 : 400
        #else
        400
        #endif
    }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private var subtitle: String {
        var parts = [item.console]
        if let year = item.year { parts.append(String(year)) }
        if let lastPlayed = item.lastPlayed { parts.append("Played \(lastPlayed.formatted(.relative(presentation: .named)))") }
        return parts.joined(separator: " · ")
    }
}

/// Recently played games as wide cards with a last-played label.
struct CurrentlyPlayingRow: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let items: [LibraryItem]
    let select: (LibraryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Now Playing").font(.title3.bold()).padding(.horizontal, 20).accessibilityIdentifier("shelf-continue")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        Button { select(item) } label: { card(item) }
                            .buttonStyle(.plain)
                            .frame(width: compact ? 190 : 250)
                            .accessibilityIdentifier("game-card")
                            .accessibilityLabel(item.title)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private func card(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WideArt(item: item)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    if item.playable?.hasResumePoint == true {
                        Label("Resume", systemImage: "play.fill").font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(item.title).font(.subheadline.bold()).lineLimit(1)
            if let lastPlayed = item.lastPlayed {
                Text("\(item.console) · Played \(lastPlayed.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// A sorted cover grid.
struct GameGridSection: View {
    @Environment(DownloadCenter.self) private var downloads
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let title: String
    let identifier: String
    let games: [LibraryItem]
    let select: (LibraryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold()).padding(.horizontal, 20).accessibilityIdentifier(identifier)
            LazyVGrid(columns: GameGridLayout.columns(compact: compact),
                      spacing: GameGridLayout.rowSpacing(compact: compact)) {
                ForEach(games) { item in
                    Button { select(item) } label: { GameCard(item: item, state: downloads.states[item.id]) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("game-card")
                        .accessibilityLabel(item.title)
                        .id(item.id)
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 20)
        }
    }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }
}

/// Wraps tags onto as many lines as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, last.width + spacing + size.width <= width {
                rows[rows.count - 1] = (last.indices + [index], last.width + spacing + size.width, max(last.height, size.height))
            } else {
                rows.append(([index], size.width, size.height))
            }
        }
        return rows
    }
}
