// L10n.swift — machine-readable output helpers.
// UI language is English only, by design: one string per message, no locale switching.
import Foundation

/// `--json`: read commands emit machine-readable output for scripts and agents.
var jsonMode = false

func emitJSON(_ obj: [String: Any]) {
    let data = try? JSONSerialization.data(withJSONObject: obj,
                                           options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(data: data ?? Data("{}".utf8), encoding: .utf8) ?? "{}")
}

/// Errors are machine-readable too: {"error":…,"code":…} in JSON mode, plain text otherwise.
func emitError(_ message: String, code: String) {
    if jsonMode { emitJSON(["error": message, "code": code]) } else { print("❌ \(message)") }
}
