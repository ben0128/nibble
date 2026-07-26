// fixtures.rs — docs/fixtures/*.json 的 Rust 側重播器，與 Tests/FixtureTests.swift 對稱。
// 兩邊用同一組向量、同一種嚴格度：連送出的 request bytes 都逐一比對，
// 並要求每一則劇本 exchange 都被消耗（多送或少送都算失敗）。
use nibble_core::config::{self, ConfigError};
use nibble_core::hidpp::{Device, Error, Transport};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

fn fixtures_dir() -> PathBuf {
    // CARGO_MANIFEST_DIR = windows/crates/nibble-core → 上三層是 repo 根
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../docs/fixtures")
}

fn load_cases(file: &str) -> Vec<Value> {
    let path = fixtures_dir().join(file);
    let data = fs::read(&path).unwrap_or_else(|e| {
        panic!(
            "cannot load fixture {} — the shared vectors are part of the suite: {e}",
            path.display()
        )
    });
    let root: Value = serde_json::from_slice(&data).expect("fixture parses");
    root["cases"].as_array().expect("fixture has cases").clone()
}

fn bytes(v: &Value) -> Vec<u8> {
    v.as_array()
        .map(|a| a.iter().map(|n| n.as_u64().expect("byte") as u8).collect())
        .unwrap_or_default()
}

/// 照劇本走的 transport：消耗一則 exchange、比對 request 與 prefer_long，
/// 回應在且 matcher 認得才回傳——認不得（別人的 swid）就跟真實世界一樣等到超時。
struct Scripted {
    name: String,
    exchanges: Vec<Value>,
    consumed: usize,
}

impl Scripted {
    fn fully_consumed(&self) -> bool {
        self.consumed == self.exchanges.len()
    }
}

impl Transport for Scripted {
    fn round_trip(
        &mut self,
        request: &[u8],
        prefer_long: bool,
        _timeout: Duration,
        matcher: &dyn Fn(&[u8]) -> bool,
    ) -> Result<Vec<u8>, Error> {
        assert!(
            self.consumed < self.exchanges.len(),
            "{}: unexpected extra request {request:?}",
            self.name
        );
        let ex = self.exchanges[self.consumed].clone();
        self.consumed += 1;
        assert_eq!(
            request,
            bytes(&ex["request"]).as_slice(),
            "{}: request bytes",
            self.name
        );
        assert_eq!(
            prefer_long,
            ex["prefer_long"].as_bool().unwrap_or(false),
            "{}: prefer_long",
            self.name
        );
        if ex["response"].is_null() {
            return Err(Error::Timeout);
        }
        let r = bytes(&ex["response"]);
        if matcher(&r) {
            Ok(r)
        } else {
            Err(Error::Timeout)
        }
    }
}

fn run_protocol(file: &str) {
    for c in load_cases(file) {
        let name = c["name"].as_str().unwrap_or("?").to_string();
        let tr = Scripted {
            name: name.clone(),
            exchanges: c["exchanges"].as_array().cloned().unwrap_or_default(),
            consumed: 0,
        };
        let mut dev = Device::new(
            tr,
            c["device"].as_u64().expect("device") as u8,
            c["swid"].as_u64().expect("swid") as u8,
        );
        let op = &c["op"];
        let expect = &c["expect"];

        let outcome: Result<(), Error> = match op["kind"].as_str().expect("op kind") {
            "ping" => dev.ping().map(|(major, minor)| {
                if let Some(w) = expect.get("ping") {
                    assert_eq!(
                        u64::from(major),
                        w["major"].as_u64().unwrap(),
                        "{name}: major"
                    );
                    assert_eq!(
                        u64::from(minor),
                        w["minor"].as_u64().unwrap(),
                        "{name}: minor"
                    );
                }
            }),
            "battery" => dev.battery().map(|b| {
                if let Some(w) = expect.get("battery") {
                    assert_eq!(b.source, w["source"].as_str().unwrap(), "{name}: source");
                    assert_eq!(
                        u64::from(b.percent),
                        w["percent"].as_u64().unwrap(),
                        "{name}: percent"
                    );
                    assert_eq!(
                        b.charging,
                        w["charging"].as_bool().unwrap(),
                        "{name}: charging"
                    );
                    let want_mv = w["millivolts"].as_u64().map(|m| m as u16); // JSON null → None
                    assert_eq!(b.millivolts, want_mv, "{name}: millivolts");
                }
            }),
            "dpi_get" => dev.current_dpi().map(|d| {
                assert_eq!(u64::from(d), expect["dpi"].as_u64().unwrap(), "{name}: dpi");
            }),
            "raw_call" => dev
                .call_index(
                    op["feature_index"].as_u64().unwrap() as u8,
                    op["function"].as_u64().unwrap() as u8,
                    &bytes(&op["params"]),
                )
                .map(|_| ()),
            "feature_index_twice" => {
                let feature = op["feature"].as_u64().unwrap() as u16;
                dev.feature_index(feature)
                    .and_then(|_| dev.feature_index(feature))
                    .map(|_| ())
            }
            k => panic!("{name}: unknown op kind {k}"),
        };

        match expect.get("error").and_then(Value::as_str) {
            Some(want) => {
                let got = match outcome {
                    Err(e) => e,
                    Ok(()) => panic!("{name}: wanted error {want}, got success"),
                };
                let matched = matches!(
                    (want, &got),
                    ("timeout", Error::Timeout)
                        | ("deviceOffline", Error::DeviceOffline(_))
                        | ("protocolError", Error::ProtocolError(_))
                );
                assert!(matched, "{name}: wanted {want}, got {got:?}");
            }
            None => outcome.unwrap_or_else(|e| panic!("{name}: threw unexpectedly: {e:?}")),
        }
        assert!(
            dev.transport().fully_consumed(),
            "{name}: every scripted exchange was consumed"
        );
    }
}

#[test]
fn framing_vectors() {
    run_protocol("hidpp-framing.json");
}

#[test]
fn battery_vectors() {
    run_protocol("hidpp-battery.json");
}

#[test]
fn dpi_vectors() {
    run_protocol("hidpp-dpi.json");
}

#[test]
fn config_semantics_vectors() {
    for (i, c) in load_cases("config-merge.json").into_iter().enumerate() {
        let name = c["name"].as_str().unwrap_or("?").to_string();
        let tmp =
            std::env::temp_dir().join(format!("nibble-fixture-rs-{}-{i}.json", std::process::id()));
        let _ = fs::remove_file(&tmp);

        if let Some(raw) = c["existing_raw"].as_str() {
            fs::write(&tmp, raw).unwrap();
        } else if c["existing"].is_object() {
            fs::write(&tmp, serde_json::to_vec_pretty(&c["existing"]).unwrap()).unwrap();
        }
        let before = fs::read(&tmp).ok();

        let op = &c["op"];
        let outcome: Result<(), ConfigError> = match op["kind"].as_str().expect("op kind") {
            "update_low_battery_notify" => config::update_low_battery_notify(
                &tmp,
                op["enabled"].as_bool().unwrap(),
                op["percent"].as_i64().unwrap(),
            ),
            "switch_profile" => config::switch_profile(&tmp, op["to"].as_str().unwrap()),
            k => panic!("{name}: unknown op kind {k}"),
        };

        let expect = &c["expect"];
        match expect.get("error").and_then(Value::as_str) {
            Some(want) => {
                let got = match outcome {
                    Err(e) => e,
                    Ok(()) => panic!("{name}: wanted error {want}, got success"),
                };
                let matched = matches!(
                    (want, &got),
                    ("unreadable", ConfigError::Unreadable { .. })
                        | ("notFound", ConfigError::ProfileNotFound(_))
                );
                assert!(matched, "{name}: wanted {want}, got {got:?}");
            }
            None => outcome.unwrap_or_else(|e| panic!("{name}: threw unexpectedly: {e}")),
        }

        if expect["file_unchanged"].as_bool() == Some(true) {
            assert_eq!(fs::read(&tmp).ok(), before, "{name}: file untouched");
        }
        let after: Option<Value> = fs::read(&tmp)
            .ok()
            .and_then(|d| serde_json::from_slice(&d).ok());
        if let Some(preserved) = expect["keys_preserved"].as_array() {
            let obj = after
                .as_ref()
                .and_then(Value::as_object)
                .expect("config parses after write");
            for key in preserved {
                assert!(
                    obj.contains_key(key.as_str().unwrap()),
                    "{name}: key {key} preserved"
                );
            }
        }
        if let Some(values) = expect["values"].as_object() {
            let obj = after
                .as_ref()
                .and_then(Value::as_object)
                .expect("config parses after write");
            for (key, want) in values {
                assert_eq!(obj.get(key), Some(want), "{name}: {key}");
            }
        }
        if expect.get("threshold_resolves").map(Value::is_null) == Some(true) {
            let cfg = config::load_config(&tmp);
            assert!(
                config::low_battery_threshold(cfg.as_ref()).is_none(),
                "{name}: threshold resolves to off"
            );
        }
        let _ = fs::remove_file(&tmp);
    }
}
