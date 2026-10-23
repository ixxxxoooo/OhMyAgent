// @author ixxxxoooo
// 内置语言 snippet 表:前缀 → snippet 源文本(VS Code 语法)。光标在前缀词后按 Tab 展开。
// 制表符 `\t` 展开时会换成当前缩进单位。

import Foundation

/// 内置 snippet。
public enum NativeSnippets {
    /// 一条 snippet。
    public struct Entry: Sendable, Equatable {
        /// 触发前缀。
        public let prefix: String
        /// 说明(补全列表展示)。
        public let detail: String
        /// snippet 源文本。
        public let body: String
    }

    /// 某语言的全部 snippet。
    public static func entries(for language: SyntaxLanguage) -> [Entry] {
        switch language {
        case .swift: return swift
        case .javascript, .typescript: return javascript
        case .python: return python
        case .go: return go
        case .rust: return rust
        case .java: return java
        case .c: return cLike
        case .shell: return shell
        default: return []
        }
    }

    /// 按前缀精确查找。
    public static func entry(prefix: String, language: SyntaxLanguage) -> Entry? {
        entries(for: language).first { $0.prefix == prefix }
    }

    private static func make(_ prefix: String, _ detail: String, _ body: String) -> Entry {
        Entry(prefix: prefix, detail: detail, body: body)
    }

    static let swift: [Entry] = [
        make("func", "函数", "func ${1:name}(${2:params}) ${3:-> ${4:Void} }{\n\t$0\n}"),
        make("class", "类", "final class ${1:Name} {\n\t$0\n}"),
        make("struct", "结构体", "struct ${1:Name} {\n\t$0\n}"),
        make("enum", "枚举", "enum ${1:Name} {\n\tcase ${2:first}\n\t$0\n}"),
        make("ext", "扩展", "extension ${1:Type} {\n\t$0\n}"),
        make("guard", "guard", "guard ${1:condition} else {\n\t${2:return}\n}\n$0"),
        make("guardlet", "guard let", "guard let ${1:value} = ${2:optional} else {\n\t${3:return}\n}\n$0"),
        make("iflet", "if let", "if let ${1:value} = ${2:optional} {\n\t$0\n}"),
        make("for", "for 循环", "for ${1:item} in ${2:items} {\n\t$0\n}"),
        make("switch", "switch", "switch ${1:value} {\ncase ${2:pattern}:\n\t$0\ndefault:\n\tbreak\n}"),
        make("test", "Swift Testing 用例", "@Test(\"${1:描述}\")\nfunc ${2:name}() {\n\t#expect($0)\n}"),
        make("task", "Task", "Task { @MainActor in\n\t$0\n}"),
        make("mark", "MARK 分节", "// MARK: ${1:分节}\n$0"),
    ]

    static let javascript: [Entry] = [
        make("fn", "函数", "function ${1:name}(${2:params}) {\n\t$0\n}"),
        make("af", "箭头函数", "const ${1:name} = (${2:params}) => {\n\t$0\n}"),
        make("for", "for 循环", "for (let ${1:i} = 0; ${1:i} < ${2:array}.length; ${1:i}++) {\n\t$0\n}"),
        make("forof", "for…of", "for (const ${1:item} of ${2:items}) {\n\t$0\n}"),
        make("if", "if", "if (${1:condition}) {\n\t$0\n}"),
        make("ife", "if…else", "if (${1:condition}) {\n\t$2\n} else {\n\t$0\n}"),
        make("try", "try…catch", "try {\n\t$1\n} catch (${2:error}) {\n\t$0\n}"),
        make("imp", "import", "import ${2:name} from '${1:module}'$0"),
        make("clg", "console.log", "console.log($0)"),
        make("class", "类", "class ${1:Name} {\n\tconstructor(${2:params}) {\n\t\t$0\n\t}\n}"),
        make("async", "async 函数", "async function ${1:name}(${2:params}) {\n\t$0\n}"),
    ]

    static let python: [Entry] = [
        make("def", "函数", "def ${1:name}(${2:params}):\n\t${0:pass}"),
        make("class", "类", "class ${1:Name}:\n\tdef __init__(self${2:, params}):\n\t\t${0:pass}"),
        make("for", "for 循环", "for ${1:item} in ${2:items}:\n\t$0"),
        make("if", "if", "if ${1:condition}:\n\t$0"),
        make("ife", "if…else", "if ${1:condition}:\n\t$2\nelse:\n\t$0"),
        make("try", "try…except", "try:\n\t$1\nexcept ${2:Exception} as ${3:e}:\n\t$0"),
        make("with", "with", "with ${1:expr} as ${2:name}:\n\t$0"),
        make("main", "入口", "if __name__ == \"__main__\":\n\t$0"),
    ]

    static let go: [Entry] = [
        make("func", "函数", "func ${1:name}(${2:params}) ${3:error }{\n\t$0\n}"),
        make("iferr", "if err", "if err != nil {\n\treturn ${1:err}\n}\n$0"),
        make("for", "for 循环", "for ${1:i} := 0; ${1:i} < ${2:n}; ${1:i}++ {\n\t$0\n}"),
        make("forr", "for range", "for ${1:_}, ${2:v} := range ${3:items} {\n\t$0\n}"),
        make("struct", "结构体", "type ${1:Name} struct {\n\t$0\n}"),
        make("test", "测试", "func Test${1:Name}(t *testing.T) {\n\t$0\n}"),
    ]

    static let rust: [Entry] = [
        make("fn", "函数", "fn ${1:name}(${2:params}) ${3:-> ${4:()} }{\n\t$0\n}"),
        make("struct", "结构体", "struct ${1:Name} {\n\t$0\n}"),
        make("impl", "impl", "impl ${1:Type} {\n\t$0\n}"),
        make("match", "match", "match ${1:value} {\n\t${2:pattern} => $0,\n\t_ => {}\n}"),
        make("test", "测试", "#[test]\nfn ${1:name}() {\n\t$0\n}"),
        make("derive", "derive", "#[derive(${1:Debug, Clone})]\n$0"),
    ]

    static let java: [Entry] = [
        make("main", "main 方法", "public static void main(String[] args) {\n\t$0\n}"),
        make("class", "类", "public class ${1:Name} {\n\t$0\n}"),
        make("for", "for 循环", "for (int ${1:i} = 0; ${1:i} < ${2:n}; ${1:i}++) {\n\t$0\n}"),
        make("sout", "System.out", "System.out.println($0);"),
        make("try", "try…catch", "try {\n\t$1\n} catch (${2:Exception} ${3:e}) {\n\t$0\n}"),
    ]

    static let cLike: [Entry] = [
        make("main", "main 函数", "int main(int argc, char *argv[]) {\n\t$0\n\treturn 0;\n}"),
        make("for", "for 循环", "for (int ${1:i} = 0; ${1:i} < ${2:n}; ${1:i}++) {\n\t$0\n}"),
        make("if", "if", "if (${1:condition}) {\n\t$0\n}"),
        make("inc", "include", "#include <${1:stdio.h}>$0"),
    ]

    static let shell: [Entry] = [
        make("if", "if", "if [[ ${1:condition} ]]; then\n\t$0\nfi"),
        make("for", "for", "for ${1:item} in ${2:items}; do\n\t$0\ndone"),
        make("fn", "函数", "${1:name}() {\n\t$0\n}"),
        make("shebang", "shebang", "#!/usr/bin/env bash\nset -euo pipefail\n$0"),
    ]
}
