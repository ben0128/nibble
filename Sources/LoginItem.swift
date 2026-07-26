// LoginItem.swift — 開機自動啟動選單列（SMAppService，macOS 13+）
//
// 跟 `nibble replay install` 是兩件不同的事，而且以前只有後者：
//   replay    — 登入時跑一次 `nibble apply` 就退出，還原 DPI / 回報率 / 燈效
//   login item — 讓選單列常駐起來，改鍵引擎才有宿主
// 少了這個，使用者重開機後 DPI 會回來但按鍵全死——而且介面上沒有任何線索。
import Foundation
import ServiceManagement

/// 「我是不是真的從 .app 裡執行」——不能只看 bundleIdentifier。
/// 在這個 repo 的根目錄跑 ./nibble 時，CFBundle 會找到 Resources/Info.plist、
/// 把整個 repo 當成 flat bundle，於是 id 有值（com.ben0128.nibble）但 .app 並不存在。
/// 這個誤判會讓「沒帶引數就進選單列」的規則在原始碼目錄裡誤觸發。
func runningFromAppBundle() -> Bool {
    Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
}

enum LoginItem {
    /// SMAppService 註冊的是「這個 bundle」；裸 binary 沒有 bundle 可註冊
    static var supported: Bool { runningFromAppBundle() }

    static var status: SMAppService.Status? {
        guard supported else { return nil }
        return SMAppService.mainApp.status
    }

    static var enabled: Bool { status == .enabled }

    /// 一次問完：supported / enabled / 給人看的說明。
    /// 分三個 property 各問一次 SMAppService 等於每次刷新都跟 servicemanagementd
    /// 來回三趟，而這個刷新掛在 45 秒的計時器和每次視窗變成前景上。
    static var snapshot: (supported: Bool, enabled: Bool, note: String) {
        guard supported else { return (false, false, "needs /Applications/Nibble.app — run `make install-app`") }
        let st = SMAppService.mainApp.status
        return (true, st == .enabled, describe(st))
    }

    static func describe(_ st: SMAppService.Status) -> String {
        switch st {
        case .enabled:          return "on"
        // 實測：從未註冊過的 app 回報 .notFound，不是 .notRegistered。把它當成「還沒打開」，
        // 不然每個沒用過這個功能的人都會看到一句「bundle 不見了」的假警告
        case .notRegistered, .notFound: return "off"
        case .requiresApproval: return "blocked in System Settings › General › Login Items"
        @unknown default:       return "unknown"
        }
    }

    /// 系統設定裡被關掉（或 MDM 擋掉）的狀態：重新註冊沒有用，只能請使用者去開
    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ on: Bool) throws {
        guard supported else { throw LoginItemError.notBundled }
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// 給人看的一行說明。`.requiresApproval` 是最容易卡住人的狀態：
    /// 註冊成功了，但使用者（或 MDM）在系統設定裡把它關掉，光看勾選框看不出來。
    static var note: String { snapshot.note }
}

enum LoginItemError: Error, CustomStringConvertible {
    case notBundled

    var description: String {
        "login at startup needs the app bundle: make install-app, then open /Applications/Nibble.app"
    }
}
