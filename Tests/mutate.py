#!/usr/bin/env python3
"""Mutation audit for `make test` — 用來回答「這些測試有沒有在保護什麼」。

做法：把實作逐一改壞（每次一個單點改動），跑整份測試，記下哪些斷言叫了。
  KILLED    有斷言抓到 → 那個斷言在做事
  SURVIVED  沒人抓到   → 這種 bug 混得過去，是覆蓋率的洞（或是語意等價的改動）
  CRASH     整個程序 trap → 測試會失敗，但說不出是哪一項（該補 catch）

沒有任何改動殺得掉的斷言，就不是在保護任何東西。2026-07 用它清掉了六個
（測標準庫的、測測試自己佈置的、被同區塊更強斷言覆蓋的），並修掉一個被閂鎖
狀態遮住、名不副實的邊界斷言。

執行：python3 Tests/mutate.py   （會在 scratch 目錄各自複製一份原始碼編譯，不動工作區）
新增實作時把對應的改動加進 MUTATIONS，跑一次確認新測試真的會叫。
"""
import json, os, re, shutil, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(os.environ.get("TMPDIR", "/tmp"), "nibble-mutants")

# (label, file, find, replace)
MUTATIONS = [
 # ---- battery curve ----
 ("curve-no-high-clamp", "HIDPP.swift", "if mv >= curve[0].0 { return 100 }", "if mv >= 99999 { return 100 }"),
 ("curve-no-low-clamp", "HIDPP.swift", "if mv <= curve[curve.count - 1].0 { return 1 }", "if mv <= 0 { return 1 }"),
 ("curve-anchor-moved", "HIDPP.swift", "(3850, 50), (3750, 30)", "(3850, 55), (3750, 30)"),
 ("curve-inverted", "HIDPP.swift",
  "[(4180, 100), (4050, 85), (3950, 70), (3850, 50), (3750, 30), (3650, 15), (3550, 5), (3500, 2)]",
  "[(4180, 2), (4050, 5), (3950, 15), (3850, 30), (3750, 50), (3650, 70), (3550, 85), (3500, 100)]"),
 # ---- HID++ framing ----
 ("swid-not-checked", "HIDPP.swift", "if p[1] == fi && p[2] == fnsw { return true }", "if p[1] == fi { return true }"),
 ("err-8f-unmatched", "HIDPP.swift", "if p[1] == 0x8F && p[2] == fi", "if p[1] == 0x7F && p[2] == fi"),
 ("err-8f-09-misdecoded", "HIDPP.swift", "if code == 0x08 || code == 0x09 {", "if code == 0x08 {"),
 ("err-ff-ignored", "HIDPP.swift", "if resp[1] == 0xFF { throw HIDPPError.protocolError(resp[4]) }",
  "if resp[1] == 0xFE { throw HIDPPError.protocolError(resp[4]) }"),
 ("long-report-threshold", "HIDPP.swift", "let needLong = params.count > 3", "let needLong = params.count > 30"),
 ("request-field-order", "HIDPP.swift", "roundTrip(request: [dev, fi, fnsw] + params", "roundTrip(request: [fi, dev, fnsw] + params"),
 # ---- battery features ----
 ("battery-endian-swapped", "HIDPP.swift", "let mv = Int(r[0]) << 8 | Int(r[1])", "let mv = Int(r[1]) << 8 | Int(r[0])"),
 ("battery-charging-bit", "HIDPP.swift", "charging: (r[2] & 0x80) != 0", "charging: (r[2] & 0x40) != 0"),
 ("battery-1004-percent-slot", "HIDPP.swift", "return Battery(millivolts: nil, percent: Int(r[0]),\n                           charging: r[2] == 1",
  "return Battery(millivolts: nil, percent: Int(r[1]),\n                           charging: r[2] == 1"),
 ("battery-1004-reports-volts", "HIDPP.swift", "return Battery(millivolts: nil, percent: Int(r[0]),\n                           charging: r[2] == 1",
  "return Battery(millivolts: 0, percent: Int(r[0]),\n                           charging: r[2] == 1"),
 ("feature-cache-disabled", "HIDPP.swift", "if let hit = featureCache[feature] { return hit == 0 ? nil : hit }",
  "if let hit = featureCache[feature], hit == 200 { return hit == 0 ? nil : hit }"),
 # ---- spy button map ----
 ("spy-allows-primary", "Engine.swift", "if let n = Int(key.dropFirst()), n >= 3 { m[n - 1] = action }",
  "if let n = Int(key.dropFirst()), n >= 1 { m[n - 1] = action }"),
 ("spy-index-off-by-one", "Engine.swift", "if let n = Int(key.dropFirst()), n >= 3 { m[n - 1] = action }",
  "if let n = Int(key.dropFirst()), n >= 3 { m[n] = action }"),
 # ---- combo parsing ----
 ("combo-unknown-key-accepted", "Actions.swift", "guard let k = nibbleKeyCodes[part] else { return nil }\n            key = k",
  "key = nibbleKeyCodes[part] ?? 0"),
 ("combo-empty-accepted", "Actions.swift", "guard let k = key else { return nil }", "let k = key ?? 0"),
 ("combo-drops-shift", "Actions.swift", 'case "shift": flags.insert(.maskShift)', 'case "shift": break'),
 ("combo-wrong-keycode", "Actions.swift", "guard let k = nibbleKeyCodes[part] else { return nil }\n            key = k",
  "guard let k = nibbleKeyCodes[part] else { return nil }\n            key = k &+ 1"),
 # ---- macro parsing ----
 ("macro-step-cap-off", "Actions.swift", "steps.count <= 64", "steps.count <= 65"),
 ("macro-delay-cap-off", "Actions.swift", "totalDelay <= 30_000_000", "totalDelay <= 60_000_000"),
 ("macro-empty-accepted", "Actions.swift", "guard !steps.isEmpty, steps.count <= 64", "guard steps.count <= 64"),
 ("macro-bad-step-skipped", "Actions.swift", "        } else {\n            return nil\n        }", "        } else {\n            continue\n        }"),
 ("macro-ms-unparsed", "Actions.swift", 'if tok.hasSuffix("ms"), let v = UInt32(tok.dropLast(2))', 'if tok.hasSuffix("zz"), let v = UInt32(tok.dropLast(2))'),
 ("macro-s-unparsed", "Actions.swift", '} else if tok.hasSuffix("s"), let v = Double(tok.dropLast(1))', '} else if tok.hasSuffix("qq"), let v = Double(tok.dropLast(1))'),
 # ---- threshold resolution ----
 ("threshold-no-clamp", "Config.swift", "return min(max(p, lowBatteryRange.lowerBound), lowBatteryRange.upperBound)\n}", "return p\n}"),
 ("threshold-bounds-off-by-one", "Config.swift", "return min(max(p, lowBatteryRange.lowerBound), lowBatteryRange.upperBound)\n}",
  "return min(max(p, lowBatteryRange.lowerBound + 1), lowBatteryRange.upperBound - 1)\n}"),
 ("threshold-ignores-notify-off", "Config.swift", "if cfg?.lowBatteryNotify == false { return nil }", "if cfg?.lowBatteryNotify == nil { return nil }"),
 ("threshold-wrong-default", "Config.swift", "guard let p = cfg?.lowBatteryPercent else { return defaultLowBatteryPercent }",
  "guard let p = cfg?.lowBatteryPercent else { return 20 }"),
 # ---- latch ----
 ("latch-no-threshold-rearm", "Config.swift", "if limit != lastLimit { fired = false; lastLimit = limit }", "if limit != lastLimit { lastLimit = limit }"),
 ("latch-no-charge-reset", "Config.swift", "if charging || percent > limit { fired = false; return false }", "if charging || percent > limit { return false }"),
 ("latch-no-disable-rearm", "Config.swift", "guard let limit else { fired = false; return false }   // 通知關閉", "guard let limit else { return false }   // 通知關閉"),
 ("latch-fires-every-poll", "Config.swift", "        if fired { return false }", "        if fired, percent < 0 { return false }"),
 ("latch-boundary-excluded", "Config.swift", "if charging || percent > limit { fired = false; return false }", "if charging || percent >= limit { fired = false; return false }"),
 # ---- config write protection ----
 ("write-weak-load", "Config.swift",
  'guard let data = try? Data(contentsOf: bmConfigURL) else { return BMConfig() }\n    do { return try JSONDecoder().decode(BMConfig.self, from: data) }\n    catch { throw ConfigError.unreadable("\\(error)") }',
  "return loadConfig() ?? BMConfig()"),
 ("write-discards-existing", "Config.swift", "func updateLowBatteryNotify(enabled: Bool, percent: Int) throws {\n    var cfg = try loadConfigForWrite()",
  "func updateLowBatteryNotify(enabled: Bool, percent: Int) throws {\n    var cfg = BMConfig()"),
 ("write-no-clamp", "Config.swift", "cfg.lowBatteryPercent = min(max(percent, lowBatteryRange.lowerBound), lowBatteryRange.upperBound)",
  "cfg.lowBatteryPercent = percent"),
 ("save-clobbers-symlink", "Config.swift", "write(to: bmConfigURL.resolvingSymlinksInPath(), options: .atomic)", "write(to: bmConfigURL, options: .atomic)"),
 # 預期 SURVIVED：單一程序觀察不到原子性（見 Tests/main.swift 開頭的已知缺口）
 ("save-not-atomic", "Config.swift", "write(to: bmConfigURL.resolvingSymlinksInPath(), options: .atomic)", "write(to: bmConfigURL.resolvingSymlinksInPath())"),
 # ---- profile resolution ----
 ("profiles-no-legacy-fallback", "Config.swift", "guard let profiles = cfg.buttonProfiles, !profiles.isEmpty else { return cfg.buttonMaps ?? [:] }",
  "guard let profiles = cfg.buttonProfiles, !profiles.isEmpty else { return [:] }"),
 ("profiles-no-dangling-fallback", "Config.swift", "return profiles[cfg.activeProfile ?? defaultProfileName] ?? profiles[defaultProfileName] ?? [:]",
  "return profiles[cfg.activeProfile ?? defaultProfileName] ?? [:]"),
 ("profiles-empty-falls-back", "Config.swift", "return profiles[cfg.activeProfile ?? defaultProfileName] ?? profiles[defaultProfileName] ?? [:]",
  "let m = profiles[cfg.activeProfile ?? defaultProfileName] ?? [:]\n    return m.isEmpty ? (profiles[defaultProfileName] ?? [:]) : m"),
 # 原本是把 return true 翻成 false——那會造出前後矛盾的比較函式，排序結果不穩定，
 # 於是這個 mutant 每次跑的存活與否都不一樣。改成「整條規則被刪掉、退回純字母序」，
 # 那才是會真的發生的回歸，而且結果確定。
 ("profiles-default-not-first", "Config.swift",
  """return profiles.keys.sorted { a, b in
        if a == defaultProfileName { return true }      // Default 永遠排第一
        if b == defaultProfileName { return false }
        return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }""",
  "return profiles.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }"),
 ("current-profile-no-fallback", "Config.swift", "return names.contains(active) ? active : defaultProfileName", "return active"),
 ("migrate-keeps-legacy-field", "Config.swift", "    cfg.buttonMaps = nil\n", "\n"),
 ("migrate-not-idempotent", "Config.swift", "guard cfg.buttonProfiles == nil else { return }", "guard true else { return }"),
 ("migrate-no-active-profile", "Config.swift", "if cfg.activeProfile == nil { cfg.activeProfile = defaultProfileName }", "if false { cfg.activeProfile = defaultProfileName }"),
 # ---- menu bar liveness ----
 ("lock-held-reads-as-free", "MenuBar.swift", "if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }\n    return true",
  "if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }\n    return false"),
 ("lock-unlocked-reads-as-held", "MenuBar.swift", "if flock(fd, LOCK_EX | LOCK_NB) == 0 { flock(fd, LOCK_UN); return false }",
  "if flock(fd, LOCK_EX | LOCK_NB) == 999 { flock(fd, LOCK_UN); return false }"),

 # ================= round 2: aimed at checks nothing killed =================
 ("curve-interpolation-scaled", "HIDPP.swift", "return p2 + (mv - v2) * (p1 - p2) / (v1 - v2) }", "return p2 + (mv - v2) * (p1 - p2) * 30 / (v1 - v2) }"),
 ("keytable-drops-c", "Actions.swift", '"c": 8, ', ''),
 ("keytable-drops-4", "Actions.swift", '"4": 21, ', ''),
 ("keytable-drops-left", "Actions.swift", '"left": 123, ', ''),
 ("keytable-drops-f13", "Actions.swift", '"f13": 105, ', ''),
 ("macro-requires-two-steps", "Actions.swift", "guard !steps.isEmpty, steps.count <= 64", "guard steps.count > 1, steps.count <= 64"),
 ("macro-cap-63", "Actions.swift", "steps.count <= 64", "steps.count <= 63"),
 ("ping-fields-swapped", "HIDPP.swift", "return (Int(r[0]), Int(r[1]))", "return (Int(r[1]), Int(r[0]))"),
 ("fnsw-shift-wrong", "HIDPP.swift", "let fnsw = (fn << 4) | swid", "let fnsw = (fn << 3) | swid"),
 ("battery-skips-1001", "HIDPP.swift", "if try featureIndex(of: 0x1001) != nil {\n            let r = try call(feature: 0x1001", "if try featureIndex(of: 0x1001) != nil, false {\n            let r = try call(feature: 0x1001"),
 ("json-keys-renamed", "Config.swift", "    var activeProfile: String? = nil\n}",
  "    var activeProfile: String? = nil\n\n    enum CodingKeys: String, CodingKey {\n        case dpi = \"dpiX\", reportRateHz, rgb = \"rgbX\", wheelMode, wheelThreshold\n        case lowBatteryNotify, lowBatteryPercent, buttonMaps = \"buttonMapsX\", buttonProfiles, activeProfile\n    }\n}"),
 ("latch-never-fires", "Config.swift", "        fired = true\n        return true", "        fired = true\n        return false"),
 ("latch-disabled-fires", "Config.swift", "guard let limit else { fired = false; return false }   // 通知關閉", "guard let limit else { fired = false; return true }   // 通知關閉"),
 ("latch-window-too-wide", "Config.swift", "if charging || percent > limit { fired = false; return false }", "if charging || percent > limit + 5 { fired = false; return false }"),
 ("write-drops-percent", "Config.swift", "cfg.lowBatteryPercent = min(max(percent, lowBatteryRange.lowerBound), lowBatteryRange.upperBound)", "_ = min(max(percent, lowBatteryRange.lowerBound), lowBatteryRange.upperBound)"),
 ("loadforwrite-throws-on-missing", "Config.swift", "guard let data = try? Data(contentsOf: bmConfigURL) else { return BMConfig() }", "let data = try Data(contentsOf: bmConfigURL)"),
 ("lock-missing-file-is-running", "MenuBar.swift", "guard fd >= 0 else { return false }", "guard fd >= 0 else { return true }"),
 # 預期 SURVIVED（語意等價）：names.contains(active) 那道關卡讓這個預設值換成什麼都一樣
 ("current-profile-bogus-default", "Config.swift", "let active = cfg?.activeProfile ?? defaultProfileName", "let active = cfg?.activeProfile ?? \"None\""),
 ("current-profile-always-default", "Config.swift", "let active = cfg?.activeProfile ?? defaultProfileName", "let active = defaultProfileName"),
 ("profilenames-empty-for-legacy", "Config.swift", "guard let profiles = cfg?.buttonProfiles, !profiles.isEmpty else { return [defaultProfileName] }", "guard let profiles = cfg?.buttonProfiles, !profiles.isEmpty else { return [] }"),
 ("active-map-ignores-selection", "Config.swift", "return profiles[cfg.activeProfile ?? defaultProfileName] ?? profiles[defaultProfileName] ?? [:]", "return profiles[defaultProfileName] ?? [:]"),
 ("profilenames-drops-one", "Config.swift", "    return profiles.keys.sorted { a, b in", "    return profiles.keys.dropLast().sorted { a, b in"),
 ("migrate-loses-content", "Config.swift", "cfg.buttonProfiles = [defaultProfileName: cfg.buttonMaps ?? [:]]", "cfg.buttonProfiles = [defaultProfileName: [:]]"),
 # 預期 SURVIVED（不可及）：migrateToProfiles 對已遷移的設定會提早 return，
 # 所以要同時改掉那個 guard 才看得出差別——單點改動碰不到
 ("migrate-resets-active", "Config.swift", "if cfg.activeProfile == nil { cfg.activeProfile = defaultProfileName }", "cfg.activeProfile = defaultProfileName"),
]

def run_one(m):
    label, fname, find, repl = m
    d = os.path.join(WORK, label)
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(os.path.join(REPO, "Sources"), os.path.join(d, "Sources"))
    shutil.copytree(os.path.join(REPO, "Tests"), os.path.join(d, "Tests"))
    target = os.path.join(d, "Sources", fname)
    src = open(target).read()
    if find not in src:
        return {"label": label, "status": "PATCH_MISS", "failed": []}
    open(target, "w").write(src.replace(find, repl, 1))

    srcs = [os.path.join(d, "Sources", f) for f in sorted(os.listdir(os.path.join(d, "Sources")))
            if f.endswith(".swift") and f != "main.swift"]
    srcs += [os.path.join(d, "Tests", "main.swift")]
    binp = os.path.join(d, "t")
    cp = subprocess.run(["swiftc", "-swift-version", "5"] + srcs + ["-o", binp],
                        capture_output=True, text=True)
    if cp.returncode != 0:
        return {"label": label, "status": "COMPILE_FAIL", "failed": [],
                "err": cp.stderr.strip().splitlines()[-3:]}
    rp = subprocess.run([binp], capture_output=True, text=True, timeout=120)
    out = rp.stdout
    failed = re.findall(r"^   (.+?)(?:: got .*)?  \(line \d+\)$", out, re.M)
    open(os.path.join(d, "stdout.txt"), "w").write(out + "\n--stderr--\n" + rp.stderr)
    status = "KILLED" if failed else ("CRASH" if rp.returncode not in (0, 1) else
                                      "SURVIVED" if rp.returncode == 0 else "FAILED_NO_NAMES")
    if rp.returncode not in (0, 1) and not failed:
        status = "CRASH"
    return {"label": label, "status": status, "failed": failed, "rc": rp.returncode,
            "crash": (rp.stderr.strip().splitlines()[-1:] if rp.returncode not in (0, 1) else [])}

os.makedirs(WORK, exist_ok=True)
with ThreadPoolExecutor(max_workers=5) as ex:
    results = list(ex.map(run_one, MUTATIONS))
json.dump(results, open(os.path.join(WORK, "results.json"), "w"), indent=1)
for r in results:
    print(f"{r['status']:14} {r['label']:34} {len(r['failed'])} checks noticed"
          + (f"  {r.get('err') or r.get('crash')}" if r['status'] in ("COMPILE_FAIL", "CRASH") else ""))
