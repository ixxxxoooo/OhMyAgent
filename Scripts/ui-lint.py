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
SCAN_DIRS = ["Sources/OhMyAgentApp", "Sources/EditorKit", "Sources/MermaidKit", "Sources/DesignSystem"]
# 令牌定义文件:允许写原始颜色(它们就是令牌本身)
TOKEN_FILES = {"Tokens.swift", "ThemePackage.swift", "Appearance.swift"}

# (规则名, 正则, 提示)
RULES = [
    ("字号", re.compile(r"\.font\(\s*\.system\(size"), "字号必须用 OMFonts 令牌(特例用 OMFonts.custom)"),
    ("颜色", re.compile(r"Color\.(red|green|orange|yellow|blue|white|gray)\b|foregroundStyle\(\.(red|green|orange|yellow|blue)\)"), "颜色必须用 OMColors 语义色(danger/success/warning/onAccent…)"),
    ("颜色", re.compile(r"Color\(\s*(red|white|\.sRGB)\b|Color\(hex"), "禁止写死 RGB,使用 OMColors"),
    ("主题色", re.compile(r"Color\.(primary|secondary|accentColor|black)\b"), "颜色必须来自主题:OMColors.primaryText/secondaryText/accent/hoverFill/scrim…"),
    ("主题色", re.compile(r"foregroundStyle\(\s*\.(primary|secondary|tertiary)\s*\)"), "前景色用 OMColors.primaryText/secondaryText/tertiaryText"),
    ("主题色", re.compile(r"[(,:]\s*\.(red|green|orange|yellow|blue|purple|pink|gray|white|black|cyan|mint|teal|indigo|brown)\s*[,)]"), "SwiftUI 语义色不随主题,改用 OMColors"),
    ("主题色", re.compile(r"NSColor\.(system\w+|label\w*|secondaryLabel\w*|tertiaryLabel\w*|separator\w*|windowBackground\w*|textBackground\w*|controlAccent\w*|controlBackground\w*|selectedText\w*)|(?<![\w])\.system(Red|Green|Orange|Yellow|Blue|Purple|Pink|Teal|Gray|Indigo|Mint|Cyan|Brown)\b|Color\(nsColor:\s*\.(system|label|separator|windowBackground|textBackground|controlBackground)"), "AppKit 系统色不随主题,改用 OMColors / OMTerminalPalette / ThemePalette"),
    ("字号", re.compile(r"\.font\s*=\s*\.system\(size"), "字号必须用 OMFonts 令牌(AttributedString 用 OMFonts.custom)"),
    ("按钮", re.compile(r"buttonStyle\(\s*\.(bordered|borderedProminent|borderless)\s*\)"), "按钮用 OMButtonStyle(.omPrimary/.omSecondary/.omPlain/.omIcon)"),
    ("复制", re.compile(r"doc\.on\.doc|\"checkmark\"\s*:\s*\"doc"), "复制图标一律 copy → check(OMCopyButton)"),
    ("图标", re.compile(r"Image\(systemName"), "界面禁止 SF Symbol,使用 Image.om"),
    ("选择", re.compile(r"pickerStyle\(\s*\.(menu|inline|radioGroup|wheel)\s*\)"), "选择类控件用 OMPickList,档位用 OMStepSlider"),
]
ALLOW = "ui-lint:allow"
# 整文件豁免已全部收回:特例只能用行内 `// ui-lint:allow 原因`
FILE_ALLOW = {}


def scan():
    """返回违规列表 [(路径, 行号, 规则, 提示, 行文本)]。"""
    out = []
    for base in SCAN_DIRS:
        for dirpath, _, names in os.walk(os.path.join(ROOT, base)):
            for name in names:
                if not name.endswith(".swift"):
                    continue
                if name in FILE_ALLOW or (name in TOKEN_FILES and "DesignSystem" in dirpath) or name in TOKEN_FILES and base.endswith("DesignSystem"):
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
