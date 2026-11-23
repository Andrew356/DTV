import SwiftUI

struct FavoritesView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedMovie: Movie?

    var body: some View {
        NavigationStack {
            let channels = model.favoriteChannels
            let movies = model.favoriteMovies
            let series = model.favoriteSeries
            let resume = model.continueWatching

            if channels.isEmpty && movies.isEmpty && series.isEmpty && resume.isEmpty {
                EmptyStateView(systemImage: "heart", title: "Nothing here yet",
                               message: "Long-press a channel, or use the Favorite button on a movie or series.\nFavorites sync to your other Apple TVs through iCloud.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 50) {
                        if !resume.isEmpty {
                            Shelf(title: "Continue Watching") {
                                ForEach(resume) { entry in
                                    PosterButton(title: entry.name, imageURL: entry.imageURL.flatMap(URL.init(string:)),
                                                 subtitle: "\(Int((entry.duration - entry.position) / 60)) min left",
                                                 progress: entry.fraction) {
                                        Task { await model.resume(entry) }
                                    }
                                    .contextMenu {
                                        Button("Remove", systemImage: "xmark") { model.sync.clearProgress(id: entry.id) }
                                    }
                                }
                            }
                        }
                        if !channels.isEmpty {
                            Shelf(title: "Channels") {
                                ForEach(channels) { ch in
                                    VStack(spacing: 12) {
                                        Button { model.play(channel: ch, in: channels) } label: {
                                            ChannelLogo(url: ch.logoURL, name: ch.name).frame(width: 300, height: 170)
                                        }
                                        .buttonStyle(.card)
                                        .contextMenu {
                                            Button("Remove from Favorites", systemImage: "heart.slash") {
                                                model.toggleFavorite(kind: .live, id: ch.id, name: ch.name, image: ch.logoURL)
                                            }
                                        }
                                        Text(ch.name).font(.caption).lineLimit(1).frame(width: 300)
                                        Text(model.epg.current(for: ch)?.title ?? " ")
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 300)
                                    }
                                }
                            }
                        }
                        if !movies.isEmpty {
                            Shelf(title: "Movies") {
                                ForEach(movies) { m in
                                    PosterButton(title: m.name, imageURL: m.posterURL,
                                                 progress: model.progress(for: m.id)?.fraction) { selectedMovie = m }
                                }
                            }
                        }
                        if !series.isEmpty {
                            Shelf(title: "Series") {
                                ForEach(series) { SeriesTile(series: $0) }
                            }
                        }
                    }
                    .padding(.vertical, 40)
                }
                .navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
            }
        }
        .sheet(item: $selectedMovie) { MovieDetailView(movie: $0) }
    }
}

struct Shelf<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title3.bold()).padding(.horizontal, 80)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 50) { content }
                    .padding(.horizontal, 80).padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
    }
}
