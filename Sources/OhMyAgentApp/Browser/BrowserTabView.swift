// @author ixxxxoooo
// 浏览器标签页:顶部工具栏(后退/前进/刷新/地址栏/用系统浏览器打开)+ 下方 WKWebView。
// Agent 与用户共用同一个标签页,所以这里的操作与 Agent 的 `browser_*` 工具看到的是同一个页面。

import AppKit
import ChatKit
import DesignSystem
import IconKit
import SwiftUI
import WebKit
import WorkbenchKit

/// 把标签模型持有的 `WKWebView` 放进 SwiftUI(同一个实例,切换标签后滚动位置与状态保留)。
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

struct BrowserTabView: View {
    let browserID: String
    let workspace: String
    @State private var address = ""
    @State private var model: BrowserTabModel?

    var body: some View {
        VStack(spacing: 0) {
            if let model {
                toolbar(model)
                Divider().opacity(0.5)
                ZStack(alignment: .top) {
                    WebViewHost(webView: model.webView)
                    if model.urlString.isEmpty { emptyState }
                    pickBanner(model)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OMColors.surface)
        .task(id: browserID) {
            let tab = BrowserController.shared.tab(id: browserID, workspace: workspace)
            model = tab
            address = tab.urlString
        }
    }

    private func toolbar(_ model: BrowserTabModel) -> some View {
        HStack(spacing: 6) {
            navButton("arrow-left", help: "后退", enabled: model.canGoBack) { model.webView.goBack() }
            navButton("arrow-right", help: "前进", enabled: model.canGoForward) { model.webView.goForward() }
            navButton(model.isLoading ? "x" : "rotate-cw", help: model.isLoading ? "停止加载" : "刷新", enabled: true) {
                if model.isLoading { model.webView.stopLoading() } else { model.webView.reload() }
            }
            HStack(spacing: 6) {
                Image.om("globe", size: 12).foregroundStyle(OMColors.tertiaryText)
                TextField("", text: $address, prompt: Text("输入网址"))
                    .textFieldStyle(.plain)
                    .font(OMFonts.small)
                    .onSubmit { go(model) }
                    .accessibilityLabel("地址栏")
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(OMPillShape().fill(OMColors.subtleFill))
            pickButton(model)
            navButton("external-link", help: "用系统浏览器打开", enabled: !model.urlString.isEmpty) {
                if let url = URL(string: model.urlString) { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .onChange(of: model.urlString) { _, value in if !value.isEmpty { address = value } }
    }

    /// 「选择元素」开关:开启后在页面里点选元素,元素信息与截图进入当前会话的输入框。
    private func pickButton(_ model: BrowserTabModel) -> some View {
        Button {
            Task { await model.setPicking(!model.isPicking) }
        } label: {
            Image.om("mouse-pointer-click", size: 13)
                .foregroundStyle(model.isPicking ? OMColors.accent : OMColors.secondaryText)
        }
        .buttonStyle(.omIcon)
        .disabled(model.urlString.isEmpty)
        .omTooltip(model.isPicking ? "退出选择元素" : "选择页面元素,发给 Agent")
        .accessibilityLabel("选择页面元素")
        .accessibilityAddTraits(model.isPicking ? .isSelected : [])
    }

    /// 页面上方的提示条:选择中提示操作方式;选中后短暂显示结果。
    @ViewBuilder
    private func pickBanner(_ model: BrowserTabModel) -> some View {
        if model.isPicking || model.pickNote != nil {
            HStack(spacing: 8) {
                Image.om(model.isPicking ? "mouse-pointer-click" : "circle-check", size: 12)
                    .foregroundStyle(model.isPicking ? OMColors.accent : OMColors.success)
                Text(verbatim: model.isPicking ? String(localized: "点击页面上的元素,把它发给 Agent · Esc 取消") : (model.pickNote ?? ""))
                    .font(OMFonts.small)
                    .foregroundStyle(OMColors.primaryText)
                    .lineLimit(1)
                if model.isPicking {
                    Button("取消") { Task { await model.setPicking(false) } }.buttonStyle(.omPlain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .omGlassCapsule()
            .padding(.top, 10)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }

    private func navButton(_ icon: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image.om(icon, size: 13) }
            .buttonStyle(.omIcon)
            .disabled(!enabled)
            .omTooltip(LocalizedStringKey(help))
            .accessibilityLabel(LocalizedStringKey(help))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image.om("globe", size: 16).foregroundStyle(OMColors.tertiaryText)
            Text("在地址栏输入网址,或让 Agent 用浏览器验证你正在开发的页面。").font(OMFonts.small).foregroundStyle(OMColors.secondaryText)
        }
        .padding(24)
    }

    private func go(_ model: BrowserTabModel) {
        guard let url = BrowserArguments.normalize(address) else { return }
        Task { await model.load(url) }
    }
}
