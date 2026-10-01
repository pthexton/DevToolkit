import SwiftUI

struct SearchView: View {
    @ObservedObject var viewModel: SearchViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search apps, browser tabs, and terminal tabs...", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .focused($isFocused)

            ModePickerRow(mode: viewModel.mode) { viewModel.setMode($0) }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

            Divider()

            ScrollViewReader { proxy in
                List(Array(viewModel.results.enumerated()), id: \.element.id) { index, item in
                    ResultRow(item: item, isSelected: index == viewModel.selectedIndex)
                        .id(item.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.activate(at: index) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: viewModel.selectedIndex) { newValue in
                    guard viewModel.results.indices.contains(newValue) else { return }
                    proxy.scrollTo(viewModel.results[newValue].id, anchor: .center)
                }
                // The query/mode changing can reorder or replace the whole
                // results list while `selectedIndex` stays 0 throughout, so
                // that onChange above never fires and the scroll position
                // goes stale. Explicitly snap back to the top match whenever
                // the result set is recomputed for a new query or mode.
                .onChange(of: viewModel.query) { _ in
                    if let first = viewModel.results.first {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
                .onChange(of: viewModel.mode) { _ in
                    if let first = viewModel.results.first {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onChange(of: viewModel.focusToken) { _ in isFocused = true }
        .onExitCommand { viewModel.onCancel?() }
    }
}

private struct ModePickerRow: View {
    let mode: SearchMode
    let onSelect: (SearchMode) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SearchMode.allCases, id: \.self) { candidate in
                Button {
                    onSelect(candidate)
                } label: {
                    Text("\(candidate.label)  \(candidate.shortcutHint)")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(candidate == mode ? Color.accentColor.opacity(0.3) : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

private struct ResultRow: View {
    let item: SwitchItem
    let isSelected: Bool

    private var fallbackSystemImage: String {
        switch item.kind {
        case .app: return "app"
        case .browserTab: return "safari"
        case .terminalTab: return "terminal"
        case .command: return "arrow.up.right.square"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: fallbackSystemImage)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
