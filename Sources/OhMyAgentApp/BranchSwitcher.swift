// @author ixxxxoooo
// 输入区页脚的分支切换器(参考 kuku 的 GitBranchMenu):点击当前分支展开弹层,
// 支持搜索、切换本地/远程分支、基于当前提交新建分支。切换失败(如有冲突的未提交修改)时在弹层内给出原因。

import ChatKit
import DesignSystem
import GitKit
import IconKit
import OMLog
import SwiftUI
import WorkbenchKit

/// 分支切换按钮 + 弹层。
struct BranchSwitcher: View {
    let workspace: URL
    let head: GitHead
    /// Agent 正在运行:此时切换分支会让工作区在 Agent 脚下改变,禁用并提示
    let isBusy: Bool
    /// 切换/新建成功后回调(用于刷新页脚显示的 HEAD)
    let onChanged: () -> Void
    @State private var shown = ProcessInfo.processInfo.environment["OMA_BRANCH_MENU"] != nil   // 调试钩子:启动即展开
    @State private var hovering = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 4) {
                Image.om("git-branch", size: 12)
                // 宽度随分支名自适应,过长才在 180pt 处中间省略(`frame(maxWidth:)` 会撑满上限,所以用自定义布局)
                ClampedWidth(maximum: 180) {
                    Text(head.displayName).lineLimit(1).truncationMode(.middle)
                }
                Image.om("chevron-down", size: 9).opacity(hovering || shown ? 0.9 : 0.5)
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(OMPillShape().fill(hovering || shown ? OMColors.hoverFill : .clear))
            .contentShape(OMPillShape())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { hovering = $0 }
        .help(isBusy ? LocalizedStringKey("Agent 运行中,暂不能切换分支") : LocalizedStringKey("切换分支"))
        .accessibilityLabel("切换分支")
        .accessibilityValue(head.displayName)
        .omCustomPicker(isPresented: $shown, width: 280) {
            BranchPicker(workspace: workspace, current: head) {
                shown = false
                onChanged()
            } onDismiss: { shown = false }
        }
    }
}

/// 宽度取「子视图理想宽度」与上限中较小者的布局:内容短时紧贴内容,过长时限制在上限内。
private struct ClampedWidth: Layout {
    /// 宽度上限
    let maximum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(.init(width: nil, height: proposal.height))
        let width = min(ideal.width, maximum, proposal.width ?? .infinity)
        return child.sizeThatFits(.init(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: .init(width: bounds.width, height: bounds.height))
    }
}

/// 分支选择器的一项。
private struct BranchPick: PickListItem {
    enum Kind { case local, remote, create }
    var id: String
    var name: String
    var kind: Kind
    var isCurrent = false

    var searchText: String { kind == .create ? "\(name) \(String(localized: "新建分支"))" : name }
    var group: String? { kind == .remote ? String(localized: "远程分支") : nil }
}

/// 分支弹层:搜索(可直接输入新分支名)+ 本地/远程分支列表 + 新建;↑↓ 切换、回车选中、Esc 关闭。
private struct BranchPicker: View {
    let workspace: URL
    let current: GitHead
    let onDone: () -> Void
    let onDismiss: () -> Void

    @State private var branches: [GitBranch] = []
    @State private var loaded = false
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            PickListContent(
                items: items(for: ""), selectedID: branches.first(where: \.isCurrent).map { "local:\($0.name)" },
                placeholder: String(localized: "搜索或输入新分支名"), maxListHeight: 240,
                emptyText: loaded ? String(localized: "没有匹配的分支") : String(localized: "正在读取分支…"),
                itemsForQuery: { items(for: $0) },
                row: { rowContent($0) }, onSelect: { pick in Task { await run(pick) } }, onDismiss: onDismiss
            )
            .id(loaded)
            .disabled(working)
            if let errorText {
                Divider()
                Text(errorText)
                    .font(OMFonts.caption).foregroundStyle(OMColors.warning)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .task { await load() }
    }

    /// 按查询词生成条目:本地分支 → 没有同名本地分支的远程分支 → 「新建分支」。
    private func items(for query: String) -> [BranchPick] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let locals = branches.filter { !$0.isRemote }.map { BranchPick(id: "local:\($0.name)", name: $0.name, kind: .local, isCurrent: $0.isCurrent) }
        let localNames = Set(branches.filter { !$0.isRemote }.map(\.name))
        let remotes = branches
            .filter { $0.isRemote && !$0.name.hasSuffix("/HEAD") && !localNames.contains(BranchListing.localName(of: $0.name)) }
            .map { BranchPick(id: "remote:\($0.name)", name: $0.name, kind: .remote) }
        var all = locals + remotes
        if !trimmed.isEmpty, !branches.contains(where: { $0.name == trimmed }) {
            all.append(BranchPick(id: "create:\(trimmed)", name: trimmed, kind: .create))
        }
        return all
    }

    private func rowContent(_ pick: BranchPick) -> some View {
        HStack(spacing: 8) {
            Image.om(pick.kind == .create ? "plus" : "git-branch", size: 12).foregroundStyle(OMColors.secondaryText).frame(width: 14)
            Text(pick.kind == .create ? String(localized: "新建分支 \(pick.name)") : pick.name)
                .font(pick.kind == .create ? OMFonts.small : OMFonts.monoSmall)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func run(_ pick: BranchPick) async {
        switch pick.kind {
        case .local:
            if pick.isCurrent { onDismiss() } else { await switchTo(pick.name) }
        case .remote: await switchTo(BranchListing.localName(of: pick.name))
        case .create: await create(pick.name)
        }
    }

    private func load() async {
        guard let repo = await GitRepository.discover(from: workspace.path) else {
            loaded = true
            errorText = String(localized: "当前目录不是 Git 仓库")
            return
        }
        do {
            branches = try await repo.branches()
        } catch {
            Log.git.error("读取分支列表失败", ["error": "\(error)"])
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        loaded = true
    }

    private func switchTo(_ name: String) async {
        await perform("切换分支") { try await $0.checkout(name) }
    }

    private func create(_ name: String) async {
        await perform("新建分支") { try await $0.createBranch(name, checkout: true) }
    }

    /// 执行一次分支操作;成功后关闭弹层,失败时保留弹层并显示原因。
    private func perform(_ title: String, _ body: @escaping @Sendable (GitRepository) async throws -> Void) async {
        guard !working, let repo = await GitRepository.discover(from: workspace.path) else { return }
        working = true
        errorText = nil
        defer { working = false }
        let started = ContinuousClock.now
        do {
            try await body(repo)
            Log.git.info("\(title)成功", ["ms": "\(OMLogger.milliseconds(since: started))"])
            onDone()
        } catch {
            Log.git.error("\(title)失败", ["error": "\(error)"])
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}

/// 分支列表的过滤与名称处理(纯函数,便于测试)。
enum BranchListing {
    /// 按关键字过滤(不区分大小写,空关键字返回全部)。
    static func filter(_ branches: [GitBranch], query: String) -> [GitBranch] {
        guard !query.isEmpty else { return branches }
        return branches.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// 远程分支 `origin/feature/x` 对应的本地分支名 `feature/x`。
    static func localName(of remote: String) -> String {
        remote.split(separator: "/", maxSplits: 1).last.map(String.init) ?? remote
    }
}
