import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selectedMovie: Movie?

    var body: some View {
        NavigationStack {
            let q = query.trimmingCharacters(in: .whitespaces)
            let results = search(q)
            ScrollView {
                VStack(alignment: .leading, spacing: 50) {
                    if q.count < 2 {
                        EmptyStateView(systemImage: "magnifyingglass", title: "Search channels, movies and series")
                    } else if results.channels.isEmpty && results.movies.isEmpty && results.series.isEmpty {
                        EmptyStateView(systemImage: "magnifyingglass", title: "No results for “\(q)”")
                    } else {
                        if !results.channels.isEmpty {
                            Shelf(title: "Channels") {
                                ForEach(results.channels) { ch in
                                    VStack(spacing: 12) {
                                        Button { model.play(channel: ch, in: results.channels) } label: {
                                            ChannelLogo(url: ch.logoURL, name: ch.name).frame(width: 300, height: 170)
                                        }
                                        .buttonStyle(.card)
                                        Text(ch.name).font(.caption).lineLimit(1).frame(width: 300)
                                    }
                                }
                            }
                        }
                        if !results.movies.isEmpty {
                            Shelf(title: "Movies") {
                                ForEach(results.movies) { m in
                                    PosterButton(title: m.name, imageURL: m.posterURL) { selectedMovie = m }
                                }
                            }
                        }
                        if !results.series.isEmpty {
                            Shelf(title: "Series") {
                                ForEach(results.series) { SeriesTile(series: $0) }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Channels, movies, series")
            .navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
        }
        .sheet(item: $selectedMovie) { MovieDetailView(movie: $0) }
    }

    private func search(_ q: String) -> (channels: [Channel], movies: [Movie], series: [Series]) {
        guard q.count >= 2, let catalog = model.catalog else { return ([], [], []) }
        func match(_ s: String) -> Bool { s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return (Array(catalog.live.lazy.filter { match($0.name) }.prefix(60)),
                Array(catalog.movies.lazy.filter { match($0.name) }.prefix(60)),
                Array(catalog.series.lazy.filter { match($0.name) }.prefix(60)))
    }
}
