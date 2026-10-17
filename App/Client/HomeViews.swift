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
    let statusLine: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if theme.system != nil {
                ThemeLogo(theme: theme, height: 38)
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("home-console-logo")
            }
            Text(statusLine)
                .font(Brand.eyebrow)
                .tracking(1.2)
                .foregroundStyle(Brand.Colors.ink3)
                .padding(.horizontal, 20)
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
        // Plate-style logos are dark artwork, so their chip is the white plate in both appearances.
        let fill = chip.logoStyle == .plate ? Color.white : Brand.Colors.surface
        return Button { selection = chip.system } label: {
            chipLabel(chip)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background { Capsule().fill(fill) }
                .overlay {
                    Capsule().strokeBorder(isSelected ? Brand.Colors.red : Brand.Colors.line, lineWidth: isSelected ? 2 : 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chip.system?.displayName ?? chip.chip)
        .accessibilityIdentifier("system-chip-\(chip.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private func chipLabel(_ chip: SystemTheme) -> some View {
        if let logo = chip.logo {
            switch chip.logoStyle {
            case .light:
                Image(logo).renderingMode(.template).resizable().scaledToFit().foregroundStyle(Brand.Colors.ink)
                    .frame(height: 22)
            case .original, .plate:
                Image(logo).resizable().scaledToFit()
                    .frame(height: 22)
            }
        } else {
            Text(chip.chip)
                .font(.subheadline.bold())
                .foregroundStyle(Brand.Colors.ink)
                .frame(minHeight: 22)
        }
    }
}

/// The featured game: cover art above the title, status and primary actions.
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
        VStack(alignment: .leading, spacing: 0) {
            WideArt(item: item, preferCover: true)
                // Scaled artwork can extend beyond its clipped frame and intercept selector-chip clicks.
                .allowsHitTesting(false)
                .frame(height: height)
                .overlay(alignment: .topLeading) {
                    if let logo = item.logoPath {
                        RemoteArtwork(gameID: item.id, path: logo, contentMode: .fit) { EmptyView() }
                            .frame(maxWidth: 240, maxHeight: 68, alignment: .leading)
                            .padding(16)
                            .accessibilityHidden(true)
                    }
                }
                .clipped()
            VStack(alignment: .leading, spacing: 10) {
                Text(item.lastPlayed != nil ? "CONTINUE PLAYING" : "IN YOUR LIBRARY")
                    .font(Brand.eyebrow).tracking(1.2).foregroundStyle(Brand.Colors.redText)
                Text(item.title)
                    .font(.system(size: compact ? 25 : 30, weight: .bold))
                    .foregroundStyle(Brand.Colors.ink)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Brand.Colors.ink2)
                HStack(spacing: 10) {
                    Button(action: primary) {
                        Label(primaryTitle, systemImage: "play.fill")
                            .frame(minWidth: compact ? nil : 140)
                    }
                    .buttonStyle(BrandPrimaryButtonStyle())
                    .controlSize(compact ? .regular : .large)
                    .fixedSize(horizontal: !compact, vertical: false)
                    .accessibilityIdentifier("hero-primary")
                    Button(action: details) {
                        Label("Details", systemImage: "info.circle")
                            .frame(minWidth: compact ? nil : 140)
                    }
                    .buttonStyle(BrandSecondaryButtonStyle())
                    .controlSize(compact ? .regular : .large)
                    .fixedSize(horizontal: !compact, vertical: false)
                    .accessibilityIdentifier("hero-details")
                }
            }
            .padding(compact ? 16 : 22)
        }
        .background(Brand.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: Brand.Radii.card))
        .overlay {
            RoundedRectangle(cornerRadius: Brand.Radii.card)
                .stroke(Brand.Colors.line, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Brand.Radii.card))
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
        compact ? 240 : 260
        #else
        260
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
            shelfHeader(title: "Now Playing", count: items.count, id: "shelf-continue")
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

    private func shelfHeader(title: String, count: Int, id: String) -> some View {
        VStack(spacing: 10) {
            HStack {
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(Brand.Colors.ink).accessibilityIdentifier(id)
                Spacer()
                Text("\(count)").font(Brand.eyebrow).tracking(1.2).foregroundStyle(Brand.Colors.ink3)
            }
            Rectangle().fill(Brand.Colors.line).frame(height: 1)
        }
        .padding(.horizontal, 20)
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
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(item.title).font(.subheadline.bold()).foregroundStyle(Brand.Colors.ink).lineLimit(1)
            if let lastPlayed = item.lastPlayed {
                Text("\(item.console) · \(lastPlayed.formatted(.relative(presentation: .named)) )".uppercased())
                    .font(Brand.eyebrow).tracking(1.2).foregroundStyle(Brand.Colors.ink3).lineLimit(1)
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
            VStack(spacing: 10) {
                HStack {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Brand.Colors.ink)
                        .accessibilityIdentifier(identifier)
                    Spacer()
                    Text("\(games.count)")
                        .font(Brand.eyebrow)
                        .tracking(1.2)
                        .foregroundStyle(Brand.Colors.ink3)
                }
                Rectangle().fill(Brand.Colors.line).frame(height: 1)
            }
            .padding(.horizontal, 20)
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
