// @author ixxxxoooo
// IDE 分支切换器(对齐 VS Code「签出到…」):点击状态栏分支,在命令面板里列出
// 创建分支、本地分支、远程分支与标签,选中即切换;分支名带最近提交的时间、作者、哈希与说明。

import DesignSystem
import GitKit
import OMLog

extension IDEWorkspace {
    /// 打开分支/标签选择器。非 Git 仓库时不做任何事。
    func showBranchPicker() {
        guard let root else { return }
        let git = GitStore.shared.model(for: root)
        guard let repo = git.repo else { return }
        Task { [weak self] in
            guard let self else { return }
            async let branchList = try? repo.branches()
            async let tagList = try? repo.tags()
            let refs = (await branchList ?? []) + (await tagList ?? [])
            paletteActions = [:]
            var items = [
                branchAction("create", String(localized: "创建新分支…"), "plus") { [weak self] in self?.promptNewBranch(git: git, base: nil) },
                branchAction("createFrom", String(localized: "创建新分支依据…"), "plus") { [weak self] in self?.showBaseRefPicker(git: git, refs: refs) },
                branchAction("detach", String(localized: "签出已分离…"), "plug") { [weak self] in self?.showDetachPicker(git: git, refs: refs) },
            ]
            items += refs.map { ref in
                branchAction(ref.id, ref.name, ref.isTag ? "tag" : ref.isRemote ? "cloud" : "git-branch", detail: Self.refDetail(ref)) {
                    if ref.isTag { _ = await git.perform(String(localized: "切换分支")) { try await $0.checkoutDetached(ref.name) } }
                    else { await git.checkout(Self.localName(of: ref)) }
                }
            }
            palette.present(custom: items, placeholder: String(localized: "选择要签出的分支或标记"))
        }
    }

    /// 登记一条面板动作并返回对应的列表行。
    private func branchAction(_ id: String, _ title: String, _ icon: String, detail: String = "",
                              _ action: @escaping @MainActor () async -> Void) -> IDEPaletteLocation {
        let key = "branch:" + id
        paletteActions[key] = action
        var item = IDEPaletteLocation(id: key, title: title, detail: detail, icon: icon, path: "", line: 0)
        item.actionID = key
        return item
    }

    /// 列表行副标题:相对时间 · 作者 · 哈希 · 提交说明。
    private static func refDetail(_ ref: GitBranch) -> String {
        ([ref.relativeDate, ref.author, String(ref.hash.prefix(7)), ref.subject]).filter { !$0.isEmpty }.joined(separator: " • ")
    }

    /// 远程分支 `origin/foo` 对应的本地分支名 `foo`;本地分支原样返回。
    private static func localName(of ref: GitBranch) -> String {
        guard ref.isRemote, let slash = ref.name.firstIndex(of: "/") else { return ref.name }
        return String(ref.name[ref.name.index(after: slash)...])
    }

    /// 询问分支名并创建。
    /// - Parameters:
    ///   - git: 仓库模型
    ///   - base: 起点引用,nil 表示从当前 HEAD
    private func promptNewBranch(git: GitModel, base: String?) {
        guard let name = OMDialog.prompt(title: String(localized: "新建分支"), validate: {
            $0.isEmpty || $0.contains(where: \.isWhitespace) ? String(localized: "分支名不能为空或包含空白") : nil
        }), !name.isEmpty else { return }
        Task {
            if let base { _ = await git.perform(String(localized: "新建分支")) { try await $0.createBranch(name, from: base) } }
            else { await git.createBranch(name) }
        }
    }

    /// 「创建新分支依据…」:先选起点再填名称。
    private func showBaseRefPicker(git: GitModel, refs: [GitBranch]) {
        paletteActions = [:]
        let items = refs.map { ref in
            branchAction("base:" + ref.id, ref.name, ref.isTag ? "tag" : ref.isRemote ? "cloud" : "git-branch", detail: Self.refDetail(ref)) { [weak self] in
                self?.promptNewBranch(git: git, base: ref.name)
            }
        }
        palette.present(custom: items, placeholder: String(localized: "选择作为新分支起点的引用"))
    }

    /// 「签出已分离…」:选一个引用以游离 HEAD 方式签出。
    private func showDetachPicker(git: GitModel, refs: [GitBranch]) {
        paletteActions = [:]
        let items = refs.map { ref in
            branchAction("detach:" + ref.id, ref.name, ref.isTag ? "tag" : ref.isRemote ? "cloud" : "git-branch", detail: Self.refDetail(ref)) {
                _ = await git.perform(String(localized: "切换分支")) { try await $0.checkoutDetached(ref.name) }
            }
        }
        palette.present(custom: items, placeholder: String(localized: "选择要以分离 HEAD 签出的引用"))
    }
}
