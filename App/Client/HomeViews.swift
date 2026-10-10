import SupersEmuKit
import SwiftUI

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
            .padding(.trailing, JumpRail.inset)
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

/// The featured game: wide art, logo or title, and Resume.
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
        WideArt(item: item)
            .frame(height: height)
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(item.lastPlayed != nil ? "CONTINUE PLAYING" : "IN YOUR LIBRARY")
                        .font(.caption.bold()).tracking(1.5).foregroundStyle(theme.accent)
                    let title = Text(item.title).font(.system(size: 32, weight: .heavy)).lineLimit(2)
                    if let logo = item.logoPath {
                        RemoteArtwork(gameID: item.id, path: logo, contentMode: .fit) { title }
                            .frame(maxWidth: 320, maxHeight: 90, alignment: .leading)
                            .accessibilityLabel(item.title)
                    } else {
                        title
                    }
                    Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.8))
                    HStack(spacing: 10) {
                        Button(action: primary) { Label(primaryTitle, systemImage: "play.fill").padding(.horizontal, 6) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .accessibilityIdentifier("hero-primary")
                        Button(action: details) { Label("Details", systemImage: "info.circle") }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .accessibilityIdentifier("hero-details")
                    }
                }
                .foregroundStyle(.white)
                .padding(24)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .padding(.leading, 20)
            .padding(.trailing, JumpRail.inset)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-hero")
    }

    private var height: CGFloat {
        #if os(iOS)
        sizeClass == .compact ? 300 : 400
        #else
        400
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
    let items: [LibraryItem]
    let select: (LibraryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Currently Playing").font(.title3.bold()).padding(.horizontal, 20).accessibilityIdentifier("shelf-continue")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        Button { select(item) } label: { card(item) }
                            .buttonStyle(.plain)
                            .frame(width: 250)
                            .accessibilityIdentifier("game-card")
                            .accessibilityLabel(item.title)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
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

/// "All Games A-Z": one cover grid per letter, each a scroll target for the jump rail.
struct AlphabetGrid: View {
    @Environment(DownloadCenter.self) private var downloads
    let sections: [LetterSection]
    let select: (LibraryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("All Games A–Z").font(.title3.bold()).padding(.horizontal, 20).accessibilityIdentifier("shelf-all")
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.id).font(.headline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("letter-header-\(section.id)")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 20) {
                            ForEach(section.items) { item in
                                Button { select(item) } label: { GameCard(item: item, state: downloads.states[item.id]) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("game-card")
                                    .accessibilityLabel(item.title)
                            }
                        }
                    }
                    .id("letter-\(section.id)")
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, JumpRail.inset)
        }
    }
}

/// A-Z down the right edge. Click a letter on the Mac; on iOS drag along it to scrub, with a bubble showing the letter.
struct JumpRail: View {
    /// Trailing space Home sections leave for the rail.
    static let inset: CGFloat = 40
    let available: Set<String>
    /// Scrubbing jumps without animation: queued animated scrolls can stop short of the final letter.
    let jump: (_ letter: String, _ animated: Bool) -> Void
    @State private var scrubbing: String?

    var body: some View {
        GeometryReader { geometry in
            let row = max(10, (geometry.size.height - 12) / CGFloat(LibraryShelves.alphabet.count))
            VStack(spacing: 0) {
                ForEach(LibraryShelves.alphabet, id: \.self) { letter in
                    letterView(letter, row: row)
                }
            }
            .padding(.vertical, 6)
            .frame(width: 22)
            .background(.ultraThinMaterial, in: Capsule())
            #if os(iOS)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let index = Int((value.location.y - 6) / row)
                    let letter = LibraryShelves.alphabet[min(max(index, 0), LibraryShelves.alphabet.count - 1)]
                    guard letter != scrubbing else { return }
                    scrubbing = letter
                    if let target = target(for: letter) { jump(target, false) }
                }
                .onEnded { _ in
                    if let scrubbing, let target = target(for: scrubbing) { jump(target, false) }
                    scrubbing = nil
                })
            .overlay(alignment: .topLeading) {
                if let scrubbing, let index = LibraryShelves.alphabet.firstIndex(of: scrubbing) {
                    Text(scrubbing).font(.title.bold()).frame(width: 56, height: 56)
                        .background(.regularMaterial, in: Circle())
                        .offset(x: -70, y: 6 + CGFloat(index) * row - 28 + row / 2)
                        .allowsHitTesting(false)
                }
            }
            .sensoryFeedback(.selection, trigger: scrubbing)
            #endif
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(width: 22)
        .frame(maxHeight: 480)
        .padding(.trailing, 8)
        .accessibilityIdentifier("jump-rail")
    }

    @ViewBuilder private func letterView(_ letter: String, row: CGFloat) -> some View {
        let label = Text(letter)
            .font(.system(size: min(11, row * 0.72), weight: .bold, design: .rounded))
            .foregroundStyle(available.contains(letter) ? Color.primary : Color.secondary.opacity(0.35))
            .frame(width: 22, height: row)
        #if os(macOS)
        Button { if let target = target(for: letter) { jump(target, true) } } label: { label.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .disabled(target(for: letter) == nil)
            .accessibilityIdentifier("jump-\(letter)")
        #else
        label.accessibilityIdentifier("jump-\(letter)")
        #endif
    }

    /// The letter itself, else the next one that has games, else the last one that does.
    private func target(for letter: String) -> String? {
        let letters = LibraryShelves.alphabet
        guard let index = letters.firstIndex(of: letter) else { return nil }
        return letters[index...].first(where: available.contains) ?? letters[..<index].last(where: available.contains)
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
