import SwiftUI

/// The "E" marker YouTube Music puts beside explicit songs.
///
/// Takes an optional so it can be fed straight from the wire models, where the
/// flag is absent on responses from a server that predates it — unknown is
/// treated as not explicit, which is the safe way round for a badge that
/// otherwise mislabels clean songs.
struct ExplicitBadge: View {
    let isExplicit: Bool?

    var body: some View {
        if isExplicit == true {
            Text("E")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(uiColor: .systemBackground))
                .frame(width: 13, height: 13)
                .background(Color.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .accessibilityLabel("Explicit")
        }
    }
}

/// A title with its explicit marker, laid out so the badge stays put while a
/// long title truncates around it.
struct TitleWithExplicitBadge: View {
    let title: String
    let isExplicit: Bool?
    var font: Font = .body
    var weight: Font.Weight? = nil

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(weight.map { font.weight($0) } ?? font)
                .lineLimit(1)
                .layoutPriority(1)
            ExplicitBadge(isExplicit: isExplicit)
        }
    }
}
