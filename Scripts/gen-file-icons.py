#!/usr/bin/env python3
# @author ygw
# 从 Material Icon Theme(MIT 许可,PKief)生成 Sources/IconKit/FileIconData.swift:
# 资源管理器/标签页使用的彩色「文件类型」图标。只收录常用扩展名、特殊文件名与文件夹名,
# 避免把 1200+ 个图标全部编进二进制。
# 用法:Scripts/gen-file-icons.py [--src <material-icon-theme 解压目录(package)>]
import json, os, re, subprocess, sys, tempfile, tarfile, glob
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXTENSIONS = """swift m mm h hpp c cc cpp cs rs go py pyi rb php java kt kts scala dart lua r pl sh bash zsh fish ps1 bat
js mjs cjs jsx ts tsx mts cts vue svelte astro html htm css scss sass less styl json jsonc json5 yaml yml toml ini conf cfg
xml plist xcconfig entitlements strings xib storyboard md mdx markdown txt rtf log csv tsv sql graphql gql proto lock
png jpg jpeg gif webp svg ico icns bmp tiff heic pdf mp3 wav mp4 mov zip tar gz tgz rar 7z dmg pkg
dockerfile env gitignore gitattributes editorconfig diff patch tf wasm nix zig ex exs erl hs clj ml vim""".split()
FILENAMES = """package.json package-lock.json pnpm-lock.yaml yarn.lock tsconfig.json Package.swift Package.resolved Podfile Cartfile
Dockerfile docker-compose.yml docker-compose.yaml Makefile CMakeLists.txt README.md readme.md LICENSE LICENSE.md CHANGELOG.md
CONTRIBUTING.md AGENTS.md CLAUDE.md .gitignore .gitattributes .editorconfig .env .env.local .prettierrc .eslintrc.json
Cargo.toml Cargo.lock go.mod go.sum requirements.txt pyproject.toml Gemfile Info.plist .swiftlint.yml .swift-version
vite.config.ts webpack.config.js tailwind.config.js .mcp.json .npmrc .nvmrc""".split()
FOLDERS = """src Sources source lib libs app apps test tests Tests __tests__ spec docs doc documentation build dist out target
node_modules vendor Vendor .git .github .gitlab .vscode .cursor .claude .idea scripts Scripts script bin assets images img
icons fonts resources Resources public static components views controllers models services utils helpers config configs
Config hooks .githooks types interfaces packages modules plugins templates temp tmp cache logs log database db migrations
api server client frontend backend ios android macos mac tools tool examples example demo benchmark perf .build
.specstory .swiftpm Pods Carthage themes styles css sass""".split()

def locate_src():
    if "--src" in sys.argv:
        return sys.argv[sys.argv.index("--src") + 1]
    tmp = tempfile.mkdtemp(prefix="mit-")
    subprocess.run(["npm", "pack", "material-icon-theme", "--silent"], cwd=tmp, check=True, stdout=subprocess.DEVNULL)
    with tarfile.open(glob.glob(os.path.join(tmp, "material-icon-theme-*.tgz"))[0]) as t:
        t.extractall(tmp)
    return os.path.join(tmp, "package")

def num(v):
    v = float(v)
    return str(int(v)) if v == int(v) else ("%.3f" % v).rstrip("0").rstrip(".")

def shape_path(tag, a):
    g = lambda k, d="0": float(re.sub(r"[a-z%]+$", "", a.get(k, d)))
    if tag == "path": return a["d"]
    if tag == "circle":
        cx, cy, r = g("cx"), g("cy"), g("r")
        return f"M{num(cx - r)} {num(cy)}a{num(r)} {num(r)} 0 1 0 {num(2 * r)} 0a{num(r)} {num(r)} 0 1 0 {num(-2 * r)} 0Z"
    if tag == "ellipse":
        cx, cy, rx, ry = g("cx"), g("cy"), g("rx"), g("ry")
        return f"M{num(cx - rx)} {num(cy)}a{num(rx)} {num(ry)} 0 1 0 {num(2 * rx)} 0a{num(rx)} {num(ry)} 0 1 0 {num(-2 * rx)} 0Z"
    if tag in ("polygon", "polyline"):
        pts = a["points"].replace(",", " ").split()
        return "M" + "L".join(f"{pts[i]} {pts[i+1]}" for i in range(0, len(pts) - 1, 2)) + "Z"
    if tag == "rect":
        x, y, w, h = g("x"), g("y"), g("width"), g("height")
        rx = g("rx") if "rx" in a else (g("ry") if "ry" in a else 0.0)
        ry = g("ry") if "ry" in a else rx
        rx, ry = min(rx, w / 2), min(ry, h / 2)
        if rx == 0 and ry == 0: return f"M{num(x)} {num(y)}H{num(x + w)}V{num(y + h)}H{num(x)}Z"
        return (f"M{num(x + rx)} {num(y)}H{num(x + w - rx)}a{num(rx)} {num(ry)} 0 0 1 {num(rx)} {num(ry)}"
                f"V{num(y + h - ry)}a{num(rx)} {num(ry)} 0 0 1 {num(-rx)} {num(ry)}H{num(x + rx)}"
                f"a{num(rx)} {num(ry)} 0 0 1 {num(-rx)} {num(-ry)}V{num(y + ry)}a{num(rx)} {num(ry)} 0 0 1 {num(rx)} {num(-ry)}Z")
    return None

def parse_svg(path):
    """返回 (视口边长, [(填充色, 不透明度, path d)])。"""
    root = ET.parse(path).getroot()
    vb = [float(x) for x in root.get("viewBox", "0 0 16 16").split()]
    shapes, skipped = [], 0
    def walk(el, fill, opacity):
        nonlocal skipped
        tag = el.tag.split("}")[1]
        fill = el.get("fill", fill)
        op = opacity * float(el.get("opacity", "1")) * float(el.get("fill-opacity", "1"))
        if tag in ("defs", "clipPath", "mask", "linearGradient", "radialGradient", "style", "title"):
            return
        if el.get("transform") or el.get("stroke") and (el.get("fill") in (None, "none")):
            skipped += 1
            return
        d = shape_path(tag, el.attrib)
        if d and fill and fill != "none" and not fill.startswith("url"):
            shapes.append((fill, op, d))
        elif d and fill and fill.startswith("url"):
            skipped += 1
        for child in el: walk(child, fill, op)
    walk(root, "#000000", 1.0)
    return vb[2], shapes, skipped

def main():
    src = locate_src()
    theme = json.load(open(os.path.join(src, "dist/material-icons.json")))
    names = {theme["file"], theme["folder"], theme["folderExpanded"]}
    ext_map = {e: theme["fileExtensions"][e] for e in EXTENSIONS if e in theme["fileExtensions"]}
    # 语言 ID 兜底(如 dockerfile、env)
    for e in EXTENSIONS:
        if e not in ext_map and e in theme["languageIds"]: ext_map[e] = theme["languageIds"][e]
    name_map = {n: theme["fileNames"][n] for n in FILENAMES if n in theme["fileNames"]}
    folder_map = {n: theme["folderNames"][n] for n in FOLDERS if n in theme["folderNames"]}
    folder_open = {n: theme["folderNamesExpanded"].get(n, theme["folderNames"][n] + "-open") for n in folder_map}
    for m in (ext_map, name_map, folder_map, folder_open): names.update(m.values())
    icons = {}
    for n in sorted(names):
        f = os.path.join(src, "icons", n + ".svg")
        if not os.path.exists(f):
            print("缺少图标:", n); continue
        size, shapes, skipped = parse_svg(f)
        if not shapes: print("无可用图元:", n); continue
        if skipped: print(f"提示:{n} 跳过 {skipped} 个图元")
        icons[n] = (size, shapes)
    def lit(s): return json.dumps(s, ensure_ascii=False)
    out = ["// @author ygw",
           "// 自动生成,请勿手改:Scripts/gen-file-icons.py(来源 Material Icon Theme 5.x,MIT 许可,见 Resources/Licenses)。",
           "// 格式:每个图标一段文本,首行为视口边长,其后每行「填充色 不透明度 path」。",
           "", "enum FileIconData {", "    static let icons: [String: String] = ["]
    for n, (size, shapes) in icons.items():
        body = num(size) + "\\n" + "\\n".join(f"{c} {num(o) if o != 1 else '1'} {d}" for c, o, d in shapes)
        out.append(f'        "{n}": "{body}",')
    out.append("    ]")
    def dict_lit(name, m):
        rows = "\n".join(f'        {lit(k)}: {lit(v)},' for k, v in sorted(m.items()) if v in icons)
        return f"    static let {name}: [String: String] = [\n{rows}\n    ]"
    out += [dict_lit("extensions", ext_map), dict_lit("fileNames", name_map), dict_lit("folders", folder_map), dict_lit("foldersOpen", folder_open),
            f'    static let defaultFile = {lit(theme["file"])}', f'    static let defaultFolder = {lit(theme["folder"])}',
            f'    static let defaultFolderOpen = {lit(theme["folderExpanded"])}', "}", ""]
    open(os.path.join(ROOT, "Sources/IconKit/FileIconData.swift"), "w").write("\n".join(out))
    print(f"已生成 {len(icons)} 个图标,扩展名 {len(ext_map)},文件名 {len(name_map)},文件夹 {len(folder_map)}")

main()
