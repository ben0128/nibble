// nibble.rs — Windows CLI（console subsystem）。
// 指令面、--json 的鍵名、exit codes（0/1/2/64）全部鏡射 macOS 版——
// 對 script 和 agent 來說，兩個平台是同一個工具。
#[cfg(not(windows))]
fn main() {
    eprintln!("nibble.exe is the Windows build; on macOS use the Swift nibble.");
    std::process::exit(2);
}

#[cfg(windows)]
fn main() {
    std::process::exit(cli::run());
}

#[cfg(windows)]
mod cli {
    use nibble_core::config;
    use nibble_core::hidpp::{apply_rgb, with_host_fallback, Device, Transport};
    use nibble_win::transport::{open_all, WinTransport};
    use nibble_win::{config_path, software_id, tray_lock, WIN_VERSION};
    use serde_json::json;

    pub fn run() -> i32 {
        let mut args: Vec<String> = std::env::args().skip(1).collect();
        let json_mode = if let Some(i) = args.iter().position(|a| a == "--json") {
            args.remove(i);
            true
        } else {
            false
        };
        let cmd = args.first().cloned().unwrap_or_else(|| "help".into());
        let sub: Vec<String> = args.into_iter().skip(1).collect();

        match cmd.as_str() {
            "version" => {
                if json_mode {
                    println!("{}", json!({ "version": WIN_VERSION }));
                } else {
                    println!("nibble {WIN_VERSION} (windows)");
                }
                0
            }
            "status" => cmd_status(json_mode),
            "battery" => cmd_battery(json_mode),
            "dpi" => cmd_dpi(&sub, json_mode),
            "rate" => cmd_rate(&sub, json_mode),
            "rgb" => cmd_rgb(&sub, json_mode),
            "mode" => cmd_mode(&sub, json_mode),
            "config" => cmd_config(&sub, json_mode),
            "apply" => cmd_apply(json_mode),
            "doctor" => cmd_doctor(json_mode),
            "help" => {
                help();
                0
            }
            _ => {
                help();
                64
            }
        }
    }

    fn help() {
        println!(
            "Nibble {WIN_VERSION} for Windows — lightweight Logitech mouse control (native · zero-dependency · no daemon by default)\n\n\
             READ\n\
             \x20 nibble status [--json]        device overview\n\
             \x20 nibble battery [--json]       one line, script-friendly\n\
             \x20 nibble doctor [--json]        diagnose device, config, tray — start here if stuck\n\n\
             CONFIGURE (runtime writes, reverted by power cycle, verified by read-back)\n\
             \x20 nibble dpi [50-25600]         get / set DPI\n\
             \x20 nibble rate [125|250|500|1000] get / set report rate\n\
             \x20 nibble rgb off|cycle|breathing|show   lighting\n\
             \x20 nibble mode [host|onboard]    control-mode flag\n\n\
             CONFIG & APPLY\n\
             \x20 nibble config init|show       %APPDATA%\\nibble\\nibble.json (same schema as macOS)\n\
             \x20 nibble apply                  apply the config file\n\n\
             UI\n\
             \x20 nibble-tray.exe               battery + controls in the notification area\n\n\
             Exit codes: 0 ok · 1 no awake device / not applied · 2 transport error · 64 usage."
        );
    }

    fn emit_error(msg: &str, code: &str, json_mode: bool) {
        if json_mode {
            println!("{}", json!({ "error": msg, "code": code }));
        } else {
            println!("❌ {msg}");
        }
    }

    /// 開第一個有醒著裝置的 transport。回傳 (transport, index, HID++ 版本)。
    /// 探測順序與 macOS discover() 相同：接收器 1–6，全空補問 0xFF；直連只問 0xFF。
    fn open_first(json_mode: bool) -> Result<(WinTransport, u8, (u8, u8)), i32> {
        let trs = match open_all() {
            Ok(t) => t,
            Err(e) => {
                emit_error(&e.to_string(), "transport", json_mode);
                return Err(2);
            }
        };
        for mut tr in trs {
            if let Some((idx, ver)) = first_awake(&mut tr) {
                return Ok((tr, idx, ver));
            }
        }
        emit_error(
            "transport present but no awake device — move the mouse and retry",
            "no-awake-device",
            json_mode,
        );
        Err(1)
    }

    fn first_awake(tr: &mut WinTransport) -> Option<(u8, (u8, u8))> {
        let swid = software_id();
        if tr.is_direct() {
            return Device::new(&mut *tr, 0xFF, swid)
                .ping()
                .ok()
                .map(|v| (0xFF, v));
        }
        for idx in 1..=6u8 {
            if let Ok(v) = Device::new(&mut *tr, idx, swid).ping() {
                return Some((idx, v));
            }
        }
        // USB 上的 0xFF00 不一定是接收器——有線滑鼠也在這頁，但只回應 0xFF
        Device::new(&mut *tr, 0xFF, swid)
            .ping()
            .ok()
            .map(|v| (0xFF, v))
    }

    fn cmd_status(json_mode: bool) -> i32 {
        let t0 = std::time::Instant::now();
        let (mut tr, idx, ver) = match open_first(json_mode) {
            Ok(x) => x,
            Err(c) => return c,
        };
        let page = tr.usage_page;
        let product = tr.product_id();
        let direct = tr.is_direct();
        let mut dev = Device::new(&mut tr, idx, software_id());
        let name = dev.name().unwrap_or_else(|_| "unknown".into());
        let battery = dev.battery().ok();
        let dpi = dev.current_dpi().ok();
        let rate = dev.report_rate_hz().ok();
        let feats = json!({
            "onboardProfiles": dev.has(0x8100),
            "rgb": dev.has(0x8071) || dev.has(0x8070),
            "remapSpy": dev.has(0x8110),
            "remapDivert": dev.has(0x1b04),
        });
        if json_mode {
            println!(
                "{}",
                json!({
                    "version": WIN_VERSION,
                    "device": name,
                    "deviceIndex": idx,
                    "receiverPID": format!("0x{product:04X}"),
                    "hidppVersion": format!("{}.{}", ver.0, ver.1),
                    "battery": battery.as_ref().map(|b| json!({
                        "percent": b.percent, "millivolts": b.millivolts,
                        "charging": b.charging, "source": b.source })),
                    "dpi": dpi,
                    "reportRateHz": rate,
                    "features": feats,
                    "queryMs": t0.elapsed().as_millis() as u64,
                })
            );
            return 0;
        }
        println!("Nibble {WIN_VERSION} ── {name}");
        let link = if direct {
            format!("direct 046D:{product:04X} (usage page 0x{page:04X})")
        } else if idx == 0xFF {
            format!("wired-usb 046D:{product:04X}")
        } else {
            format!("receiver 046D:{product:04X} · device #{idx}")
        };
        println!(" link      HID++ {}.{} · {link}", ver.0, ver.1);
        match &battery {
            Some(b) => {
                let volt = b
                    .millivolts
                    .map(|m| format!("{:.2}V  ", f64::from(m) / 1000.0))
                    .unwrap_or_default();
                println!(
                    " battery   {}%  {}{}",
                    b.percent,
                    volt,
                    if b.charging {
                        "charging ⚡"
                    } else {
                        "discharging"
                    }
                );
            }
            None => println!(" battery   —"),
        }
        println!(
            " dpi       {}",
            dpi.map(|d| d.to_string()).unwrap_or_else(|| "—".into())
        );
        println!(
            " rate      {}",
            rate.map(|r| format!("{r} Hz"))
                .unwrap_or_else(|| "—".into())
        );
        0
    }

    fn cmd_battery(json_mode: bool) -> i32 {
        let (mut tr, idx, _) = match open_first(json_mode) {
            Ok(x) => x,
            Err(c) => return c,
        };
        let mut dev = Device::new(&mut tr, idx, software_id());
        match dev.battery() {
            Ok(b) => {
                if json_mode {
                    println!(
                        "{}",
                        json!({ "percent": b.percent, "millivolts": b.millivolts,
                                "charging": b.charging, "source": b.source,
                                "device": dev.name().unwrap_or_else(|_| "unknown".into()) })
                    );
                } else {
                    let volt = b
                        .millivolts
                        .map(|m| format!(" {:.2}V", f64::from(m) / 1000.0))
                        .unwrap_or_default();
                    println!(
                        "{}%{} {}",
                        b.percent,
                        volt,
                        if b.charging {
                            "charging"
                        } else {
                            "discharging"
                        }
                    );
                }
                0
            }
            Err(e) => {
                emit_error(&e.to_string(), "transport", json_mode);
                2
            }
        }
    }

    fn cmd_dpi(sub: &[String], json_mode: bool) -> i32 {
        let target: Option<u16> = match sub.first() {
            Some(s) => match s.parse::<u32>() {
                Ok(v) if (50..=25600).contains(&v) => Some(v as u16),
                _ => {
                    println!("usage: nibble dpi [50-25600]");
                    return 64;
                }
            },
            None => None,
        };
        let (mut tr, idx, _) = match open_first(json_mode) {
            Ok(x) => x,
            Err(c) => return c,
        };
        let mut dev = Device::new(&mut tr, idx, software_id());
        match target {
            None => match dev.current_dpi() {
                Ok(d) => {
                    if json_mode {
                        println!("{}", json!({ "dpi": d }));
                    } else {
                        println!("dpi {d}");
                    }
                    0
                }
                Err(e) => {
                    emit_error(&e.to_string(), "transport", json_mode);
                    2
                }
            },
            Some(want) => match dev.set_dpi(want) {
                Ok(got) => {
                    if json_mode {
                        println!(
                            "{}",
                            json!({ "dpi": got, "requested": want, "applied": got == want })
                        );
                    } else if got == want {
                        println!("dpi {got} ✓  (read back from device)");
                    } else {
                        println!("⚠️ asked {want}, device reports {got}");
                    }
                    if got == want {
                        0
                    } else {
                        1
                    }
                }
                Err(e) => {
                    emit_error(&e.to_string(), "transport", json_mode);
                    2
                }
            },
        }
    }

    fn cmd_rate(sub: &[String], json_mode: bool) -> i32 {
        let target: Option<u16> = match sub.first() {
            Some(s) => match s.parse::<u16>() {
                Ok(v) if [125, 250, 500, 1000].contains(&v) => Some(v),
                _ => {
                    println!("usage: nibble rate [125|250|500|1000]");
                    return 64;
                }
            },
            None => None,
        };
        let (mut tr, idx, _) = match open_first(json_mode) {
            Ok(x) => x,
            Err(c) => return c,
        };
        let mut dev = Device::new(&mut tr, idx, software_id());
        match target {
            None => {
                let cur = dev.report_rate_hz().ok();
                let supported = dev.supported_report_rates_hz().unwrap_or_default();
                if json_mode {
                    println!("{}", json!({ "reportRateHz": cur, "supported": supported }));
                } else {
                    let s = supported
                        .iter()
                        .map(u16::to_string)
                        .collect::<Vec<_>>()
                        .join("/");
                    println!(
                        "rate {} Hz (supported: {s} Hz)",
                        cur.map(|c| c.to_string()).unwrap_or_else(|| "—".into())
                    );
                }
                0
            }
            Some(hz) => {
                // 回報率寫入需要 host 模式——fallback 舞步由共同向量釘住
                match with_host_fallback(&mut dev, |d| d.set_report_rate_hz(hz)) {
                    Ok(got) => {
                        if json_mode {
                            println!(
                                "{}",
                                json!({ "reportRateHz": got, "requested": hz, "applied": got == hz })
                            );
                        } else if got == hz {
                            println!("rate {got} Hz ✓");
                        } else {
                            println!("⚠️ asked {hz}, device reports {got}");
                        }
                        if got == hz {
                            0
                        } else {
                            1
                        }
                    }
                    Err(e) => {
                        emit_error(&e.to_string(), "transport", json_mode);
                        2
                    }
                }
            }
        }
    }

    fn cmd_rgb(sub: &[String], json_mode: bool) -> i32 {
        let kind = sub.first().map(String::as_str).unwrap_or("");
        if !["off", "cycle", "breathing", "show"].contains(&kind) {
            println!("usage: nibble rgb off|cycle|breathing|show");
            return 64;
        }
        let (mut tr, idx, _) = match open_first(json_mode) {
            Ok(x) => x,
            Err(c) => return c,
        };
        let mut dev = Device::new(&mut tr, idx, software_id());
        if kind == "show" {
            let zones = dev.rgb_zone_count().unwrap_or(0);
            let mut out = Vec::new();
            for z in 0..zones {
                let effects: Vec<String> = dev
                    .rgb_zone_effects(z)
                    .iter()
                    .map(|(slot, id)| format!("slot {slot}: 0x{id:04X}"))
                    .collect();
                out.push((z, effects));
            }
            if json_mode {
                println!(
                    "{}",
                    json!({ "zones": out.iter().map(|(z, e)| json!({"zone": z, "effects": e})).collect::<Vec<_>>() })
                );
            } else {
                for (z, effects) in out {
                    println!("zone {z}: {}", effects.join(" · "));
                }
            }
            return 0;
        }
        match apply_rgb(&mut dev, kind) {
            Ok(applied) if applied > 0 => {
                if json_mode {
                    println!("{}", json!({ "rgb": kind, "zonesApplied": applied }));
                } else {
                    println!("rgb {kind} ✓ ({applied} zones)");
                }
                0
            }
            Ok(_) => {
                emit_error(
                    "effect not available on this device",
                    "unsupported",
                    json_mode,
                );
                1
            }
            Err(e) => {
                emit_error(&e.to_string(), "transport", json_mode);
                2
            }
        }
    }

    fn cmd_mode(sub: &[String], json_mode: bool) -> i32 {
        let (mut tr, idx, _) = match open_first(json_mode) {
            Ok(x) => x,
            Err(c) => return c,
        };
        let mut dev = Device::new(&mut tr, idx, software_id());
        match sub.first().map(String::as_str) {
            None => match dev.onboard_mode() {
                Ok(m) => {
                    let text = if m == 1 {
                        "onboard (device profile in charge)"
                    } else {
                        "host (software runtime in charge)"
                    };
                    if json_mode {
                        println!(
                            "{}",
                            json!({ "mode": if m == 1 { "onboard" } else { "host" } })
                        );
                    } else {
                        println!("mode {text}");
                    }
                    0
                }
                Err(e) => {
                    emit_error(&e.to_string(), "transport", json_mode);
                    2
                }
            },
            Some("host") | Some("onboard") => {
                let want = if sub[0] == "host" { 2u8 } else { 1u8 };
                match dev.set_onboard_mode(want) {
                    Ok(()) => {
                        if json_mode {
                            println!("{}", json!({ "mode": sub[0] }));
                        } else {
                            println!("mode {} ✓", sub[0]);
                        }
                        0
                    }
                    Err(e) => {
                        emit_error(&e.to_string(), "transport", json_mode);
                        2
                    }
                }
            }
            _ => {
                println!("usage: nibble mode [host|onboard]");
                64
            }
        }
    }

    fn cmd_config(sub: &[String], json_mode: bool) -> i32 {
        let path = config_path();
        match sub.first().map(String::as_str).unwrap_or("show") {
            "show" => {
                match std::fs::read_to_string(&path) {
                    Ok(s) => print!("{s}"),
                    Err(_) => println!(
                        "not created — run: nibble config init  (path: {})",
                        path.display()
                    ),
                }
                0
            }
            "init" => {
                let (mut tr, idx, _) = match open_first(json_mode) {
                    Ok(x) => x,
                    Err(c) => return c,
                };
                let mut dev = Device::new(&mut tr, idx, software_id());
                let mut cfg = match config::load_config_for_write(&path) {
                    Ok(c) => c,
                    Err(e) => {
                        emit_error(&e.to_string(), "config-unreadable", json_mode);
                        return 1;
                    }
                };
                // 讀不到就保留既有值——絕不用失敗覆蓋掉存好的設定（macOS v1.7.1 的規則）
                if let Ok(d) = dev.current_dpi() {
                    cfg.dpi = Some(i64::from(d));
                }
                if let Ok(r) = dev.report_rate_hz() {
                    cfg.report_rate_hz = Some(i64::from(r));
                }
                if cfg.rgb.is_none() {
                    cfg.rgb = Some("keep".into());
                }
                match config::save_config(&path, &cfg) {
                    Ok(()) => {
                        println!("✅ updated {} from current device state", path.display());
                        0
                    }
                    Err(e) => {
                        emit_error(&e.to_string(), "config-write", json_mode);
                        2
                    }
                }
            }
            _ => {
                println!("usage: nibble config init|show");
                64
            }
        }
    }

    fn cmd_apply(json_mode: bool) -> i32 {
        let path = config_path();
        let Some(cfg) = config::load_config(&path) else {
            emit_error(
                &format!(
                    "no readable config at {} — run: nibble config init",
                    path.display()
                ),
                "no-config",
                json_mode,
            );
            return 1;
        };
        let (mut tr, idx, _) = match open_first(json_mode) {
            Ok(x) => x,
            Err(c) => return c,
        };
        let mut dev = Device::new(&mut tr, idx, software_id());
        let mut failures = 0;
        if let Some(want) = cfg.dpi {
            match dev.set_dpi(want as u16) {
                Ok(got) if i64::from(got) == want => println!(" dpi {got} ✓"),
                _ => {
                    println!(" dpi {want} ✗");
                    failures += 1;
                }
            }
        }
        if let Some(want) = cfg.report_rate_hz {
            match with_host_fallback(&mut dev, |d| d.set_report_rate_hz(want as u16)) {
                Ok(got) if i64::from(got) == want => println!(" rate {got} Hz ✓"),
                _ => {
                    println!(" rate {want} Hz ✗");
                    failures += 1;
                }
            }
        }
        if let Some(kind) = cfg.rgb.as_deref() {
            if kind != "keep" {
                match apply_rgb(&mut dev, kind) {
                    Ok(n) if n > 0 => println!(" rgb {kind} ✓ ({n} zones)"),
                    _ => {
                        println!(" rgb {kind} ✗");
                        failures += 1;
                    }
                }
            }
        }
        println!(
            "{}",
            if failures == 0 {
                "apply complete ✓"
            } else {
                "apply complete, some settings did not take effect"
            }
        );
        if failures == 0 {
            0
        } else {
            1
        }
    }

    fn cmd_doctor(json_mode: bool) -> i32 {
        let mut checks: Vec<serde_json::Value> = Vec::new();
        let mut first_fix: Option<String> = None;
        let add = |checks: &mut Vec<serde_json::Value>,
                   first_fix: &mut Option<String>,
                   name: &str,
                   ok: Option<bool>,
                   detail: String,
                   fix: Option<&str>| {
            checks.push(json!({
                "check": name,
                "status": match ok { Some(true) => "ok", Some(false) => "fail", None => "warn" },
                "detail": detail,
                "fix": fix,
            }));
            if ok == Some(false) && first_fix.is_none() {
                *first_fix = fix.map(str::to_string);
            }
        };

        // 傳輸層：列舉 + 開啟
        let mut awake: Option<(String, String)> = None;
        match open_all() {
            Ok(mut trs) => {
                let desc = trs
                    .iter()
                    .map(|t| {
                        format!(
                            "{} 046D:{:04X}",
                            if t.is_direct() { "direct" } else { "receiver" },
                            t.product_id()
                        )
                    })
                    .collect::<Vec<_>>()
                    .join(" · ");
                add(
                    &mut checks,
                    &mut first_fix,
                    "transports",
                    Some(true),
                    desc,
                    None,
                );
                for tr in trs.iter_mut() {
                    if let Some((idx, ver)) = first_awake(tr) {
                        let mut dev = Device::new(&mut *tr, idx, software_id());
                        let name = dev.name().unwrap_or_else(|_| "unknown".into());
                        awake = Some((
                            name.clone(),
                            format!("HID++ {}.{} · index {idx}", ver.0, ver.1),
                        ));
                        if let Ok(b) = dev.battery() {
                            add(
                                &mut checks,
                                &mut first_fix,
                                "battery",
                                Some(b.percent > 10 || b.charging),
                                format!(
                                    "{}% {} ({})",
                                    b.percent,
                                    if b.charging {
                                        "charging"
                                    } else {
                                        "discharging"
                                    },
                                    b.source
                                ),
                                (b.percent <= 10 && !b.charging).then_some("Charge the mouse"),
                            );
                        }
                        break;
                    }
                }
                match &awake {
                    Some((name, link)) => add(
                        &mut checks,
                        &mut first_fix,
                        "device",
                        Some(true),
                        format!("{name} · {link}"),
                        None,
                    ),
                    None => add(
                        &mut checks,
                        &mut first_fix,
                        "device",
                        Some(false),
                        "transport present but no awake device".into(),
                        Some("Move the mouse to wake it, then rerun"),
                    ),
                }
            }
            Err(e) => {
                add(
                    &mut checks,
                    &mut first_fix,
                    "transports",
                    Some(false),
                    e.to_string(),
                    Some("Plug in the USB receiver or connect the mouse over Bluetooth"),
                );
            }
        }

        // 設定檔：三態（解析成功／存在但解不開／未建立）——與 macOS doctor 相同的誠實
        let path = config_path();
        let exists = path.exists();
        match config::load_config(&path) {
            Some(_) => add(
                &mut checks,
                &mut first_fix,
                "config",
                Some(true),
                path.display().to_string(),
                None,
            ),
            None if exists => add(
                &mut checks,
                &mut first_fix,
                "config",
                Some(false),
                format!(
                    "{} exists but could not be parsed — Nibble refuses to overwrite it",
                    path.display()
                ),
                Some("fix the JSON by hand (or move it aside), then rerun"),
            ),
            None => add(
                &mut checks,
                &mut first_fix,
                "config",
                None,
                "not created".into(),
                Some("nibble config init"),
            ),
        }

        // 托盤：named mutex 探測（macOS flock 的對應物）
        let tray = tray_lock::tray_running();
        add(
            &mut checks,
            &mut first_fix,
            "tray",
            None,
            if tray {
                "running".into()
            } else {
                "not running".into()
            },
            (!tray).then_some("start nibble-tray.exe for battery in the notification area"),
        );

        // G HUB 同時在跑：HID 是共享開啟，通常能共存，但值得知道
        if let Ok(out) = std::process::Command::new("tasklist")
            .args(["/FI", "IMAGENAME eq lghub.exe", "/NH"])
            .output()
        {
            let running = String::from_utf8_lossy(&out.stdout)
                .to_lowercase()
                .contains("lghub");
            if running {
                add(
                    &mut checks,
                    &mut first_fix,
                    "ghub",
                    None,
                    "G HUB is running — access is shared, but two writers can fight over settings"
                        .into(),
                    None,
                );
            }
        }

        let failed = checks.iter().filter(|c| c["status"] == "fail").count();
        if json_mode {
            println!(
                "{}",
                json!({ "ok": failed == 0, "failed": failed, "checks": checks,
                        "nextStep": first_fix, "version": WIN_VERSION })
            );
        } else {
            println!("Nibble doctor {WIN_VERSION} (windows)\n");
            for c in &checks {
                let icon = match c["status"].as_str() {
                    Some("ok") => "✅",
                    Some("fail") => "❌",
                    _ => "•",
                };
                println!(
                    " {icon} {:18}{}",
                    c["check"].as_str().unwrap_or("?"),
                    c["detail"].as_str().unwrap_or("")
                );
                if let Some(fix) = c["fix"].as_str() {
                    println!("      → {fix}");
                }
            }
            println!(
                "\n {}",
                if failed == 0 {
                    "All good.".into()
                } else {
                    format!("{failed} issue(s) — fix the first arrow above and rerun.")
                }
            );
        }
        if failed == 0 {
            0
        } else {
            1
        }
    }
}
