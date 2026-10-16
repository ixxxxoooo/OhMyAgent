// @author ixxxxoooo
// 输入区页脚的分支切换器(参考 kuku 的 GitBranchMenu):点击当前分支展开弹层,
// 支持搜索、切换本地/远程分支、基于当前提交新建分支。切换失败(如有冲突的未提交修改)时在弹层内给出原因。

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
            .background(Capsule().fill(hovering || shown ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { hovering = $0 }
        .help(isBusy ? LocalizedStringKey("Agent 运行中,暂不能切换分支") : LocalizedStringKey("切换分支"))
        .accessibilityLabel("切换分支")
        .accessibilityValue(head.displayName)
        .popover(isPresented: $shown, arrowEdge: .top) {
            BranchPicker(workspace: workspace, current: head) {
                shown = false
                onChanged()
            }
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

/// 分支弹层:搜索框 + 分支列表 + 新建。
private struct BranchPicker: View {
    let workspace: URL
    let current: GitHead
    let onDone: () -> Void

    @State private var branches: [GitBranch] = []
    @State private var query = ""
    @State private var loaded = false
    @State private var working = false
    @State private var errorText: String?
    @FocusState private var searchFocused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    /// 过滤后的本地分支(当前分支在前)。
    private var locals: [GitBranch] {
        BranchListing.filter(branches.filter { !$0.isRemote }, query: trimmed)
    }

    /// 没有同名本地分支的远程分支(切换时会创建并跟踪同名本地分支)。
    private var remotes: [GitBranch] {
        let localNames = Set(branches.filter { !$0.isRemote }.map(\.name))
        let candidates = branches.filter { $0.isRemote && !$0.name.hasSuffix("/HEAD") && !localNames.contains(BranchListing.localName(of: $0.name)) }
        return BranchListing.filter(candidates, query: trimmed)
    }

    private var canCreate: Bool {
        !trimmed.isEmpty && !branches.contains { $0.name == trimmed }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image.om("search", size: 12).foregroundStyle(OMColors.secondaryText)
                TextField("搜索或输入新分支名", text: $query)
                    .textFieldStyle(.plain)
                    .font(OMFonts.small)
                    .focused($searchFocused)
                    .onSubmit(submit)
                if working { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 10).frame(height: 32)
            Divider()
            list
            if let errorText {
                Divider()
                Text(errorText)
                    .font(OMFonts.caption).foregroundStyle(OMColors.warning)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .frame(width: 260)
        .task { await load() }
        .onAppear { searchFocused = true }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(locals) { branch in
                    row(branch.name, isCurrent: branch.isCurrent, subtitle: nil) { await switchTo(branch.name) }
                }
                if !remotes.isEmpty {
                    Text("远程分支").font(OMFonts.caption).foregroundStyle(OMColors.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                    ForEach(remotes) { branch in
                        row(branch.name, isCurrent: false, subtitle: nil) { await switchTo(BranchListing.localName(of: branch.name)) }
                    }
                }
                if canCreate {
                    row(String(localized: "新建分支 \(trimmed)"), isCurrent: false, subtitle: nil, icon: "plus", mono: false) { await create(trimmed) }
                } else if loaded, locals.isEmpty, remotes.isEmpty {
                    Text("没有匹配的分支").font(OMFonts.small).foregroundStyle(OMColors.secondaryText).padding(10)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(height: min(CGFloat(max(locals.count + remotes.count + (canCreate ? 1 : 0), 1)) * 28 + (remotes.isEmpty ? 8 : 34), 240))
    }

    private func row(_ title: String, isCurrent: Bool, subtitle: String?, icon: String = "git-branch", mono: Bool = true, action: @escaping () async -> Void) -> some View {
        BranchRow(title: title, isCurrent: isCurrent, icon: icon, mono: mono) { Task { await action() } }
            .disabled(working)
    }

    /// 回车:仅一个匹配时切换,没有匹配时新建。
    private func submit() {
        if canCreate, locals.isEmpty, remotes.isEmpty {
            Task { await create(trimmed) }
        } else if locals.count == 1, remotes.isEmpty, let only = locals.first, !only.isCurrent {
            Task { await switchTo(only.name) }
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

/// 分支列表行:图标 + 名称 + 当前分支对勾,悬停高亮。
private struct BranchRow: View {
    let title: String
    let isCurrent: Bool
    let icon: String
    let mono: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image.om(icon, size: 12).foregroundStyle(OMColors.secondaryText).frame(width: 14)
                Text(title)
                    .font(mono ? OMFonts.monoSmall : OMFonts.small)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isCurrent { Image.om("check", size: 12) }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Color.primary.opacity(0.07) : .clear).padding(.horizontal, 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
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
