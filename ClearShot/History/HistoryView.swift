import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            window = WindowFactory.make(title: "History", size: CGSize(width: 980, height: 660), minSize: CGSize(width: 720, height: 460), autosaveName: "History") {
                HistoryView()
            }
        }
        if let window { WindowFactory.present(window) }
    }
}

private enum HistoryFilter: String, CaseIterable {
    case all, screenshots, text

    var title: String {
        switch self {
        case .all: "All captures"
        case .screenshots: "Screenshots"
        case .text: "Text"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .screenshots: "photo"
        case .text: "text.viewfinder"
        }
    }

    func matches(_ record: CaptureRecord) -> Bool {
        switch self {
        case .all: true
        case .screenshots: record.kind == .screenshot
        case .text: record.kind == .text
        }
    }
}

struct HistoryView: View {
    @State private var filter: HistoryFilter = .all
    @State private var query = ""
    private let history = HistoryStore.shared

    private var filtered: [CaptureRecord] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return history.records.filter { record in
            guard filter.matches(record) else { return false }
            guard !needle.isEmpty else { return true }
            return (record.text?.lowercased().contains(needle) ?? false) || record.baseName.lowercased().contains(needle)
        }
    }

    private var sections: [(title: String, records: [CaptureRecord])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            (Self.dayTitle(day), grouped[day]!.sorted { $0.date > $1.date })
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ShadSeparator(vertical: true)
            VStack(spacing: 0) {
                header
                ShadSeparator()
                if filtered.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .background(Theme.background)
        }
        .background(Theme.background)
        .ignoresSafeArea()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            TitlebarSpacer()
            ForEach(HistoryFilter.allCases, id: \.self) { item in
                SidebarButton(
                    title: item.title, symbol: item.symbol, selected: filter == item,
                    count: history.records.filter(item.matches).count
                ) { filter = item }
            }
            Spacer()
            Button {
                SettingsWindowController.shared.show(.history)
            } label: {
                Label("History settings", systemImage: "gearshape")
            }
            .buttonStyle(.shad(.ghost, size: .sm))
            .padding(.bottom, Space.md)
        }
        .padding(.horizontal, Space.md)
        .frame(width: 208)
        .background(Theme.muted.opacity(0.5))
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            Text(filter.title)
                .textStyle(.title3)
                .foregroundStyle(Theme.foreground)
            Spacer()
            ShadTextField(placeholder: "Search text in captures", text: $query, icon: "magnifyingglass")
                .frame(width: 260)
        }
        .padding(.horizontal, Space.xl)
        .frame(height: WindowMetrics.titleBand)
        .gesture(WindowDragGesture())
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: Space.lg)],
                alignment: .leading,
                spacing: Space.lg,
                pinnedViews: []
            ) {
                ForEach(sections, id: \.title) { section in
                    Section {
                        ForEach(section.records) { record in
                            HistoryCard(record: record, highlight: query)
                        }
                    } header: {
                        Text(section.title)
                            .font(.jakarta(12, .semibold))
                            .foregroundStyle(Theme.mutedForeground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Space.sm)
                    }
                }
            }
            .padding(Space.xl)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Space.lg) {
            Spacer()
            if !query.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.mutedForeground)
                Text("Nothing matches “\(query)”")
                    .textStyle(.title3)
                    .foregroundStyle(Theme.foreground)
                Text("Search looks at text recognized inside every capture.")
                    .textStyle(.body)
                    .foregroundStyle(Theme.mutedForeground)
            } else {
                Text(filter == .text ? "No text captures yet" : "No captures yet")
                    .textStyle(.title3)
                    .foregroundStyle(Theme.foreground)
                VStack(alignment: .leading, spacing: Space.md) {
                    ForEach([HotkeyAction.captureArea, .captureText], id: \.self) { action in
                        HStack(spacing: Space.md) {
                            HStack(spacing: 4) {
                                ForEach(Array((Preferences.shared.shortcuts[action] ?? .none).glyphs.enumerated()), id: \.offset) { _, glyph in
                                    Kbd(keys: glyph)
                                }
                            }
                            .frame(width: 120, alignment: .trailing)
                            Text(action == .captureText ? "copies text from anything on screen" : "captures an area of the screen")
                                .textStyle(.body)
                                .foregroundStyle(Theme.mutedForeground)
                        }
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

private struct HistoryCard: View {
    let record: CaptureRecord
    let highlight: String

    @State private var image: NSImage?
    @State private var hovering = false
    private let app = AppController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Theme.muted
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                }
                if hovering {
                    Rectangle().fill(.black.opacity(0.35)).transition(.opacity)
                    HStack(spacing: 6) {
                        if record.kind == .text, let text = record.text {
                            Button("Copy text") {
                                Clipboard.copy(text: text)
                                ToastCenter.shared.show(.success, "Text copied", detail: text.singleLinePreview)
                            }
                            .buttonStyle(.shad(.secondary, size: .sm))
                        } else {
                            Button("Copy") { Task { await app.copy(record) } }
                                .buttonStyle(.shad(.secondary, size: .sm))
                            IconButton(symbol: "pencil.tip", help: "Annotate", size: .iconSm, variant: .secondary) { app.annotate(record) }
                        }
                        IconButton(symbol: "pin", help: "Pin to screen", size: .iconSm, variant: .secondary) { app.pin(record) }
                    }
                    .environment(\.colorScheme, .light)
                    .transition(.opacity)
                }
            }
            .frame(height: 150)
            .clipped()

            ShadSeparator()

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.date.formatted(date: .omitted, time: .shortened))
                        .font(.jakarta(12, .semibold))
                        .foregroundStyle(Theme.foreground)
                    if record.isAnnotated {
                        Image(systemName: "pencil.tip")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.mutedForeground)
                    }
                    Spacer()
                    Text("\(record.pixelWidth) × \(record.pixelHeight)")
                        .font(.jakarta(11, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.mutedForeground)
                }
                Text(snippet)
                    .textStyle(.footnote)
                    .foregroundStyle(Theme.mutedForeground)
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, 10)
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(hovering ? Theme.input : Theme.border, lineWidth: 1)
        )
        .shadowSm()
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(Motion.quick) { hovering = inside } }
        .onTapGesture(count: 2) { app.annotate(record) }
        .onDrag {
            NSItemProvider(contentsOf: HistoryStore.shared.imageURL(for: record)) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Copy Image") { Task { await app.copy(record) } }
            if let text = record.text, !text.isEmpty {
                Button("Copy Text") { Clipboard.copy(text: text) }
            }
            Button("Annotate") { app.annotate(record) }
            Button("Pin to Screen") { app.pin(record) }
            Button("Save to Folder") { Task { await app.export(record) } }
            Button("Show in Finder") { app.revealInFinder(record) }
            Divider()
            Button("Delete", role: .destructive) { HistoryStore.shared.delete(record.id) }
        }
        .task(id: record) { image = await HistoryStore.shared.thumbnail(for: record) }
    }

    private var snippet: String {
        guard let text = record.text, !text.isEmpty else {
            return record.kind == .text ? "No text" : "Screenshot"
        }
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let needle = highlight.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty, let range = flat.range(of: needle, options: .caseInsensitive) {
            let start = flat.index(range.lowerBound, offsetBy: -24, limitedBy: flat.startIndex) ?? flat.startIndex
            return (start == flat.startIndex ? "" : "…") + flat[start...]
        }
        return flat
    }
}
