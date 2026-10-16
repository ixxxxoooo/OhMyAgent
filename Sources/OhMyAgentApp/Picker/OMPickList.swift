// @author ixxxxoooo
// 统一选择列表 `OMPickList`:顶部搜索、↑↓ 切换高亮、回车选中、Esc 关闭、当前项右侧打勾。
// 行为逻辑在 `ChatKit.PickListState`(可单测),这里只负责渲染与按键转发。
// 模型、模式、思考强度、Git 分支、面包屑、Agent、标签溢出、日志级别等下拉选择都用它。

import ChatKit
import DesignSystem
import IconKit
import SwiftUI

/// 选择列表内容(搜索框 + 分组列表)。
struct PickListContent<Item: PickListItem, Row: View>: View {
    @State private var state: PickListState<Item>
    private let placeholder: String
    private let showsSearch: Bool
    private let maxListHeight: CGFloat
    private let emptyText: String
    private let row: (Item) -> Row
    private let itemsForQuery: ((String) -> [Item])?
    private let onSelect: (Item) -> Void
    private let onDismiss: () -> Void
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    /// - Parameters:
    ///   - items: 条目
    ///   - selectedID: 当前选中项(打勾,初始高亮)
    ///   - placeholder: 搜索框占位文案
    ///   - showsSearch: 是否显示搜索框(隐藏时仍可用键盘导航)
    ///   - maxListHeight: 列表最大高度,超出滚动
    ///   - emptyText: 无匹配项时的提示
    ///   - itemsForQuery: 可选:随查询词动态生成条目(例如「新建分支 xxx」);设置后每次查询变化都会重建条目
    ///   - row: 行内容(不含高亮底与对勾)
    ///   - onSelect: 选中回调(回车或点击)
    ///   - onDismiss: 关闭回调(Esc)
    init(items: [Item], selectedID: String?, placeholder: String, showsSearch: Bool = true, maxListHeight: CGFloat = 300,
         emptyText: String = String(localized: "没有匹配项"), itemsForQuery: ((String) -> [Item])? = nil,
         @ViewBuilder row: @escaping (Item) -> Row,
         onSelect: @escaping (Item) -> Void, onDismiss: @escaping () -> Void) {
        _state = State(initialValue: PickListState(items: items, selectedID: selectedID))
        self.placeholder = placeholder
        self.showsSearch = showsSearch
        self.maxListHeight = maxListHeight
        self.emptyText = emptyText
        self.row = row
        self.itemsForQuery = itemsForQuery
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsSearch {
                HStack(spacing: 6) {
                    Image.om("search", size: 12).foregroundStyle(OMColors.tertiaryText)
                    TextField(placeholder, text: $state.query)
                        .textFieldStyle(.plain)
                        .font(OMFonts.small)
                        .focused($searchFocused)
                        .onSubmit { confirm() }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                Divider()
            }
            list
        }
        .contentShape(Rectangle())
        .focusable(!showsSearch)
        .focused($listFocused)
        .onKeyPress(.upArrow) { state.move(-1); return .handled }
        .onKeyPress(.downArrow) { state.move(1); return .handled }
        .onKeyPress(.escape) { onDismiss(); return .handled }
        .onKeyPress(.return) { confirm(); return .handled }
        .onChange(of: state.query) { _, query in
            if let itemsForQuery { state.setItems(itemsForQuery(query)) }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(40))
            if showsSearch { searchFocused = true } else { listFocused = true }
        }
        .accessibilityElement(children: .contain)
    }

    private func confirm() {
        guard let item = state.highlighted else { return }
        onSelect(item)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.visible.enumerated()), id: \.element.id) { index, item in
                        if let group = item.group, index == 0 || state.visible[index - 1].group != group {
                            Text(verbatim: group).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                                .padding(.horizontal, 12).padding(.top, index == 0 ? 6 : 10).padding(.bottom, 2)
                        }
                        rowView(item).id(item.id)
                    }
                    if state.visible.isEmpty {
                        Text(verbatim: emptyText).font(OMFonts.small).foregroundStyle(OMColors.secondaryText).padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: maxListHeight)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: state.highlightedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func rowView(_ item: Item) -> some View {
        let highlighted = state.highlightedID == item.id
        return HStack(spacing: 7) {
            row(item)
            Spacer(minLength: 4)
            if state.selectedID == item.id { Image.om("check", size: 12).foregroundStyle(OMColors.accent) }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
        .background(highlighted ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 4)
        .opacity(item.isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .onHover { inside in if inside { state.highlight(item.id) } }
        .onTapGesture { if item.isEnabled { onSelect(item) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(state.selectedID == item.id ? [.isButton, .isSelected] : .isButton)
    }
}

/// 最常用的行:可选图标 + 标题 + 弱化副标题。
struct PickRowLabel<Icon: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 7) {
            icon
            Text(verbatim: title).font(OMFonts.small).lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(verbatim: subtitle).font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText).lineLimit(1)
            }
        }
    }
}

extension PickRowLabel where Icon == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.icon = EmptyView()
    }
}

/// 通用条目:只有标题/副标题/分组,适用于大多数简单选择(模式、思考强度、日志级别、Agent…)。
struct PickEntry: PickListItem, Equatable {
    var id: String
    var title: String
    var subtitle: String?
    var group: String?
    var isEnabled = true
    /// 可选的图标语义名(Lucide)
    var icon: String?

    var searchText: String { [title, subtitle ?? "", id].joined(separator: " ") }
}
