import SwiftUI

struct ChannelLogo: View {
    let url: URL?
    let name: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08))
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit().padding(8)
                    } else {
                        initials
                    }
                }
            } else {
                initials
            }
        }
    }

    private var initials: some View {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map { String($0) }.joined())
            .font(.title3.bold()).foregroundStyle(.secondary)
    }
}

struct PosterCard: View {
    let title: String
    let imageURL: URL?
    var subtitle: String? = nil
    var progress: Double? = nil
    var isFavorite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .bottom) {
                Rectangle().fill(.white.opacity(0.06))
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").font(.system(size: 50)).foregroundStyle(.tertiary)
                    }
                }
                if let progress, progress > 0 {
                    GeometryReader { geo in
                        Rectangle().fill(.red).frame(width: geo.size.width * progress, height: 6)
                    }
                    .frame(height: 6)
                }
            }
            .frame(width: 250, height: 375)
            .clipped()
            .overlay(alignment: .topTrailing) {
                if isFavorite {
                    Image(systemName: "heart.fill").foregroundStyle(.red).padding(10)
                }
            }
        }
    }
}

/// Poster + title, laid out for the tvOS `.card` button style.
struct PosterButton: View {
    let title: String
    let imageURL: URL?
    var subtitle: String? = nil
    var progress: Double? = nil
    var isFavorite = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: action) {
                PosterCard(title: title, imageURL: imageURL, progress: progress, isFavorite: isFavorite)
            }
            .buttonStyle(.card)
            Text(title).font(.caption).lineLimit(2).frame(width: 250, alignment: .leading)
            if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// Left-hand list of categories shared by Live TV, Movies and Series.
struct CategorySidebar: View {
    let groups: [String]
    let counts: [String: Int]
    var extras: [String] = []
    @Binding var selection: String

    var body: some View {
        List {
            ForEach(extras + groups, id: \.self) { group in
                Button {
                    selection = group
                } label: {
                    HStack {
                        Text(group).lineLimit(1)
                        Spacer()
                        if let n = counts[group] { Text("\(n)").foregroundStyle(.secondary).font(.caption) }
                    }
                }
                .listRowBackground(selection == group ? Color.white.opacity(0.15) : Color.clear)
            }
        }
        .frame(width: 480)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage).font(.system(size: 80)).foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            if let message { Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(80)
    }
}

enum Groups {
    static let all = "All"
    static let favorites = "★ Favorites"
}
