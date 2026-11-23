import SwiftUI

struct SeriesListView: View {
    @Environment(AppModel.self) private var model
    @State private var group = Groups.all

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 250), spacing: 50, alignment: .top)]

    private var items: [Series] {
        guard let catalog = model.catalog else { return [] }
        switch group {
        case Groups.all: return catalog.series
        case Groups.favorites: return model.favoriteSeries
        default: return catalog.series.filter { $0.group == group }
        }
    }

    var body: some View {
        NavigationStack {
            if let catalog = model.catalog {
                if catalog.series.isEmpty {
                    EmptyStateView(systemImage: "play.square.stack", title: "No series in this source")
                } else {
                    HStack(alignment: .top, spacing: 0) {
                        CategorySidebar(groups: catalog.seriesGroups,
                                        counts: Dictionary(grouping: catalog.series, by: \.group).mapValues(\.count),
                                        extras: [Groups.all, Groups.favorites], selection: $group)
                        ScrollView {
                            LazyVGrid(columns: columns, spacing: 60) {
                                ForEach(items) { series in
                                    SeriesTile(series: series)
                                }
                            }
                            .padding(40)
                        }
                    }
                    .navigationDestination(for: Series.self) { SeriesDetailView(series: $0) }
                }
            } else {
                Color.clear
            }
        }
    }
}

struct SeriesTile: View {
    @Environment(AppModel.self) private var model
    let series: Series

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: series) {
                PosterCard(title: series.name, imageURL: series.coverURL, isFavorite: model.isFavorite(.series, series.id))
            }
            .buttonStyle(.card)
            Text(series.name).font(.caption).lineLimit(2).frame(width: 250, alignment: .leading)
        }
    }
}

struct SeriesDetailView: View {
    @Environment(AppModel.self) private var model
    let series: Series

    @State private var episodes: [Episode] = []
    @State private var season: Int = 1
    @State private var loading = true
    @State private var error: String?

    private var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }

    var body: some View {
        let favorite = model.isFavorite(.series, series.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                HStack(alignment: .top, spacing: 50) {
                    PosterCard(title: series.name, imageURL: series.coverURL)
                    VStack(alignment: .leading, spacing: 18) {
                        Text(series.name).font(.title.bold())
                        HStack(spacing: 20) {
                            if let d = series.releaseDate { Text(d) }
                            if let r = series.rating { Text("★ \(r)") }
                            if let g = series.genre { Text(g) }
                        }
                        .foregroundStyle(.secondary)
                        if let plot = series.plot { Text(plot).lineLimit(6) }
                        HStack(spacing: 30) {
                            if let next = nextEpisode {
                                Button { model.play(episode: next, of: series) } label: {
                                    Label("Play S\(next.season)E\(next.number)", systemImage: "play.fill")
                                }
                            }
                            Button {
                                model.toggleFavorite(kind: .series, id: series.id, name: series.name, image: series.coverURL)
                            } label: {
                                Label(favorite ? "Favorited" : "Favorite", systemImage: favorite ? "heart.fill" : "heart")
                            }
                        }
                    }
                }

                if loading {
                    ProgressView("Loading episodes…")
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    if seasons.count > 1 {
                        ScrollView(.horizontal) {
                            HStack(spacing: 20) {
                                ForEach(seasons, id: \.self) { s in
                                    Button("Season \(s)") { season = s }
                                        .tint(s == season ? Color.accentColor : Color.gray)
                                }
                            }
                            .padding(.vertical, 20)
                        }
                    }
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(episodes.filter { $0.season == season }) { ep in
                            EpisodeRow(episode: ep, series: series)
                        }
                    }
                }
            }
            .padding(60)
        }
        .task {
            do {
                episodes = try await model.episodes(for: series)
                season = nextEpisode?.season ?? seasons.first ?? 1
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    /// First unfinished episode after the most recently watched one.
    private var nextEpisode: Episode? {
        let watched = episodes.compactMap { ep in model.progress(for: ep.id).map { (ep, $0) } }
            .max { $0.1.updatedAt < $1.1.updatedAt }
        guard let watched else { return episodes.first }
        let (last, progress) = watched
        if !progress.isFinished { return last }
        guard let idx = episodes.firstIndex(of: last), idx + 1 < episodes.count else { return last }
        return episodes[idx + 1]
    }
}

struct EpisodeRow: View {
    @Environment(AppModel.self) private var model
    let episode: Episode
    let series: Series

    var body: some View {
        let progress = model.progress(for: episode.id)
        Button { model.play(episode: episode, of: series) } label: {
            HStack(spacing: 30) {
                AsyncImage(url: episode.imageURL ?? series.coverURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { Rectangle().fill(.white.opacity(0.06)) }
                }
                .frame(width: 320, height: 180).clipped().cornerRadius(10)
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(episode.number). \(episode.title)").font(.headline).lineLimit(1)
                    if let plot = episode.plot { Text(plot).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    if let progress, progress.position > 0 {
                        ProgressView(value: progress.fraction).frame(maxWidth: 400)
                    }
                }
                Spacer()
                if let secs = episode.durationSeconds, secs > 0 {
                    Text("\(secs / 60) min").font(.caption).foregroundStyle(.secondary)
                }
                if progress?.isFinished == true {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .padding(16)
        }
        .buttonStyle(.card)
    }
}
