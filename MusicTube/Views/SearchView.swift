import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    searchHeader

                    if appState.isSearching, appState.searchResults.isEmpty {
                        statusCard(label: "Searching YouTube...")
                    } else if appState.searchResults.isEmpty {
                        statusCard(label: emptyStateMessage)
                    } else {
                        if appState.isSearching {
                            statusCard(label: "Refreshing results...")
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            Text("\(appState.searchResults.count) songs")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.white.opacity(0.6))

                            ForEach(appState.searchResults) { track in
                                TrackRowView(track: track) {
                                    appState.play(track: track, queue: appState.searchResults)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, bottomSpacing)
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
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
            .background(searchBackground.ignoresSafeArea())
        }
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search YouTube music, artists, and live sessions.")
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.62))

            if appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                Text("Results update as you type, and tapping a song starts the native background player.")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.48))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var bottomSpacing: CGFloat {
        appState.nowPlaying == nil ? 108 : 172
    }

    private var searchBackground: some View {
        LinearGradient(
            colors: [
                Color.black,
                Color(red: 0.04, green: 0.04, blue: 0.08)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func statusCard(label: String) -> some View {
        HStack(spacing: 10) {
            if appState.isSearching {
                ProgressView()
                    .tint(.white)
            }

            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
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
