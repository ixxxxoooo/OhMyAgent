// @author ixxxxoooo
// ChatKit 内的本地化:库本身没有资源包,文案键(中文原文)取自主应用的 `Localizable.strings`。
// 找不到译文时原样返回中文,因此测试与脚本化环境不受影响。

import Foundation

/// 本地化访问器。
public enum ChatL10n {
    /// 取译文。
    /// - Parameter key: 中文原文(即 `Localizable.strings` 的键)
    /// - Returns: 当前语言的译文
    public static func t(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    /// 取带占位符的译文并格式化。
    /// - Parameters:
    ///   - key: 中文原文(含 `%@` / `%lld`)
    ///   - args: 参数
    public static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }
}
