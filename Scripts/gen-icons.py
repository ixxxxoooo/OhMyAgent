#!/usr/bin/env python3
# @author ixxxxoooo
# 从 Lucide(ISC 许可)生成 Sources/IconKit/LucideIcons.swift。
# 用法:Scripts/gen-icons.py [--src <lucide-static 解压目录>]
# 不带 --src 时自动 `npm pack lucide-static` 到临时目录。
# 图标清单:Scripts/lucide-icons.txt。所有图元(circle/rect/line/polyline/polygon/ellipse)
# 在生成时统一转换为 path 的 d 字符串,运行时只需要一个 SVG path 解析器。
import json, os, subprocess, sys, tempfile, tarfile, glob

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def locate_src():
    if "--src" in sys.argv:
        return sys.argv[sys.argv.index("--src") + 1]
    tmp = tempfile.mkdtemp(prefix="lucide-")
    subprocess.run(["npm", "pack", "lucide-static", "--silent"], cwd=tmp, check=True, stdout=subprocess.DEVNULL)
    tgz = glob.glob(os.path.join(tmp, "lucide-static-*.tgz"))[0]
    with tarfile.open(tgz) as t:
        t.extractall(tmp)
    return os.path.join(tmp, "package")

def num(v):
    v = float(v)
    return str(int(v)) if v == int(v) else ("%.4f" % v).rstrip("0").rstrip(".")

def to_path(tag, a):
    g = lambda k, d="0": a.get(k, d)
    if tag == "path":
        return a["d"]
    if tag == "circle":
        cx, cy, r = float(g("cx")), float(g("cy")), float(g("r"))
        return f"M{num(cx - r)} {num(cy)}a{num(r)} {num(r)} 0 1 0 {num(2 * r)} 0a{num(r)} {num(r)} 0 1 0 {num(-2 * r)} 0Z"
    if tag == "ellipse":
        cx, cy, rx, ry = float(g("cx")), float(g("cy")), float(g("rx")), float(g("ry"))
        return f"M{num(cx - rx)} {num(cy)}a{num(rx)} {num(ry)} 0 1 0 {num(2 * rx)} 0a{num(rx)} {num(ry)} 0 1 0 {num(-2 * rx)} 0Z"
    if tag == "line":
        return f"M{g('x1')} {g('y1')}L{g('x2')} {g('y2')}"
    if tag in ("polyline", "polygon"):
        pts = a["points"].replace(",", " ").split()
        pairs = [f"{pts[i]} {pts[i+1]}" for i in range(0, len(pts) - 1, 2)]
        return "M" + "L".join(pairs) + ("Z" if tag == "polygon" else "")
    if tag == "rect":
        x, y, w, h = float(g("x")), float(g("y")), float(g("width")), float(g("height"))
        rx = float(a["rx"]) if "rx" in a else (float(a["ry"]) if "ry" in a else 0.0)
        ry = float(a["ry"]) if "ry" in a else rx
        rx, ry = min(rx, w / 2), min(ry, h / 2)
        if rx == 0 and ry == 0:
            return f"M{num(x)} {num(y)}H{num(x + w)}V{num(y + h)}H{num(x)}Z"
        return (f"M{num(x + rx)} {num(y)}H{num(x + w - rx)}a{num(rx)} {num(ry)} 0 0 1 {num(rx)} {num(ry)}"
                f"V{num(y + h - ry)}a{num(rx)} {num(ry)} 0 0 1 {num(-rx)} {num(ry)}H{num(x + rx)}"
                f"a{num(rx)} {num(ry)} 0 0 1 {num(-rx)} {num(-ry)}V{num(y + ry)}a{num(rx)} {num(ry)} 0 0 1 {num(rx)} {num(-ry)}Z")
    raise SystemExit(f"不支持的图元:{tag}")

def main():
    src = locate_src()
    nodes = json.load(open(os.path.join(src, "icon-nodes.json")))
    names = [l.strip() for l in open(os.path.join(ROOT, "Scripts/lucide-icons.txt")) if l.strip() and not l.startswith("#")]
    missing = [n for n in names if n not in nodes]
    if missing:
        raise SystemExit(f"Lucide 中不存在:{missing}")
    version = json.load(open(os.path.join(src, "package.json")))["version"]
    out = ["// @author ixxxxoooo",
           f"// 由 Scripts/gen-icons.py 自动生成,请勿手改。来源:Lucide {version}(ISC 许可,见 Resources/Licenses/Lucide-LICENSE.txt)。",
           "// 每个图标是 24×24 视口内的若干 SVG path 数据(圆/矩形/折线等已在生成时转换为 path)。",
           "", "enum LucideData {", "    static let version = \"%s\"" % version, "    static let icons: [String: [String]] = ["]
    for n in sorted(set(names)):
        paths = [to_path(t, a) for t, a in nodes[n]]
        body = ", ".join('"%s"' % p.replace("\\", "\\\\").replace('"', '\\"') for p in paths)
        out.append(f'        "{n}": [{body}],')
    out += ["    ]", "}", ""]
    open(os.path.join(ROOT, "Sources/IconKit/LucideIcons.swift"), "w").write("\n".join(out))
    print(f"已生成 {len(set(names))} 个图标(Lucide {version})")

main()
