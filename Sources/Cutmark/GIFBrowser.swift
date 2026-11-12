import AppKit
import SwiftUI

struct GIFBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let add: (CommonsGIFCatalog.Item, Data) async throws -> Void

    private struct Search: Equatable {
        var query = ""
        var offset = 0
        var attempt = 0
    }

    @State private var query = ""
    @State private var request = Search()
    @State private var items: [CommonsGIFCatalog.Item] = []
    @State private var nextOffset: Int?
    @State private var selected: CommonsGIFCatalog.Item?
    @State private var preview: NSImage?
    @State private var loading = true
    @State private var searchError: String?
    @State private var previewError: String?
    @State private var addError: String?
    @State private var pending: CommonsGIFCatalog.Item?
    private let catalog = CommonsGIFCatalog()

    var body: some View {
        VStack(spacing: 0) {
            header
            Rule()
            HStack(spacing: 0) {
                results.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rule(vertical: true)
                detail.frame(width: 235)
            }
        }
        .frame(width: 660, height: 490)
        .background(Theme.paper).foregroundStyle(Theme.ink)
        .task(id: request) { await load(request) }
        .task(id: selected?.id) { await loadPreview(selected) }
        .task(id: pending?.id) {
            guard let item = pending else { return }
            await insert(item)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("GIFs").font(Theme.display(24))
                Text("Wikimedia Commons").font(Theme.sans(12)).foregroundStyle(Theme.muted)
                Spacer()
                Button(pending == nil ? "Done" : "Cancel") { dismiss() }.buttonStyle(AccentButtonStyle(kind: .quiet))
            }
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted).accessibilityHidden(true)
                    TextField("Search GIFs", text: $query).textFieldStyle(.plain).font(Theme.sans(13))
                        .onSubmit { submit(query) }
                    if !query.isEmpty {
                        Button {
                            query = ""; submit("")
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                    }
                }.padding(9).background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                Button("Search") { submit(query) }.buttonStyle(AccentButtonStyle(kind: .quiet))
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(pending != nil)
        }.padding(16)
    }

    private var results: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if request.query.isEmpty {
                    Text("Featured").font(Theme.sans(13, .semibold))
                }
                if !items.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 10)], spacing: 10) {
                        ForEach(items) { item in tile(item) }
                    }
                }
                if loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 18)
                        .accessibilityLabel("Loading GIFs")
                } else if let searchError {
                    Text(searchError).font(Theme.sans(12)).foregroundStyle(Theme.muted)
                    Button("Try again") { request.attempt += 1 }.buttonStyle(AccentButtonStyle(kind: .quiet))
                } else if items.isEmpty {
                    Text("No matching GIFs").font(Theme.sans(13, .semibold))
                    Text("Try a different search or browse more results.").font(Theme.sans(12)).foregroundStyle(Theme.muted)
                }
                if !loading, searchError == nil, let nextOffset {
                    Button("More results") { request.offset = nextOffset }.buttonStyle(AccentButtonStyle(kind: .quiet))
                }
            }.padding(14)
        }.background(Theme.canvas).disabled(pending != nil)
    }

    private func tile(_ item: CommonsGIFCatalog.Item) -> some View {
        Button {
            guard selected?.id != item.id else { return }
            selected = item; preview = nil; previewError = nil; addError = nil
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                GIFThumbnail(item: item, catalog: catalog)
                .frame(maxWidth: .infinity).frame(height: 76)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(item.title).font(Theme.sans(11, .medium)).lineLimit(1)
            }.padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected?.id == item.id ? Theme.accent.opacity(0.14) : Theme.paper,
                        in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help(item.title)
            .accessibilityLabel(item.title).accessibilityAddTraits(selected?.id == item.id ? .isSelected : [])
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let item = selected {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.surface)
                    if let preview {
                        AnimatedGIFImage(image: preview, animated: !reduceMotion)
                    } else if previewError != nil {
                        Image(systemName: "film").foregroundStyle(Theme.muted)
                    } else {
                        ProgressView().controlSize(.small).accessibilityLabel("Loading GIF preview")
                    }
                }.frame(maxWidth: .infinity).frame(height: 142).clipped().accessibilityLabel("GIF preview")
                Text(item.title).font(Theme.sans(14, .semibold)).lineLimit(2).help(item.title)
                Link(destination: item.source) {
                    Label(item.license, systemImage: "arrow.up.right").font(Theme.sans(11, .medium))
                }.help("View the original file and license on Wikimedia Commons")
                if let error = addError ?? previewError {
                    Text(error).font(Theme.sans(11)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    addError = nil; pending = item
                } label: {
                    Label(pending == nil ? "Add to timeline" : "Adding GIF…", systemImage: "plus")
                }.buttonStyle(AccentButtonStyle(kind: .solid)).disabled(pending != nil)
            } else {
                Text("Select a GIF to preview it.").font(Theme.sans(13)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }.padding(14).frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func submit(_ query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        items = []; selected = nil; preview = nil; nextOffset = nil
        request = Search(query: term, attempt: request.attempt + 1)
    }

    private func load(_ request: Search) async {
        loading = true; searchError = nil
        do {
            let page = try await catalog.search(query: request.query, offset: request.offset)
            try Task.checkCancellation()
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            nextOffset = page.nextOffset.flatMap { $0 > request.offset ? $0 : nil }
            if selected == nil { selected = items.first }
        } catch {
            guard !Task.isCancelled else { return }
            searchError = CommonsGIFCatalog.Failure.unavailable.localizedDescription
        }
        loading = false
    }

    private func loadPreview(_ item: CommonsGIFCatalog.Item?) async {
        guard let item else { return }
        do {
            let data = try await catalog.animation(for: item, preview: true)
            try Task.checkCancellation()
            guard let image = NSImage(data: data) else { throw CommonsGIFCatalog.Failure.unreadable }
            preview = image
        } catch {
            guard !Task.isCancelled else { return }
            previewError = "Preview unavailable. You can still try adding this GIF."
        }
    }

    private func insert(_ item: CommonsGIFCatalog.Item) async {
        do {
            let data = try await catalog.animation(for: item, preview: false)
            try Task.checkCancellation()
            try await add(item, data)
            dismiss()
        } catch {
            guard !Task.isCancelled else { return }
            addError = error.localizedDescription
            pending = nil
        }
    }
}

private struct GIFThumbnail: View {
    let item: CommonsGIFCatalog.Item
    let catalog: CommonsGIFCatalog
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Image(systemName: "film").foregroundStyle(Theme.muted) }
        }.task(id: item.id) {
            if let result = try? await catalog.thumbnail(for: item), !Task.isCancelled { image = result }
        }.accessibilityHidden(true)
    }
}

private struct AnimatedGIFImage: NSViewRepresentable {
    let image: NSImage
    let animated: Bool

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        view.animates = animated
        if view.image !== image { view.image = image }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}
