#!/usr/bin/env python3
"""由 en.lproj/Localizable.strings 的键生成 zh-Hans.lproj/Localizable.strings(键即中文原文,值与键相同)。

为什么需要:开发语言是中文、键即中文原文;为了让系统/应用语言选择 zh-Hans 时有明确的资源包,
并让 CFBundleDevelopmentRegion 能设为 en(其他语言用户回退英文),需要一份与英文键一一对应的中文资源。

用法:
  Scripts/sync-zh-strings.py           # 重新生成
  Scripts/sync-zh-strings.py --check   # CI:不一致时以非零状态退出
@author ixxxxoooo
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EN = os.path.join(ROOT, "Resources/en.lproj/Localizable.strings")
ZH = os.path.join(ROOT, "Resources/zh-Hans.lproj/Localizable.strings")
# 行格式:"key" = "value";(键值内的引号已转义)
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"(?:[^"\\]|\\.)*";\s*$')
SECTION = re.compile(r'^/\*.*\*/\s*$')


def generate():
    """按英文文件的顺序与分组注释生成中文文件内容。"""
    out = ["/* @author ixxxxoooo — 简体中文本地化(开发语言)。键即中文原文,值与键相同;由 Scripts/sync-zh-strings.py 生成,勿手改。 */"]
    for line in open(EN, encoding="utf-8").read().split("\n")[1:]:
        match = ENTRY.match(line)
        if match:
            out.append(f'"{match.group(1)}" = "{match.group(1)}";')
        elif SECTION.match(line) or line.strip() == "":
            out.append(line)
    return "\n".join(out).rstrip("\n") + "\n"


def main():
    content = generate()
    if "--check" in sys.argv:
        current = open(ZH, encoding="utf-8").read() if os.path.exists(ZH) else ""
        if current != content:
            print("zh-Hans.lproj/Localizable.strings 与 en.lproj 不同步,请运行 Scripts/sync-zh-strings.py", file=sys.stderr)
            sys.exit(1)
        print("中文资源同步检查通过")
        return
    os.makedirs(os.path.dirname(ZH), exist_ok=True)
    open(ZH, "w", encoding="utf-8").write(content)
    print("已生成", os.path.relpath(ZH, ROOT))


if __name__ == "__main__":
    main()
