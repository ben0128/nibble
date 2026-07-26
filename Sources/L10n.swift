// L10n.swift — 極簡雙語（英文為主，系統語言為中文時顯示中文）＋ JSON 輸出模式
// 零依賴做法：不用 .lproj bundle（單一 binary 帶不了），呼叫點自帶兩種語言字串。
import Foundation

let nibbleIsChinese: Bool = (Locale.preferredLanguages.first ?? "en").hasPrefix("zh")

/// L("English", "中文")
func L(_ en: String, _ zh: String) -> String { nibbleIsChinese ? zh : en }

/// `--json`：所有讀取指令改輸出機器可讀格式（給腳本與 AI agent）
var jsonMode = false

func emitJSON(_ obj: [String: Any]) {
    let data = try? JSONSerialization.data(withJSONObject: obj,
                                           options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}")
}

/// 錯誤也要機器可讀：JSON 模式輸出 {"error":…,"code":…}，否則印人類訊息
func emitError(_ message: String, code: String) {
    if jsonMode { emitJSON(["error": message, "code": code]) } else { print("❌ \(message)") }
}
