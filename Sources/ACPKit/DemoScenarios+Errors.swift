// @author ixxxxoooo
// 演示场景:回合的各种收尾方式(模型拒绝、输出上限等)。
// 这类场景的行为是 `.failing`:回合不以正常的 `end_turn` 收尾,用来查看时间线末尾对应的提示样式。

import Foundation

extension DemoScenarios {
    /// 回合收尾类场景。
    static let endingScenarios: [DemoScenario] = [
        DemoScenario(id: "errors-refusal", group: "状态与错误", title: "模型拒绝:无法协助该请求", summary: "回合以 refusal 结束,末尾出现「模型拒绝了该请求」提示", behavior: .failing, build: errorsRefusal),
        DemoScenario(id: "errors-max-tokens", group: "状态与错误", title: "输出上限:回复被截断", summary: "长回复写到一半以 max_tokens 结束,末尾出现「已达到输出上限」提示", behavior: .failing, build: errorsMaxTokens),
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
}
