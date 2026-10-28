// @author ixxxxoooo
// IDE 侧栏「源代码管理」视图:与 Agent 窗口右栏共用同一套 `SCMContent`(分支切换、拉取/推送、
// 提交与修补、AI 提交说明、stash、冲突解决、变更分组、提交图谱);差异/文件/历史标签落到 IDE 窗口。
// 工作区根目录本身不是仓库、但其一级子目录里有仓库时(如 KB/bigdata-kb、KB/bigdata-kb-fe),
// 各仓库按可折叠分区上下排列,独立显示自己的改动。

import DesignSystem
import GitKit
import IconKit
import SwiftUI

struct IDESCMPane: View {
    let workspace: IDEWorkspace
    /// 根目录下含 `.git` 的一级子目录(根目录自身是仓库时为空)
    @State private var nestedRepos: [String] = []
    /// 已折叠的子仓库
    @State private var collapsed: Set<String> = []
    /// 共用提交图谱当前查看的仓库(nil 取第一个)
    @State private var graphRepo: String?
    @State private var graphPickerShown = false

    var body: some View {
        if let root = workspace.root {
            Group {
                if nestedRepos.isEmpty {
                    SCMContent(host: IDESCMHost(workspace: workspace), model: GitStore.shared.model(for: root))
                } else {
                    nestedList
                }
            }
            .id(root)
            .task(id: root) { nestedRepos = await Self.discoverNestedRepos(in: root) }
        }
    }

    /// 多个子仓库:各自一个可折叠分区,独立显示分支、提交框与改动。
    private var nestedList: some View {
        VStack(spacing: 0) {
            ForEach(nestedRepos, id: \.self) { path in
                let open = !collapsed.contains(path)
                repoHeader(path: path, open: open)
                if open {
                    SCMContent(host: IDESCMHost(workspace: workspace), model: GitStore.shared.model(for: path), showsGraph: false)
                        .id(path)
                        .frame(maxHeight: .infinity)
                }
                Divider()
            }
            if collapsed.count == nestedRepos.count { Spacer(minLength: 0) }
            sharedGraph
        }
    }

    /// 所有仓库共用一个提交图谱(对标 VS Code):顶部仓库选择条切换查看哪个仓库的历史。
    private var sharedGraph: some View {
        let active = graphRepo.flatMap { nestedRepos.contains($0) ? $0 : nil } ?? nestedRepos[0]
        return VStack(spacing: 0) {
            Button { graphPickerShown.toggle() } label: {
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
            .omPicker(isPresented: $graphPickerShown,
                      entries: nestedRepos.map { PickEntry(id: $0, title: ($0 as NSString).lastPathComponent, subtitle: ($0 as NSString).abbreviatingWithTildeInPath, icon: "folder-git-2") },
                      selectedID: active, placeholder: String(localized: "搜索文件夹"), placement: .below, width: 280, showsSearch: nestedRepos.count > 6) { entry in
                graphRepo = entry.id
            }
            ScrollView {
                GitGraphSection(host: IDESCMHost(workspace: workspace), model: GitStore.shared.model(for: active))
                    .id(active)
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 子仓库标题行:点击折叠/展开。
    private func repoHeader(path: String, open: Bool) -> some View {
        Button {
            if open { collapsed.insert(path) } else { collapsed.remove(path) }
        } label: {
            HStack(spacing: 6) {
                Image.om(open ? "chevron-down" : "chevron-right", size: 12).foregroundStyle(OMColors.tertiaryText)
                Image.om("folder-git-2", size: 12)
                Text(verbatim: (path as NSString).lastPathComponent).font(OMFonts.small.weight(.medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 28)
            .background(OMColors.subtleFill)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: (path as NSString).lastPathComponent))
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
