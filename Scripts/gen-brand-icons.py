#!/usr/bin/env python3
# @author ixxxxoooo
# 从 lobe-icons(MIT 许可)生成 Sources/IconKit/BrandIconData.swift:模型厂商的单色图标(24×24 视口 path 数据)。
# 用法:Scripts/gen-brand-icons.py [--src <@lobehub/icons-static-svg 解压目录>]
# 不带 --src 时自动 `npm pack @lobehub/icons-static-svg` 到临时目录。
# 图标清单:Scripts/brand-icons.txt(每行一个 lobe 图标名)。只取单色版本,运行时按文字颜色着色(模板渲染)。
import glob, os, re, subprocess, sys, tarfile, tempfile
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def locate_src():
    if "--src" in sys.argv:
        return sys.argv[sys.argv.index("--src") + 1]
    tmp = tempfile.mkdtemp(prefix="lobe-")
    subprocess.run(["npm", "pack", "@lobehub/icons-static-svg", "--silent"], cwd=tmp, check=True, stdout=subprocess.DEVNULL)
    tgz = glob.glob(os.path.join(tmp, "lobehub-icons-static-svg-*.tgz"))[0]
    with tarfile.open(tgz) as t:
        t.extractall(tmp)
    return os.path.join(tmp, "package")


def num(v):
    v = float(v)
    return str(int(v)) if v == int(v) else ("%.4f" % v).rstrip("0").rstrip(".")


def to_path(tag, a):
    """把基础图元转成 path 的 d 字符串;不支持的图元返回 None。"""
    g = lambda k, d="0": a.get(k, d)
    if tag == "path":
        return a["d"]
    if tag == "circle":
        cx, cy, r = float(g("cx")), float(g("cy")), float(g("r"))
        return f"M{num(cx - r)} {num(cy)}a{num(r)} {num(r)} 0 1 0 {num(2 * r)} 0a{num(r)} {num(r)} 0 1 0 {num(-2 * r)} 0Z"
    if tag == "rect":
        x, y, w, h = float(g("x")), float(g("y")), float(g("width")), float(g("height"))
        return f"M{num(x)} {num(y)}H{num(x + w)}V{num(y + h)}H{num(x)}Z"
    return None


def main():
    src = locate_src()
    names = [l.strip() for l in open(os.path.join(ROOT, "Scripts/brand-icons.txt")) if l.strip() and not l.startswith("#")]
    version = re.search(r'"version":\s*"([^"]+)"', open(os.path.join(src, "package.json")).read()).group(1)
    out = ["// @author ixxxxoooo",
           f"// 由 Scripts/gen-brand-icons.py 自动生成,请勿手改。来源:lobe-icons {version}(MIT 许可,见 Resources/Licenses/LobeIcons-LICENSE.txt)。",
           "// 模型厂商单色图标:24×24 视口内的 SVG path 数据;evenodd 表示按奇偶规则填充。",
           "", "enum BrandIconData {", f'    static let version = "{version}"',
           "    /// 图标名 → (path 列表, 是否 evenodd)", "    static let icons: [String: (paths: [String], evenOdd: Bool)] = ["]
    skipped = []
    for name in sorted(set(names)):
        file = os.path.join(src, "icons", f"{name}.svg")
        if not os.path.exists(file):
            skipped.append(f"{name}(不存在)")
            continue
        root = ET.parse(file).getroot()
        paths, ok = [], True
        for el in root.iter():
            tag = el.tag.split("}")[-1]
            if tag in ("svg", "title"):
                continue
            d = to_path(tag, el.attrib)
            if d is None:
                ok = False
                break
            paths.append(d)
        if not ok or not paths:
            skipped.append(f"{name}(含不支持的图元)")
            continue
        even = root.attrib.get("fill-rule") == "evenodd"
        body = ", ".join('"%s"' % p.replace("\\", "\\\\").replace('"', '\\"') for p in paths)
        out.append(f'        "{name}": ([{body}], {"true" if even else "false"}),')
    out += ["    ]", "}", ""]
    open(os.path.join(ROOT, "Sources/IconKit/BrandIconData.swift"), "w").write("\n".join(out))
    print(f"已生成 {len(set(names)) - len(skipped)} 个厂商图标(lobe-icons {version})")
    if skipped:
        print("已跳过:", "、".join(skipped))


main()
