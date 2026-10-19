// @author ixxxxoooo
// 已解析的颜色令牌表:主题或强调色变化时一次性生成全部 `Color`(含混色、填充透明度、动态系统色),
// 之后每次读取 `OMColors.*` 只是一次 Observation 登记 + 字段读取。
// 背景:全应用约 1300 处 `OMColors.*` 读取,过去每次都复制整个 `ThemePalette`、新建 `NSColor`/`Color`、
// 重算混色;系统主题下 `scrim` 每次新建动态色(按身份比较,背景永远「变了」)。

import os
import SwiftUI

/// 当前主题下的全部颜色令牌(值快照,`Sendable`)。
struct ResolvedTokens: Sendable {
    /// 图表分类色数量
    static let chartCount = 8

    let surface: Color
    let sidebar: Color
    let card: Color
    let opaqueChrome: Color
    let primaryText: Color
    let hairline: Color
    let secondaryText: Color
    let tertiaryText: Color
    let diffAdded: Color
    let diffRemoved: Color
    let warning: Color
    let success: Color
    let danger: Color
    let onAccent: Color
    let accentText: Color
    let link: Color
    let actionFill: Color
    let onAction: Color
    let actionWarm: Color
    let onWarm: Color
    let actionPositive: Color
    let onPositive: Color
    let outline: Color
    let accent: Color
    let accent2: Color
    let scrollThumb: Color
    let scrollThumbActive: Color
    let subtleFill: Color
    let hoverFill: Color
    let selectedFill: Color
    let pressedFill: Color
    let statusActive: Color
    let statusRunning: Color
    let statusWaiting: Color
    let statusUnread: Color
    let statusIdle: Color
    let scrim: Color
    let chart: [Color]

    /// 按「未缓存参考实现」现算一份(只在缓存失效时调用)。
    private static func build() -> ResolvedTokens {
        _rebuilds.withLock { $0 += 1 }
        return ResolvedTokens(
            surface: OMColorsUncached.surface,
            sidebar: OMColorsUncached.sidebar,
            card: OMColorsUncached.card,
            opaqueChrome: OMColorsUncached.opaqueChrome,
            primaryText: OMColorsUncached.primaryText,
            hairline: OMColorsUncached.hairline,
            secondaryText: OMColorsUncached.secondaryText,
            tertiaryText: OMColorsUncached.tertiaryText,
            diffAdded: OMColorsUncached.diffAdded,
            diffRemoved: OMColorsUncached.diffRemoved,
            warning: OMColorsUncached.warning,
            success: OMColorsUncached.success,
            danger: OMColorsUncached.danger,
            onAccent: OMColorsUncached.onAccent,
            accentText: OMColorsUncached.accentText,
            link: OMColorsUncached.link,
            actionFill: OMColorsUncached.actionFill,
            onAction: OMColorsUncached.onAction,
            actionWarm: OMColorsUncached.actionWarm,
            onWarm: OMColorsUncached.onWarm,
            actionPositive: OMColorsUncached.actionPositive,
            onPositive: OMColorsUncached.onPositive,
            outline: OMColorsUncached.outline,
            accent: OMColorsUncached.accent,
            accent2: OMColorsUncached.accent2,
            scrollThumb: OMColorsUncached.scrollThumb,
            scrollThumbActive: OMColorsUncached.scrollThumbActive,
            subtleFill: OMColorsUncached.subtleFill,
            hoverFill: OMColorsUncached.hoverFill,
            selectedFill: OMColorsUncached.selectedFill,
            pressedFill: OMColorsUncached.pressedFill,
            statusActive: OMColorsUncached.statusActive,
            statusRunning: OMColorsUncached.statusRunning,
            statusWaiting: OMColorsUncached.statusWaiting,
            statusUnread: OMColorsUncached.statusUnread,
            statusIdle: OMColorsUncached.statusIdle,
            scrim: OMColorsUncached.scrim,
            chart: (0..<chartCount).map { OMColorsUncached.chart($0) }
        )
    }

    /// 缓存键:主题修订号 + 运行时配置代号(直接改 `ThemeRuntime` 而未 `bump` 时也能失效)。
    private struct Key: Equatable { var revision: Int; var generation: Int }
    private struct Cache { var key: Key; var tokens: ResolvedTokens }
    private static let cache = OSAllocatedUnfairLock<Cache?>(initialState: nil)

    /// 当前主题的令牌表。每次读取都会登记对 `ThemeTracker.revision` 的 Observation 依赖(视图随主题自动刷新),
    /// 缓存命中时不做任何重算。
    static var current: ResolvedTokens {
        let key = Key(revision: ThemeTracker.shared.revision, generation: ThemeRuntime.generation)
        return cache.withLock { cached in
            if let cached, cached.key == key { return cached.tokens }
            let tokens = build()
            cached = Cache(key: key, tokens: tokens)
            return tokens
        }
    }

    /// 重建缓存的次数(测试用:验证同一主题下不会重复生成)。
    static var rebuildCount: Int { _rebuilds.withLock { $0 } }
    private static let _rebuilds = OSAllocatedUnfairLock(initialState: 0)
}
