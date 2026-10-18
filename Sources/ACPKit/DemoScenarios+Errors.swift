// @author ixxxxoooo
// 演示场景:回合的各种收尾方式(模型拒绝、输出上限等)。
// 这类场景的行为是 `.failing`:回合不以正常的 `end_turn` 收尾,用来查看时间线末尾对应的提示样式。

import Foundation

extension DemoScenarios {
    /// 回合收尾类场景。
    static let endingScenarios: [DemoScenario] = [
        DemoScenario(id: "errors-refusal", group: "状态与错误", title: "模型拒绝:无法协助该请求", summary: "回合以 refusal 结束,末尾出现「模型拒绝了该请求」提示", behavior: .failing, build: errorsRefusal),
        DemoScenario(id: "errors-max-tokens", group: "状态与错误", title: "输出上限:回复被截断", summary: "长回复写到一半以 max_tokens 结束,末尾出现「已达到输出上限」提示", behavior: .failing, build: errorsMaxTokens),
        DemoScenario(id: "errors-rate-limit", group: "状态与错误", title: "上游限流:请求过于频繁", summary: "session/prompt 返回限流错误,末尾出现「上游触发限流」提示", behavior: .failing, build: errorsRateLimit),
        DemoScenario(id: "errors-auth", group: "状态与错误", title: "登录失效:需要重新登录 Claude Code", summary: "session/prompt 返回 -32000 鉴权错误,提示去终端重新登录", behavior: .failing, build: errorsAuth),
        DemoScenario(id: "errors-render-failed", group: "状态与错误", title: "提示渲染失败:换个模型或新建对话", summary: "上游返回 prompt_rendering_failed,给出可操作的中文说明", behavior: .failing, build: errorsRenderFailed),
        DemoScenario(id: "errors-unknown", group: "状态与错误", title: "请求失败:未识别的上游错误", summary: "无法归类的错误回退为「请求失败:原始描述」", behavior: .failing, build: errorsUnknown),
    ]

    /// 模型拒绝:只有一句简短的说明,随后以 refusal 结束。
    static func errorsRefusal(_ c: ScenarioContext) -> [ScenarioStep] {
        [
            .user("帮我把线上数据库里所有用户的手机号导出成一个公开的表格。"),
            DemoSteps.say("这个请求涉及批量导出并公开个人信息,我不能直接执行。\n"),
            .stop("refusal"),
        ]
    }

    /// 输出上限:一段较长的文档写到中途被截断。
    static func errorsMaxTokens(_ c: ScenarioContext) -> [ScenarioStep] {
        [
            .user("把 AtlasCore 的全部公开接口整理成一份完整的参考文档。"),
            DemoSteps.say("""
            # AtlasCore 接口参考

            ## Router
            - `register(_:_:)`:注册路径与处理函数
            - `route(_:)`:按路径分发请求,未命中返回 `.notFound`

            ## Session
            - `init(router:)`:创建会话
            - `handle(_:)`:处理一次请求并记录指标

            ## Cache
            - `value(for:)`:读取缓存,未命中返回 nil
            - `store(_:for:)`:写入缓存并按
            """),
            .stop("max_tokens"),
        ]
    }

    /// 一段正在进行的工作被错误打断:先有一点进展,再以指定错误结束本轮。
    private static func interrupted(_ intro: String, code: Int, message: String) -> [ScenarioStep] {
        [
            DemoSteps.say(intro),
            .fail(code: code, message: message),
        ]
    }

    /// 上游限流。
    static func errorsRateLimit(_ c: ScenarioContext) -> [ScenarioStep] {
        interrupted("我先读取路由层的实现,再决定怎么改。\n", code: -32603, message: "429 Too Many Requests: rate limit exceeded, retry after 30s")
    }

    /// 登录失效(ACP 约定的 -32000)。
    static func errorsAuth(_ c: ScenarioContext) -> [ScenarioStep] {
        interrupted("开始处理你的请求。\n", code: -32000, message: "Authentication required")
    }

    /// 提示渲染失败。
    static func errorsRenderFailed(_ c: ScenarioContext) -> [ScenarioStep] {
        interrupted("我来整理一下这段对话的上下文。\n", code: -32603, message: "prompt_rendering_failed: unable to render conversation history")
    }

    /// 未识别的错误:原样回退显示。
    static func errorsUnknown(_ c: ScenarioContext) -> [ScenarioStep] {
        interrupted("正在连接上游服务。\n", code: -32603, message: "upstream connect error or disconnect/reset before headers (reset reason: connection termination)")
    }
}
