// @author ixxxxoooo
// 彩色文件类型图标:名称解析(文件名 > 扩展名 > 默认)、文件夹展开态、全部内置图标可解析并渲染。

import AppKit
import Testing

@testable import IconKit

@Suite("文件类型图标")
struct FileIconTests {
    @Test("按扩展名解析,大小写不敏感,未知扩展回退默认文件图标")
    func byExtension() {
        #expect(OMFileIconCatalog.iconName(for: "main.swift", isDirectory: false) == "swift")
        #expect(OMFileIconCatalog.iconName(for: "VIEW.SWIFT", isDirectory: false) == "swift")
        #expect(OMFileIconCatalog.iconName(for: "data.unknownext", isDirectory: false) == FileIconData.defaultFile)
        #expect(OMFileIconCatalog.iconName(for: "noextension", isDirectory: false) == FileIconData.defaultFile)
    }

    @Test("特殊文件名优先于扩展名;隐藏文件按去掉前导点的名称解析")
    func byFileName() {
        #expect(OMFileIconCatalog.iconName(for: "README.md", isDirectory: false) == "readme")
        #expect(OMFileIconCatalog.iconName(for: "readme.md", isDirectory: false) == "readme")
        #expect(OMFileIconCatalog.iconName(for: ".gitignore", isDirectory: false) == FileIconData.fileNames[".gitignore"] ?? FileIconData.extensions["gitignore"])
        #expect(OMFileIconCatalog.iconName(for: ".gitignore", isDirectory: false) != FileIconData.defaultFile)
    }

    @Test("文件夹按名称解析,展开态使用 -open 图标,未知文件夹回退默认")
    func folders() {
        #expect(OMFileIconCatalog.iconName(for: "src", isDirectory: true) == "folder-src")
        #expect(OMFileIconCatalog.iconName(for: "SRC", isDirectory: true) == "folder-src")
        #expect(OMFileIconCatalog.iconName(for: "src", isDirectory: true, expanded: true) == "folder-src-open")
        #expect(OMFileIconCatalog.iconName(for: "whatever", isDirectory: true) == FileIconData.defaultFolder)
        #expect(OMFileIconCatalog.iconName(for: "whatever", isDirectory: true, expanded: true) == FileIconData.defaultFolderOpen)
    }

    @Test("每个图标的路径都落在视口内(防止 viewBox 原点非 0 的图标被画到画布外而不显示)")
    func iconsStayInsideViewport() throws {
        // 上游图标自身路径就超出 viewBox(被自身 viewBox 裁剪),不是原点问题,豁免
        let upstreamOverflow: Set<String> = ["vedic"]
        for (name, spec) in FileIconData.icons where !upstreamOverflow.contains(name) {
            let lines = spec.split(separator: "\n", omittingEmptySubsequences: true)
            let head = lines.first?.split(separator: " ").compactMap { Double($0) } ?? []
            let side = try #require(head.first)
            let origin = head.count >= 3 ? CGPoint(x: head[1], y: head[2]) : .zero
            let viewport = CGRect(x: origin.x, y: origin.y, width: side, height: side).insetBy(dx: -side * 0.1, dy: -side * 0.1)
            for line in lines.dropFirst() {
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count == 3 else { continue }
                let box = try SVGPathParser.parse(String(parts[2])).cgPath.boundingBoxOfPath
                #expect(viewport.contains(box), "\(name) 的路径超出视口:\(box)")
            }
        }
    }

    @Test("映射表指向的图标全部存在,且每个内置图标都能解析并渲染")
    @MainActor
    func allIconsRender() {
        let tables: [[String: String]] = [FileIconData.extensions, FileIconData.fileNames, FileIconData.folders, FileIconData.foldersOpen]
        for table in tables {
            for (key, icon) in table { #expect(FileIconData.icons[icon] != nil, "\(key) → \(icon) 缺少图标数据") }
        }
        for name in [FileIconData.defaultFile, FileIconData.defaultFolder, FileIconData.defaultFolderOpen] {
            #expect(FileIconData.icons[name] != nil)
        }
        for name in FileIconData.icons.keys {
            #expect(OMFileIconRenderer.image(icon: name, size: 16) != nil, "\(name) 渲染失败")
        }
    }

    @Test("常见文件类型都有专属图标,不回退默认文件图标")
    func commonTypesHaveDedicatedIcons() {
        let common = """
        json jsonc yaml yml toml xml plist md txt csv tsv xlsx xls docx doc pptx ppt pdf key pages numbers
        swift kt java py js ts tsx jsx go rs rb php c cpp h cs sh zsh sql html css scss vue svelte
        png jpg jpeg gif svg webp ico mp3 wav mp4 mov zip tar gz rar 7z dmg pkg log lock env
        """.split(whereSeparator: { $0 == " " || $0 == "\n" })
        for ext in common {
            let icon = OMFileIconCatalog.iconName(for: "sample.\(ext)", isDirectory: false)
            #expect(icon != FileIconData.defaultFile, "\(ext) 没有专属图标")
        }
    }
}
