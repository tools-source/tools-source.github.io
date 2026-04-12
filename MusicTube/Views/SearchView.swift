import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                if appState.isSearching, appState.searchResults.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching YouTube...")
                            .foregroundStyle(.secondary)
                    }
                } else if appState.searchResults.isEmpty {
                    Text(emptyStateMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    if appState.isSearching {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Refreshing results...")
                                .foregroundStyle(.secondary)
                        }
                    }

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
                scheduleSearch(for: appState.searchQuery, immediately: true)
            }
            .onChange(of: appState.searchQuery) { _, newValue in
                scheduleSearch(for: newValue)
            }
            .onDisappear {
                searchTask?.cancel()
            }
        }
    }

    private var emptyStateMessage: String {
        if appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Search YouTube music"
        }

        if appState.isSearching {
            return "Searching..."
        }

        return "No songs matched that search."
    }

    private func scheduleSearch(for query: String, immediately: Bool = false) {
        searchTask?.cancel()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else {
            appState.clearSearch()
            return
        }

        searchTask = Task {
            if immediately == false {
                try? await Task.sleep(nanoseconds: 350_000_000)
            }

            guard Task.isCancelled == false else { return }
            _ = await appState.search(query: trimmedQuery)
        }
    }
}
