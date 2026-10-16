#!/usr/bin/env python3
"""UI 规范扫描:禁止绕开设计系统的写法(字号、颜色、按钮、复制图标、SF Symbol)。

用法:
  Scripts/ui-lint.py [--check]
    --check  CI 模式:存在违规时以非零状态退出(默认只打印)

规则全文见 AGENTS.md「4.2 UI 组件与字号规范」。个别特例可在该行末尾追加注释 `// ui-lint:allow 原因` 豁免。
@author ixxxxoooo
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCAN_DIRS = ["Sources/OhMyAgentApp"]

# (规则名, 正则, 提示)
RULES = [
    ("字号", re.compile(r"\.font\(\s*\.system\(size"), "字号必须用 OMFonts 令牌(特例用 OMFonts.custom)"),
    ("颜色", re.compile(r"Color\.(red|green|orange|yellow|blue|white|gray)\b|foregroundStyle\(\.(red|green|orange|yellow|blue)\)"), "颜色必须用 OMColors 语义色(danger/success/warning/onAccent…)"),
    ("颜色", re.compile(r"Color\(\s*(red|white|\.sRGB)\b|Color\(hex"), "禁止写死 RGB,使用 OMColors"),
    ("按钮", re.compile(r"buttonStyle\(\s*\.(bordered|borderedProminent|borderless)\s*\)"), "按钮用 OMButtonStyle(.omPrimary/.omSecondary/.omPlain/.omIcon)"),
    ("复制", re.compile(r"doc\.on\.doc|\"checkmark\"\s*:\s*\"doc"), "复制图标一律 copy → check(OMCopyButton)"),
    ("图标", re.compile(r"Image\(systemName"), "界面禁止 SF Symbol,使用 Image.om"),
    ("选择", re.compile(r"pickerStyle\(\s*\.(menu|inline|radioGroup|wheel)\s*\)"), "选择类控件用 OMPickList,档位用 OMStepSlider"),
]
ALLOW = "ui-lint:allow"
# 整文件豁免(原因):终端 ANSI 调色板、菜单栏 NSColor 绘制、图表色板、固定深色浮层
FILE_ALLOW = {
    "ANSITextView.swift": "终端 ANSI 调色板",
    "StatusItemController.swift": "菜单栏 NSColor 绘制",
    "ContextUsagePanel.swift": "上下文图表固定色板",
    "ImagePreviewView.swift": "固定深色浮层",
}


def scan():
    """返回违规列表 [(路径, 行号, 规则, 提示, 行文本)]。"""
    out = []
    for base in SCAN_DIRS:
        for dirpath, _, names in os.walk(os.path.join(ROOT, base)):
            for name in names:
                if not name.endswith(".swift"):
                    continue
                if name in FILE_ALLOW:
                    continue
                path = os.path.join(dirpath, name)
                with open(path, encoding="utf-8") as handle:
                    for number, line in enumerate(handle, 1):
                        if ALLOW in line or line.lstrip().startswith("//"):
                            continue
                        for rule, regex, hint in RULES:
                            if regex.search(line):
                                out.append((os.path.relpath(path, ROOT), number, rule, hint, line.strip()))
    return out


def main():
    violations = scan()
    for path, number, rule, hint, text in violations:
        print(f"{path}:{number}: [{rule}] {hint}\n    {text}")
    if violations:
        print(f"\nUI 规范违规 {len(violations)} 处")
        if "--check" in sys.argv:
            sys.exit(1)
    else:
        print("UI 规范扫描通过")


if __name__ == "__main__":
    main()
