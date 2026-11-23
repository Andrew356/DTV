import SwiftUI

struct LiveTVView: View {
    @Environment(AppModel.self) private var model
    @State private var group = Groups.all

    private var channels: [Channel] {
        guard let catalog = model.catalog else { return [] }
        switch group {
        case Groups.all: return catalog.live
        case Groups.favorites: return model.favoriteChannels
        default: return catalog.live.filter { $0.group == group }
        }
    }

    var body: some View {
        if let catalog = model.catalog {
            if catalog.live.isEmpty {
                EmptyStateView(systemImage: "tv.slash", title: "No live channels in this source")
            } else {
                HStack(alignment: .top, spacing: 0) {
                    CategorySidebar(groups: catalog.liveGroups,
                                    counts: counts(catalog),
                                    extras: [Groups.all, Groups.favorites],
                                    selection: $group)
                    ChannelList(channels: channels, emptyMessage: group == Groups.favorites
                                ? "Long-press a channel to add it to Favorites." : "No channels")
                }
            }
        } else {
            Color.clear
        }
    }

    private func counts(_ catalog: Catalog) -> [String: Int] {
        var c = Dictionary(grouping: catalog.live, by: \.group).mapValues(\.count)
        c[Groups.all] = catalog.live.count
        c[Groups.favorites] = model.favoriteChannels.count
        return c
    }
}

struct ChannelList: View {
    @Environment(AppModel.self) private var model
    let channels: [Channel]
    var emptyMessage = "No channels"

    var body: some View {
        if channels.isEmpty {
            EmptyStateView(systemImage: "heart", title: emptyMessage)
        } else {
            // TimelineView keeps "now playing" and progress bars fresh.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                List(channels) { channel in
                    ChannelRow(channel: channel, now: context.date, list: channels)
                }
            }
        }
    }
}

struct ChannelRow: View {
    @Environment(AppModel.self) private var model
    let channel: Channel
    let now: Date
    var list: [Channel]? = nil

    var body: some View {
        let current = model.epg.current(for: channel, at: now)
        let next = model.epg.upcoming(for: channel, after: now, limit: 2).first { $0 != current }
        let favorite = model.isFavorite(.live, channel.id)

        Button {
            model.play(channel: channel, in: list ?? listForPlayback)
        } label: {
            HStack(spacing: 30) {
                if model.sync.settings.showChannelNumbers, let n = channel.number {
                    Text("\(n)").font(.headline).monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                }
                ChannelLogo(url: channel.logoURL, name: channel.name).frame(width: 150, height: 90)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(channel.name).font(.headline).lineLimit(1)
                        if favorite { Image(systemName: "heart.fill").foregroundStyle(.red).font(.caption) }
                        if channel.hasArchive { Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary) }
                    }
                    if let current {
                        Text(current.title).font(.callout).lineLimit(1)
                        ProgressView(value: current.progress(at: now)).frame(maxWidth: 500)
                    } else {
                        Text(channel.group).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let next {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Next · \(next.start.formatted(date: .omitted, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(next.title).font(.caption).lineLimit(1)
                    }
                    .frame(maxWidth: 420, alignment: .trailing)
                }
            }
            .padding(.vertical, 6)
        }
        .contextMenu {
            Button(favorite ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: favorite ? "heart.slash" : "heart") {
                model.toggleFavorite(kind: .live, id: channel.id, name: channel.name, image: channel.logoURL)
            }
        }
    }

    /// Zap list: the channel's own category.
    private var listForPlayback: [Channel] {
        model.catalog?.live.filter { $0.group == channel.group } ?? [channel]
    }
}
