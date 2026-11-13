import FlotionCore
import SwiftUI

struct SidebarView: View {
    let model: AppModel
    @State private var showTrash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44) // room for the window's traffic lights
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.children(of: nil)) { page in
                        PageRow(model: model, page: page, depth: 0)
                    }
                }
                .padding(.horizontal, 6)
            }
            VStack(alignment: .leading, spacing: 1) {
                SidebarButton(symbol: "plus", label: "New page") { Task { await model.newPage() } }
                SidebarButton(symbol: "trash", label: "Trash") { showTrash.toggle() }
                    .popover(isPresented: $showTrash, arrowEdge: .trailing) { TrashView(model: model) }
            }
            .padding(6)
        }
        .background(Color(nsColor: Theme.sidebar))
    }
}

private struct PageRow: View {
    let model: AppModel
    let page: Page
    let depth: Int
    @State private var hovering = false

    var body: some View {
        let children = model.children(of: page.id)
        let isOpen = model.expanded.contains(page.id)
        let isSelected = model.selectedPageID == page.id

        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Button {
                    if isOpen { model.expanded.remove(page.id) } else { model.expanded.insert(page.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(children.isEmpty ? 0.25 : 0.7)

                Text(page.icon ?? "📄").font(.system(size: 13))
                Text(page.title.isEmpty ? "Untitled" : page.title)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if hovering {
                    Button { Task { await model.newPage(under: page.id) } } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Add a page inside")
                }
            }
            .foregroundStyle(Color(nsColor: isSelected ? Theme.text : Theme.secondary))
            .padding(.leading, CGFloat(depth) * 14 + 2)
            .padding(.trailing, 4)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: isSelected || hovering ? Theme.hover : .clear)))
            .contentShape(Rectangle())
            .onTapGesture { Task { await model.open(page.id) } }
            .onHover { hovering = $0 }
            .contextMenu {
                Button("New Page Inside") { Task { await model.newPage(under: page.id) } }
                Divider()
                Button("Move to Trash") { Task { await model.archive(page.id) } }
            }
            .accessibilityIdentifier("page-row-\(page.title)")

            if isOpen {
                ForEach(children) { child in
                    PageRow(model: model, page: child, depth: depth + 1)
                }
            }
        }
    }
}

private struct SidebarButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 18)
                Text(label).font(.system(size: 14))
                Spacer()
            }
            .foregroundStyle(Color(nsColor: Theme.secondary))
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: hovering ? Theme.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct TrashView: View {
    let model: AppModel
    @State private var pendingDelete: Page?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Trash").font(.system(size: 13, weight: .semibold)).padding(.bottom, 4)
            if model.trash.isEmpty {
                Text("Pages you delete appear here.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(model.trash) { page in
                HStack {
                    Text(page.title.isEmpty ? "Untitled" : page.title).font(.system(size: 13)).lineLimit(1)
                    Spacer()
                    Button("Restore") { Task { await model.restore(page.id) } }
                    Button("Delete") { pendingDelete = page }
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .confirmationDialog("Delete “\(pendingDelete.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "")” permanently?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete Permanently", role: .destructive) {
                if let page = pendingDelete { Task { await model.deleteForever(page.id) } }
                pendingDelete = nil
            }
        } message: {
            Text("The page and its sub-pages will be removed for good. This cannot be undone.")
        }
    }
}
