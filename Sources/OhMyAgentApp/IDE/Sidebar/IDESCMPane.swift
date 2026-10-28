// @author ixxxxoooo
// IDE 侧栏「源代码管理」视图:与 Agent 窗口右栏共用同一套 `SCMContent`(分支切换、拉取/推送、
// 提交与修补、AI 提交说明、stash、冲突解决、变更分组、提交图谱);差异/文件/历史标签落到 IDE 窗口。
// 工作区根目录本身不是仓库、但其一级子目录里有仓库时(如 KB/bigdata-kb、KB/bigdata-kb-fe),
// 顶部出现仓库切换条,各仓库独立显示自己的改动。

import DesignSystem
import GitKit
import IconKit
import SwiftUI

struct IDESCMPane: View {
    let workspace: IDEWorkspace
    /// 根目录下含 `.git` 的一级子目录(根目录自身是仓库时为空)
    @State private var nestedRepos: [String] = []
    /// 当前查看的子仓库(nil 取第一个)
    @State private var chosenRepo: String?
    @State private var pickerShown = false

    var body: some View {
        if let root = workspace.root {
            let active = chosenRepo.flatMap { nestedRepos.contains($0) ? $0 : nil } ?? nestedRepos.first ?? root
            VStack(spacing: 0) {
                if nestedRepos.count > 1 || (nestedRepos.count == 1 && nestedRepos[0] != root) {
                    repoBar(active: active)
                    Divider()
                }
                SCMContent(host: IDESCMHost(workspace: workspace), model: GitStore.shared.model(for: active))
                    .id(active)
            }
            .task(id: root) { nestedRepos = await Self.discoverNestedRepos(in: root) }
        }
    }

    /// 仓库切换条:显示当前仓库名,点击弹出 `OMPickList`。
    private func repoBar(active: String) -> some View {
        Button { pickerShown.toggle() } label: {
            HStack(spacing: 6) {
                Image.om("folder-git-2", size: 12)
                Text(verbatim: (active as NSString).lastPathComponent).font(OMFonts.small.weight(.medium)).lineLimit(1)
                Image.om("chevron-down", size: 10).foregroundStyle(OMColors.tertiaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换仓库")
        .omPicker(isPresented: $pickerShown,
                  entries: nestedRepos.map { PickEntry(id: $0, title: ($0 as NSString).lastPathComponent, subtitle: ($0 as NSString).abbreviatingWithTildeInPath, icon: "folder-git-2") },
                  selectedID: active, placeholder: String(localized: "搜索文件夹"), placement: .below, width: 280, showsSearch: nestedRepos.count > 6) { entry in
            chosenRepo = entry.id
        }
    }

    /// 根目录自身不是仓库时,列出含 `.git` 的一级子目录(按名称排序,跳过隐藏目录)。
    /// - Parameter root: 工作区根目录
    /// - Returns: 子仓库的绝对路径;根目录自身是仓库或没有子仓库时为空
    nonisolated private static func discoverNestedRepos(in root: String) async -> [String] {
        await Task.detached {
            let fm = FileManager.default
            guard !fm.fileExists(atPath: (root as NSString).appendingPathComponent(".git")) else { return [] }
            let names = (try? fm.contentsOfDirectory(atPath: root)) ?? []
            return names.filter { !$0.hasPrefix(".") }.sorted()
                .map { (root as NSString).appendingPathComponent($0) }
                .filter { fm.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git")) }
        }.value
    }
}
