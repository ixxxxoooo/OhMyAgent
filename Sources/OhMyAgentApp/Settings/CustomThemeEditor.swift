// @author ixxxxoooo
// 自定义主题编辑器:基于某个主题改关键颜色与风格,带实时预览;保存到 `Application Support/OhMyAgent/themes`。

import AppKit
import DesignSystem
import IconKit
import OMLog
import SwiftUI
import UniformTypeIdentifiers

/// 可编辑的颜色项(键 → 显示名)。
private struct ThemeColorField: Identifiable, Sendable {
    let key: String
    /// 显示名(中文原文,同时是本地化键)
    let title: String
    var id: String { key }

    static let all: [ThemeColorField] = [
        .init(key: "surface", title: "内容区背景"), .init(key: "sidebarBackground", title: "侧栏背景"), .init(key: "card", title: "卡片"),
        .init(key: "editorForeground", title: "前景文字"), .init(key: "accent", title: "主强调色"), .init(key: "accent2", title: "第二强调色"),
        .init(key: "success", title: "成功"), .init(key: "danger", title: "危险"), .init(key: "warning", title: "警告"),
        .init(key: "keyword", title: "关键字"), .init(key: "string", title: "字符串"), .init(key: "comment", title: "注释"),
        .init(key: "number", title: "数字"), .init(key: "type", title: "类型"), .init(key: "function", title: "函数"),
    ]
}

/// 自定义主题编辑器(以 sheet 呈现)。
struct CustomThemeEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let appearance = AppearanceModel.shared
    @State private var draft: CustomThemeFile
    @State private var errorText: String?

    /// - Parameter initial: 初始内容(新建时由当前主题导出)
    init(initial: CustomThemeFile) {
        _draft = State(initialValue: initial)
    }

    private var package: ThemePackage? { try? draft.makePackage() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自定义主题").font(OMFonts.title)
            if let package {
                ThemeMiniWorkbench(package: package)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: OMMetrics.cardRadius, style: .continuous).strokeBorder(OMColors.hairline))
            }
            HStack {
                TextField("主题名称", text: $draft.name).textFieldStyle(.roundedBorder).font(OMFonts.body)
                Picker("基线", selection: $draft.base) {
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented).frame(width: 140).labelsHidden()
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 6) {
                    ForEach(ThemeColorField.all) { field in
                        ColorPicker(selection: binding(for: field.key), supportsOpacity: false) { Text(LocalizedStringKey(field.title)).font(OMFonts.small) }
                    }
                }
                .padding(.vertical, 4)
                Divider().padding(.vertical, 6)
                styleSliders
            }
            if let errorText { Text(errorText).font(OMFonts.small).foregroundStyle(OMColors.danger) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.omSecondary).keyboardShortcut(.cancelAction)
                Button("保存并使用") { save() }.buttonStyle(.omPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520, height: 560)
        .background(OMColors.surface)
    }

    /// 风格倍率滑块(圆角/描边/阴影)。
    private var styleSliders: some View {
        VStack(alignment: .leading, spacing: 8) {
            styleRow("圆角", key: "cornerScale", range: 0.3...1.6)
            styleRow("描边", key: "strokeScale", range: 0.3...2)
            styleRow("阴影", key: "shadowScale", range: 0...2)
        }
    }

    private func styleRow(_ title: LocalizedStringKey, key: String, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(OMFonts.small).frame(width: 40, alignment: .leading)
            Slider(value: Binding(
                get: { draft.style?[key] ?? 1 },
                set: { value in var style = draft.style ?? [:]; style[key] = value; draft.style = style }
            ), in: range)
            Text(String(format: "%.1f×", draft.style?[key] ?? 1)).font(OMFonts.caption).foregroundStyle(OMColors.secondaryText).monospacedDigit().frame(width: 36)
        }
    }

    /// 颜色项与 `Color` 的双向绑定。
    private func binding(for key: String) -> Binding<Color> {
        Binding(
            get: { ThemeRGB(hexString: draft.colors[key] ?? "")?.color ?? .gray },
            set: { color in
                guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                draft.colors[key] = ThemeRGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent).hexString
            }
        )
    }

    private func save() {
        do {
            // id 取名称的规整形式;同名覆盖
            if draft.id.isEmpty || draft.id.hasPrefix("new-") { draft.id = CustomThemeFile.sanitizedID(draft.name) }
            try appearance.saveCustomTheme(draft)
            Log.ui.info("自定义主题已保存", ["id": draft.id])
            dismiss()
        } catch {
            errorText = error.localizedDescription
            Log.ui.warning("自定义主题保存失败", ["error": "\(error)"])
        }
    }
}

/// 外观页里的「自定义主题」区:列表、新建、导入、导出、删除。
struct CustomThemeSection: View {
    @Bindable private var appearance = AppearanceModel.shared
    @State private var editing: CustomThemeFile?
    @State private var message: String?

    var body: some View {
        Section("自定义主题") {
            let customs = ThemePackage.all.filter { $0.group == .custom }
            if customs.isEmpty {
                Note("还没有自定义主题。可以基于当前主题新建,或导入别人分享的 .json 主题文件。")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(customs) { package in
                        ThemeCardPublic(package: package, selected: appearance.themeID == package.id) { appearance.themeID = package.id }
                            .contextMenu {
                                Button("编辑…") { edit(package) }
                                Button("导出…") { export(package) }
                                Button("删除", role: .destructive) { appearance.deleteCustomTheme(id: package.id) }
                            }
                    }
                }
            }
            HStack(spacing: 8) {
                Button("新建…") { editing = newDraft() }.buttonStyle(.omSecondary)
                Button("导入…") { importTheme() }.buttonStyle(.omSecondary)
                Button("导出当前") { export(appearance.themePackage) }.buttonStyle(.omSecondary).disabled(appearance.themePackage.palette == nil)
                Button("打开文件夹") { openFolder() }.buttonStyle(.omSecondary)
            }
            if let message { Note(message) }
            Note("主题文件是 JSON(目录:Application Support/OhMyAgent/themes),可直接用编辑器修改颜色、风格与终端 ANSI 色,保存后点「打开文件夹」旁的导入即可。")
        }
        .sheet(item: Binding(get: { editing.map(EditingTheme.init) }, set: { editing = $0?.file })) { item in
            CustomThemeEditor(initial: item.file)
        }
    }

    /// sheet 的标识包装(每次新建都用新的 id,保证编辑器重新初始化)。
    private struct EditingTheme: Identifiable {
        let file: CustomThemeFile
        let id = UUID()
    }

    /// 以当前主题(系统主题时取内置深/浅色基线)为基础的草稿。
    private func newDraft() -> CustomThemeFile {
        let base = appearance.themePackage.palette != nil ? appearance.themePackage : ThemePackage.find(ThemeRuntime.systemIsDark ? "cursor-dark" : "cursor-light")
        var file = CustomThemeFile.export(base, id: "new-\(Int(Date().timeIntervalSince1970))", name: String(localized: "我的主题")) ?? CustomThemeFile(id: "new", name: String(localized: "我的主题"), base: "dark")
        file.ansi = nil
        return file
    }

    private func edit(_ package: ThemePackage) {
        guard var file = CustomThemeFile.export(package) else { return }
        file.ansi = nil
        editing = file
    }

    private func export(_ package: ThemePackage) {
        guard let file = CustomThemeFile.export(package, id: CustomThemeFile.sanitizedID(package.name)) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(file.id).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try file.encoded().write(to: url, options: .atomic)
            message = String(localized: "已导出到 \(url.lastPathComponent)")
        } catch {
            message = String(localized: "导出失败:\(error.localizedDescription)")
            Log.ui.error("主题导出失败", ["error": "\(error)"])
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let package = try appearance.saveCustomTheme(CustomThemeFile.decode(data))
            message = String(localized: "已导入主题「\(package.name)」")
        } catch {
            message = String(localized: "导入失败:\(error.localizedDescription)")
            Log.ui.warning("主题导入失败", ["file": url.lastPathComponent, "error": "\(error)"])
        }
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: CustomThemeStore.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(CustomThemeStore.directory)
    }
}
