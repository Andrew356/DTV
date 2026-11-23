import SwiftUI

struct MoviesView: View {
    @Environment(AppModel.self) private var model
    @State private var group = Groups.all
    @State private var selected: Movie?

    private let columns = [GridItem(.adaptive(minimum: 250, maximum: 250), spacing: 50, alignment: .top)]

    private var movies: [Movie] {
        guard let catalog = model.catalog else { return [] }
        switch group {
        case Groups.all: return catalog.movies
        case Groups.favorites: return model.favoriteMovies
        default: return catalog.movies.filter { $0.group == group }
        }
    }

    var body: some View {
        if let catalog = model.catalog {
            if catalog.movies.isEmpty {
                EmptyStateView(systemImage: "film", title: "No movies in this source")
            } else {
                HStack(alignment: .top, spacing: 0) {
                    CategorySidebar(groups: catalog.movieGroups,
                                    counts: Dictionary(grouping: catalog.movies, by: \.group).mapValues(\.count),
                                    extras: [Groups.all, Groups.favorites], selection: $group)
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 60) {
                            ForEach(movies) { movie in
                                PosterButton(title: movie.name, imageURL: movie.posterURL,
                                             subtitle: movie.year ?? movie.rating.map { "★ \($0)" },
                                             progress: model.progress(for: movie.id)?.fraction,
                                             isFavorite: model.isFavorite(.movie, movie.id)) {
                                    selected = movie
                                }
                            }
                        }
                        .padding(40)
                    }
                }
                .sheet(item: $selected) { MovieDetailView(movie: $0) }
            }
        } else {
            Color.clear
        }
    }
}

struct MovieDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let movie: Movie

    var body: some View {
        let saved = model.progress(for: movie.id)
        let favorite = model.isFavorite(.movie, movie.id)
        HStack(alignment: .top, spacing: 60) {
            PosterCard(title: movie.name, imageURL: movie.posterURL).scaleEffect(1.3).padding(60)
            VStack(alignment: .leading, spacing: 24) {
                Text(movie.name).font(.title.bold())
                HStack(spacing: 20) {
                    if let year = movie.year { Text(year) }
                    if let rating = movie.rating { Text("★ \(rating)") }
                    Text(movie.group)
                }
                .foregroundStyle(.secondary)
                if let plot = movie.plot { Text(plot).lineLimit(8) }
                HStack(spacing: 30) {
                    if let saved, !saved.isFinished, saved.position > 30 {
                        Button { dismiss(); model.play(movie: movie, resume: true) } label: {
                            Label("Resume \(Self.format(saved.position))", systemImage: "play.fill")
                        }
                        Button { dismiss(); model.play(movie: movie, resume: false) } label: {
                            Label("From Beginning", systemImage: "arrow.counterclockwise")
                        }
                    } else {
                        Button { dismiss(); model.play(movie: movie, resume: false) } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                    }
                    Button {
                        model.toggleFavorite(kind: .movie, id: movie.id, name: movie.name, image: movie.posterURL)
                    } label: {
                        Label(favorite ? "Favorited" : "Favorite", systemImage: favorite ? "heart.fill" : "heart")
                    }
                }
                .padding(.top, 20)
            }
            Spacer()
        }
        .padding(80)
    }

    static func format(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}
