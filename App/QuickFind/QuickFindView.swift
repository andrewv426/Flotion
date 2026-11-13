import FlotionCore
import SwiftUI

/// ⌘K: jump to any page by title or content. Results update on every keystroke.
struct QuickFindView: View {
    let model: AppModel
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var index = 0
    @FocusState private var focused: Bool

    /// With nothing typed, offer the most recently edited pages.
    private var rows: [SearchHit] {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return hits }
        return model.pages.sorted { $0.updatedAt > $1.updatedAt }.prefix(7).map {
            SearchHit(pageID: $0.id, pageTitle: $0.title, blockID: nil, snippet: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color(nsColor: Theme.secondary))
                TextField("Search pages…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { open(index) }
                    .accessibilityIdentifier("quick-find-field")
            }
            .padding(14)

            if !rows.isEmpty {
                Rectangle().fill(Color(nsColor: Theme.divider)).frame(height: 1)
                VStack(spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, hit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.pageTitle.isEmpty ? "Untitled" : hit.pageTitle).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            if !hit.snippet.isEmpty {
                                Text(hit.snippet).font(.system(size: 12)).foregroundStyle(Color(nsColor: Theme.secondary)).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: i == index ? Theme.hover : .clear)))
                        .contentShape(Rectangle())
                        .onTapGesture { open(i) }
                    }
                }
                .padding(6)
            } else if !query.isEmpty {
                Text("No pages match").font(.system(size: 13)).foregroundStyle(Color(nsColor: Theme.secondary)).padding(14)
            }
        }
        .foregroundStyle(Color(nsColor: Theme.text))
        .frame(width: 560)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: Theme.page)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: Theme.divider), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear { focused = true }
        .onChange(of: query) { search() }
        .onKeyPress(.downArrow) { index = min(index + 1, max(0, rows.count - 1)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { model.showQuickFind = false; return .handled }
    }

    private func search() {
        guard let workspace = model.workspace else { return }
        let current = query
        Task {
            let interval = signposter.beginInterval("search")
            let found = (try? await Task.detached { try workspace.search(current, limit: 8) }.value) ?? []
            signposter.endInterval("search", interval)
            // A slower, older query must not overwrite the results of a newer one.
            if current == query {
                hits = found
                index = 0
            }
        }
    }

    private func open(_ i: Int) {
        guard rows.indices.contains(i) else { return }
        let pageID = rows[i].pageID
        model.showQuickFind = false
        Task { await model.reveal(pageID) }
    }
}
