#!/usr/bin/env python3
# @author ixxxxoooo
# 把各语法仓库的 highlights.scm 打包成 Swift 源码(Sources/EditorKit/TreeSitter/TreeSitterQueries.swift)。
# 用法:先把各语法仓库克隆到同一目录(默认 /tmp/tsprobe),再 `python3 Scripts/gen-ts-queries.py [目录]`。
import os
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "/tmp/tsprobe"
sources = {
    "swift": ["tree-sitter-swift/queries/highlights.scm"],
    "javascript": ["tree-sitter-javascript/queries/highlights.scm"],
    "typescript": ["tree-sitter-javascript/queries/highlights.scm", "tree-sitter-typescript/queries/highlights.scm"],
    "python": ["tree-sitter-python/queries/highlights.scm"],
    "json": ["tree-sitter-json/queries/highlights.scm"],
    "rust": ["tree-sitter-rust/queries/highlights.scm"],
    "go": ["tree-sitter-go/queries/highlights.scm"],
    "css": ["tree-sitter-css/queries/highlights.scm"],
    "html": ["tree-sitter-html/queries/highlights.scm"],
}
out = ["// @author ixxxxoooo",
       "// 各语言的 tree-sitter 高亮查询(由 Scripts/gen-ts-queries.py 生成,勿手改;来源为各上游语法仓库的 queries/highlights.scm,遵循其许可证)。",
       "", "enum TreeSitterQueries {",
       "    /// 语言名 → 高亮查询源码", "    static let highlights: [String: String] = ["]
for name, files in sources.items():
    text = "\n".join(open(os.path.join(root, f)).read() for f in files)
    assert '"""#' not in text
    out.append(f'        "{name}": #"""')
    out.append(text.rstrip("\n"))
    out.append('"""#,')
out += ["    ]", "}", ""]
dest = os.path.join(os.path.dirname(__file__), "..", "Sources/EditorKit/TreeSitter/TreeSitterQueries.swift")
open(dest, "w").write("\n".join(out))
print("已生成", os.path.normpath(dest))
