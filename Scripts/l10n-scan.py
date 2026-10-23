#!/usr/bin/env python3
"""扫描 Swift 源码里的中文字符串字面量,对照 en.lproj/Localizable.strings 找出缺失的英文翻译。

用法:
  Scripts/l10n-scan.py [--all] [--json] [--check]
    --all    同时列出已收录的键(默认只列缺失)
    --json   以 JSON 输出(含偏移量、插值表达式、前文)
    --check  CI 模式:存在缺失翻译时以非零状态退出

约定:字面量里的插值 `\\(expr)` 归一化为占位符,与 strings 键里的 %@ / %lld / %d / %f 等价比较;
插值内部嵌套的字符串字面量会作为独立条目输出(它们是普通 String,不会被 SwiftUI 自动本地化)。
@author ixxxxoooo
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STRINGS = os.path.join(ROOT, "Resources/en.lproj/Localizable.strings")
HAN = re.compile(r"[\u4e00-\u9fff]")
PLACEHOLDER = "\u0000"


def load_keys():
    """用 plutil 解析 strings 文件,返回归一化后的键集合。"""
    raw = subprocess.run(["plutil", "-convert", "json", "-o", "-", STRINGS], capture_output=True, check=True).stdout
    return {normalize_key(k) for k in json.loads(raw)}


def normalize_key(key):
    """把 strings 键里的格式占位符统一替换为占位符标记。"""
    key = key.replace("%%", "\u0001")
    key = re.sub(r"%(?:\d+\$)?(?:lld|ld|@|d|\.\d+f|f|u|llu)", PLACEHOLDER, key)
    return key.replace("\u0001", "%")


def unescape(text):
    """还原 Swift 字符串转义(只处理常见转义,用于键比较)。"""
    return (text.replace("\\n", "\n").replace("\\t", "\t").replace('\\"', '"').replace("\\\\", "\\"))


def scan_file(path):
    """返回文件内所有含中文的字符串字面量(字典列表)。

    字段:line / key(插值以占位符表示)/ ctx(所在行)/ nested / start / end(偏移)/ exprs(插值表达式)。
    """
    src = open(path, encoding="utf-8").read()
    lines = src.split("\n")
    out = []
    n = len(src)
    i = 0

    def line_of(pos):
        return src.count("\n", 0, pos) + 1

    def read_string(start, nested):
        """从 start(引号或 # 位置)读取一个字符串字面量,返回 (结束位置, 键文本, 插值表达式列表)。"""
        j = start
        hashes = 0
        while src[j] == "#":
            hashes += 1
            j += 1
        triple = src.startswith('"""', j)
        j += 3 if triple else 1
        buf = []
        exprs = []
        close = ('"""' if triple else '"') + "#" * hashes
        interp = "\\" + "#" * hashes + "("
        while j < n:
            if src.startswith(close, j):
                return j + len(close), "".join(buf), exprs
            if src.startswith(interp, j):
                depth = 1
                k = j + len(interp)
                body_start = k
                while k < n and depth:
                    c = src[k]
                    if c == '"' or (c == "#" and src.startswith('#"', k)):
                        s0 = k
                        k, inner, inner_exprs = read_string(k, True)
                        if HAN.search(inner):
                            ln = line_of(s0)
                            out.append({"line": ln, "key": unescape(inner), "ctx": lines[ln - 1].strip(), "nested": True,
                                        "start": s0, "end": k, "exprs": inner_exprs})
                        continue
                    if c == "(":
                        depth += 1
                    elif c == ")":
                        depth -= 1
                    k += 1
                exprs.append(src[body_start:k - 1])
                buf.append(PLACEHOLDER)
                j = k
                continue
            if src[j] == "\\" and hashes == 0:
                buf.append(src[j:j + 2])
                j += 2
                continue
            buf.append(src[j])
            j += 1
        return j, "".join(buf), exprs

    while i < n:
        c = src[i]
        if src.startswith("//", i):
            nl = src.find("\n", i)
            i = n if nl < 0 else nl
            continue
        if src.startswith("/*", i):
            end = src.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        if c == '"' or (c == "#" and re.match(r'#+"', src[i:i + 8])):
            start = i
            i, text, exprs = read_string(i, False)
            if HAN.search(text):
                ln = line_of(start)
                out.append({"line": ln, "key": unescape(text), "ctx": lines[ln - 1].strip(), "nested": False,
                            "start": start, "end": i, "exprs": exprs})
            continue
        i += 1
    # 为每个条目补充前文(用于判断调用上下文)
    for item in out:
        item["before"] = src[max(0, item["start"] - 48):item["start"]].replace("\n", " ")
    return out


# 有意不翻译的位置(协议/日志/辅助进程/不可恢复错误/字符串比较用的字面量)。
# 元素为 (文件路径前缀, 键或 None);键为 None 表示该前缀下全部放行。
ALLOWLIST = (
    ("Sources/EditorKit/Native/NativeSnippets.swift", None),   # 内置 snippet 的说明与模板正文(代码片段内容)
    ("Sources/OhMyAgentApp/ProjectTreeView.swift", "前"),
    *(("Sources/ProviderProxyKit/UpstreamHints.swift", w) for w in ("额度不足", "余额不足", "额度已用尽", "配额已用尽")),   # 上游错误正文的匹配特征,非界面文案   # 相对时间后缀裁剪(去掉「前」只做字符串比较,非界面文案)
    ("Sources/OhMyAgentApp/Demo/DemoBenchmarkRunner.swift", None),   # 演示基准的明细文本(仅演示模式,面向开发者)
    ("Sources/OhMyAgentApp/Demo/DemoBenchmarkRunner+IDE.swift", None),   # IDE 基准的明细文本(仅演示模式,面向开发者)
    ("Sources/ACPKit/ACPClient.swift", None),            # JSON-RPC 错误文本(给 Agent 看)
    ("Sources/ACPKit/JSONRPC.swift", None),
    ("Sources/ACPKit/JSONValue.swift", None),
    ("Sources/ACPKit/JSONFast.swift", None),             # JSON 解析错误原因(仅进日志,面向开发者)
    ("Sources/ACPKit/ScenarioEngine.swift", None),
    ("Sources/ACPKit/ACPConnection.swift", "未实现: \u0000"),
    ("Sources/ACPKit/Models.swift", "开"),                # 协议值的回退显示,与选项值比较
    ("Sources/ACPKit/Models.swift", "关"),
    ("Sources/AgentHost/BridgeServer.swift", None),      # MCP Bridge 返回给 Agent 的错误
    ("Sources/AgentHost/TerminalManager.swift", None),
    ("Sources/ChatKit/SessionBridge.swift", None),
    ("Sources/ChatKit/CanvasBridge.swift", None),          # Canvas 工具返回给 Agent 的错误文本
    ("Sources/ChatKit/CodeSearch.swift", None),            # search_code 工具返回给 Agent 的错误文本
    ("Sources/ChatKit/AskBridge.swift", None),             # ask_user_question 工具返回给 Agent 的错误文本
    ("Sources/ChatKit/ChartPrompt.swift", None),           # 追加给 Agent 的图表系统提示词
    ("Sources/ChatKit/CommitCollaborator.swift", None),    # 追加给 Agent 的协作者尾注提示词
    ("Sources/ChatKit/PickedElement.swift", None),         # 选中页面元素后发给 Agent 的描述文本
    ("Sources/OhMyAgentApp/Browser/BrowserProbe.swift", None),  # 调试钩子 OMA_BROWSER_PROBE 的输出文件
    ("Sources/CanvasKit/", None),                          # 画布校验错误(给模型看,带路径便于重试)
    ("Sources/OhMyAgentApp/Explorer/HubSearch.swift", "报告"),  # 画布搜索的中文别名关键词
    ("Sources/IconKit/BrandIcons.swift", None),           # 厂商匹配关键字(用户自建提供商名称),不是界面文案
    ("Sources/ChatKit/SessionModel.swift", "仅允许写入工作区内的文件: \u0000"),
    ("Sources/LSPKit/LSPClient.swift", "未实现: \u0000"),
    ("Sources/ChatKit/CommitMessageGenerator.swift", None),  # 提交说明生成:提示词与中英文启发式文案,不是界面文案
    ("Sources/WorkbenchKit/WorkbenchModel.swift", None),  # 会话区系统提示词:发给 Agent 的指令,不是界面文案
    ("Sources/ChatKit/TitleGenerator.swift", None),       # 标题生成:发给小模型的提示词与前缀清洗,不是界面文案
    ("Sources/ChatKit/PlanDocument.swift", "步骤"),       # 计划解析:匹配「实施步骤」等标题的关键词,不是界面文案
    ("Sources/ChatKit/PlanDocument.swift", "任务"),
    ("Sources/ChatKit/PlanDocument.swift", "实施"),
    ("Sources/ChatKit/PlanDocument.swift", "实现"),
    ("Sources/ChatKit/PromptOptimizer.swift", None),      # 提示词优化:发给模型的系统提示词、前缀清洗与演示改写,不是界面文案
    ("Sources/OhMyAgentApp/Settings/SettingsWindow.swift", "服务器"),  # 设置搜索的中文别名关键词
    ("Sources/OhMyAgentApp/Settings/SettingsWindow.swift", "斜杠"),  # 设置搜索的中文别名关键词
    ("Sources/OhMyAgentApp/Settings/SettingsWindow.swift", "子代理"),  # 设置搜索的中文别名关键词
    ("Sources/OhMyAgentApp/Settings/SettingsWindow.swift", "子 agent"),  # 设置搜索的中文别名关键词
    ("Sources/OhMyAgentApp/Settings/SettingsWindow.swift", "钩子"),  # 设置搜索的中文别名关键词
    ("Sources/OhMyAgentApp/Settings/SettingsWindow.swift", "生命周期"),  # 设置搜索的中文别名关键词
    ("Sources/OhMyAgentApp/Settings/SettingsWindow.swift", "市场"),  # 设置搜索的中文别名关键词
    ("Sources/OhMyAgentApp/Settings/SettingsWindow.swift", "指令"),  # 设置搜索的中文别名关键词
    ("Sources/OhMyAgentApp/Settings/SettingsWindow.swift", "规则"),  # 设置搜索的中文别名关键词
    ("Sources/OhMyAgentApp/Settings/SettingsWindow.swift", "密钥"),  # 设置搜索的中文别名关键词
    ("Sources/OhMyAgentApp/Settings/SettingsWindow.swift", "注册表"),  # 设置搜索的中文别名关键词
    ("Sources/OMLog/", None),                            # 日志文本不本地化
    ("Sources/EditorKit/CodeEditorView.swift", "不支持从 nib 创建"),  # fatalError 信息
    ("Sources/OhMyAgentApp/StatusItemController.swift", "init(coder:) 不可用"),
    ("Sources/ChatKit/ToolPresentation.swift", "读取 "),   # stripVerb:与 Agent 标题做前缀比较
    ("Sources/ChatKit/ToolPresentation.swift", "修改 "),
    ("Sources/ChatKit/ToolPresentation.swift", "编辑 "),
    ("Sources/ChatKit/ToolPresentation.swift", "写入 "),
    ("Sources/ChatKit/ToolPresentation.swift", "运行 "),
    ("Sources/ChatKit/ToolPresentation.swift", "搜索 "),
)


def is_allowed(rel, key):
    """该文件内的该字面量是否在白名单中。"""
    return any(rel.startswith(prefix) and (allowed is None or allowed == key) for prefix, allowed in ALLOWLIST)


EXCLUDE_DIRS = ("Sources/DemoKit/", "Sources/ACPSpike/", "Sources/EditorSpike/", "Sources/FakeAgent/",
                "Sources/ACPKit/DemoScenarios", "Sources/ACPKit/DemoHistory", "Sources/ACPKit/ScriptedAgent")
LOG_RE = re.compile(r"\b(Log|log)\.\w+\.?(info|debug|warning|error)?\(|\blog\.(info|debug|warning|error)\(|\bLog\.\w+\.span\(|\bPerfStats\.shared\.record\(|\bLaunchTrace\.mark\(|Logger\(|assertionFailure|precondition")


def scan_all(show_all=False):
    """扫描全部源码,返回条目列表(默认只含缺失)。"""
    have = load_keys()
    rows = []
    for dirpath, _, files in os.walk(os.path.join(ROOT, "Sources")):
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, ROOT)
            if rel.startswith(EXCLUDE_DIRS):
                continue
            for item in scan_file(path):
                if LOG_RE.search(item["ctx"]) or is_allowed(rel, item["key"]):
                    continue
                covered = normalize_key(item["key"]) in have or item["key"] in have
                if covered and not show_all:
                    continue
                item["file"] = rel
                item["covered"] = covered
                rows.append(item)
    rows.sort(key=lambda r: (r["file"], r["line"]))
    return rows


def main():
    show_all = "--all" in sys.argv
    rows = scan_all(show_all)
    if "--check" in sys.argv:
        for r in rows:
            print(f"缺少英文翻译: {r['file']}:{r['line']}  {r['key'].replace(PLACEHOLDER, '%@')!r}", file=sys.stderr)
        if rows:
            print(f"共 {len(rows)} 条中文字面量缺少英文翻译(用 Scripts/add-strings.py 追加,或加入 l10n-scan.py 白名单)", file=sys.stderr)
            sys.exit(1)
        print("本地化扫描通过")
        return
    if "--json" in sys.argv:
        print(json.dumps(rows, ensure_ascii=False, indent=1))
    else:
        for r in rows:
            print(f"{r['file']}:{r['line']}\t{'[嵌套]' if r['nested'] else ''}{r['key'].replace(PLACEHOLDER, '%@')}")
        print(f"-- 共 {len(rows)} 条", file=sys.stderr)


if __name__ == "__main__":
    main()
