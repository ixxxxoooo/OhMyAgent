// @author ixxxxoooo
// 演示场景:提问(Elicitation)的各种形态——多选项两列、多题向导、并发排队、MCP 通用表单、链接提问。
// 基础的两题向导见 `ask` 场景。

import Foundation

extension DemoScenarios {
    /// 提问变体类场景。
    static let askScenarios: [DemoScenario] = [
        DemoScenario(id: "ask-variants", group: "交互", title: "提问变体:多选项、多题向导与排队", summary: "7 个选项分两列、三题向导(单选/多选/带说明)、两个提问同时排队(交互)", behavior: .interactive, build: askVariants),
        DemoScenario(id: "ask-forms", group: "交互", title: "表单提问:MCP 通用表单与链接授权", summary: "文本/整数/布尔/单选/多选且含必填项的通用表单,以及需要在浏览器完成的链接提问(交互)", behavior: .interactive, build: askForms),
    ]

    /// 选项取值与标题相同的简写。
    private static func choices(_ titles: [String]) -> JSONValue {
        .array(titles.map { ["const": .string($0), "title": .string($0)] })
    }

    /// 提问变体:选项很多、多题、并发排队。
    static func askVariants(_ c: ScenarioContext) -> [ScenarioStep] {
        let manyOptions: JSONValue = [
            "type": "object",
            "properties": [
                "question_0": ["type": "string", "title": "数据库", "oneOf": choices(["PostgreSQL", "MySQL", "SQLite", "MongoDB", "Redis", "ClickHouse", "DuckDB", "CockroachDB"])],
                "question_0_custom": ["type": "string", "title": "Other"],
            ],
        ]
        let wizard: JSONValue = [
            "type": "object",
            "properties": [
                "question_0": [
                    "type": "string", "title": "缓存策略",
                    "oneOf": [
                        ["const": "lru", "title": "LRU", "description": "实现简单,命中率稳定"],
                        ["const": "lfu", "title": "LFU", "description": "热点明显时更优,实现更复杂"],
                        ["const": "ttl", "title": "仅 TTL", "description": "不限容量,按时间过期"],
                    ],
                ],
                "question_0_custom": ["type": "string", "title": "Other"],
                "question_1": ["type": "array", "title": "需要覆盖的场景", "items": ["anyOf": choices(["单元测试", "集成测试", "性能基准", "并发压力", "文档示例"])]],
                "question_2": [
                    "type": "string", "title": "发布方式",
                    "oneOf": [
                        ["const": "canary", "title": "灰度发布", "description": "先放 5% 流量观察一天"],
                        ["const": "full", "title": "全量发布"],
                    ],
                ],
                "question_2_custom": ["type": "string", "title": "Other"],
            ],
        ]
        let queuedA: JSONValue = [
            "type": "object",
            "properties": ["question_0": ["type": "string", "title": "日志级别", "oneOf": choices(["debug", "info", "warning", "error"])]],
        ]
        let queuedB: JSONValue = [
            "type": "object",
            "properties": ["question_0": ["type": "string", "title": "是否同时更新文档", "oneOf": choices(["更新", "暂不更新"])]],
        ]
        return DemoSteps.withUsage([
            DemoSteps.say("先确认几件事,第一个问题的选项比较多。\n\n"),
            .elicit(message: "新服务选用哪种数据库?", schema: manyOptions),
            DemoSteps.say("再确认缓存与发布的细节,一共三题。\n\n"),
            .elicit(message: "请完成下面三个选择", schema: wizard),
            DemoSteps.say("最后两个问题会同时出现,第二个在队列里等待。\n\n"),
            .parallel([
                [.elicit(message: "日志级别用哪一档?", schema: queuedA)],
                [.elicit(message: "是否同时更新文档?", schema: queuedB)],
            ]),
            DemoSteps.say("信息齐了,开始动手。\n"),
        ], used: 22_400)
    }

    /// 表单提问:MCP 通用表单与链接提问(字段键名带字母前缀,界面按键名排序,以此固定显示顺序)。
    static func askForms(_ c: ScenarioContext) -> [ScenarioStep] {
        let form: JSONValue = [
            "type": "object",
            "required": ["a_service", "b_replicas"],
            "properties": [
                "a_service": ["type": "string", "title": "服务名称", "description": "例如 atlas-web"],
                "b_replicas": ["type": "integer", "title": "副本数", "default": 2],
                "c_timeout": ["type": "number", "title": "超时(秒)", "default": 30.5],
                "d_autoscale": ["type": "boolean", "title": "启用自动扩缩容", "default": true],
                "e_region": [
                    "type": "string", "title": "部署区域",
                    "oneOf": [
                        ["const": "ap-east", "title": "亚太东部"],
                        ["const": "eu-west", "title": "欧洲西部"],
                        ["const": "us-east", "title": "美国东部"],
                    ],
                ],
                "f_channels": ["type": "array", "title": "通知渠道", "items": ["anyOf": choices(["邮件", "飞书", "Slack"])]],
            ],
        ]
        return DemoSteps.withUsage([
            DemoSteps.say("部署工具需要你填一份表单,带 * 的是必填项。\n\n"),
            .elicit(message: "请填写部署参数", schema: form),
            DemoSteps.say("接下来需要你在浏览器里授权访问 GitHub。\n\n"),
            .elicitURL(message: "请在浏览器中完成 GitHub 授权,然后回来继续", url: "https://github.com/login/device"),
            DemoSteps.say("流程结束。\n"),
        ], used: 15_800)
    }
}
