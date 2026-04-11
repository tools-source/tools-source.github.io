import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                if appState.searchResults.isEmpty {
                    Text(emptyStateMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.searchResults) { track in
                        TrackRowView(track: track) {
                            appState.play(track: track, queue: appState.searchResults)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Search")
            .searchable(text: $appState.searchQuery, prompt: "Artists, songs, videos")
            .onSubmit(of: .search) {
                Task {
                    await appState.performSearch()
                }
            }
            .onChange(of: appState.searchQuery) { _, newValue in
                if newValue.isEmpty {
                    appState.searchResults = []
                }
            }
        }
    }

    private var emptyStateMessage: String {
        if appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Search YouTube music"
        }

        return "No results are available right now."
    }
}
