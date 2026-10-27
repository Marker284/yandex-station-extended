// Виртуальные Bluetooth-устройства из MPRIS-плееров.
//
// Каждый org.mpris.MediaPlayer2.<имя> на шине плееров виден maind как подключённый
// Bluetooth-источник: Device1 + MediaControl1, player0 (MediaPlayer1) и fd0 (MediaTransport1).
// Форма объектов и последовательность сигналов сняты с настоящего подключения: Device1 и
// MediaControl1 без Player, транспорт, player0 и только потом PropertiesChanged MediaControl1
// {Player, Connected} — по этому сигналу maind пишет «Bt source connected». Перед playing
// транспорт проходит idle -> pending -> active. Устройство появляется при первом Playing, после Stopped живёт ещё
// STOPPED_GRACE (как телефон, у которого кончился трек) и сразу исчезает при уходе плеера с шины. Алиса управляет им как Bluetooth-плеером:
// фокус, «дальше / назад / пауза / продолжи», громкость (Volume транспорта <-> MPRIS Volume).
use std::collections::HashMap;

use zbus::zvariant::{ObjectPath, OwnedValue, Value};

pub const ADAPTER: &str = "/org/bluez/hci0";
pub const MPRIS_PREFIX: &str = "org.mpris.MediaPlayer2.";
pub const MPRIS_PATH: &str = "/org/mpris/MediaPlayer2";
pub const MPRIS_PLAYER: &str = "org.mpris.MediaPlayer2.Player";

pub const STOPPED_GRACE: std::time::Duration = std::time::Duration::from_secs(60);

pub type Props = HashMap<String, OwnedValue>;
pub type Ifaces = HashMap<String, Props>;

fn ov<'a>(v: impl Into<Value<'a>>) -> OwnedValue {
    v.into().try_to_owned().expect("значение без fd")
}

fn opath(p: &str) -> OwnedValue {
    ov(ObjectPath::try_from(p.to_string()).expect("корректный путь"))
}

pub struct Dev {
    pub mpris: String, // well-known имя плеера
    pub path: String,
    pub objects: Vec<(String, Ifaces)>, // устройство, fd0, player0 — в порядке появления
    pub stopped_since: Option<std::time::Instant>,
}

impl Dev {
    pub fn new(mpris: &str, identity: &str) -> Dev {
        // локально администрируемый MAC из имени плеера: стабилен между запусками
        let h = mpris.bytes().fold(0x811c9dc5u32, |h, b| (h ^ b as u32).wrapping_mul(0x01000193));
        let mac = [0x02, 0xA1, (h >> 24) as u8, (h >> 16) as u8, (h >> 8) as u8, h as u8];
        let addr = mac.map(|b| format!("{b:02X}")).join(":");
        let path = format!("{ADAPTER}/dev_{}", addr.replace(':', "_"));
        let (player, fd) = (format!("{path}/player0"), format!("{path}/fd0"));
        let uuids: Vec<String> = ["0000110a", "0000110c", "0000110e"]
            .iter()
            .map(|u| format!("{u}-0000-1000-8000-00805f9b34fb"))
            .collect();
        let device: Props = [
            ("Address", ov(addr.as_str())),
            ("AddressType", ov("public")),
            ("Name", ov(identity)),
            ("Alias", ov(identity)),
            ("Class", ov(7995916u32)), // как у телефона: Alice показывает источник «телефон»
            ("Icon", ov("phone")),
            ("Paired", ov(true)),
            ("Bonded", ov(true)),
            ("Trusted", ov(true)),
            ("Blocked", ov(false)),
            ("LegacyPairing", ov(false)),
            ("Connected", ov(true)),
            ("UUIDs", ov(uuids)),
            ("Adapter", opath(ADAPTER)),
            ("ServicesResolved", ov(true)),
            ("CurrentRSSI", ov(-40i16)),
            ("AFH", ov("")),
            ("LQ", ov(255i16)),
            ("TPL", ov(7i16)),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        let control: Props = [("Connected", ov(true))]
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect();
        let mplayer: Props = [
            ("Name", ov(identity)),
            ("Type", ov("Audio")),
            ("Subtype", ov("None")),
            ("Position", ov(0u32)),
            ("Status", ov("paused")),
            ("Repeat", ov("off")),
            ("Shuffle", ov("off")),
            ("Track", ov(HashMap::<String, Value>::new())),
            ("Device", opath(&path)),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        let transport: Props = [
            ("Device", opath(&path)),
            ("UUID", ov("0000110B-0000-1000-8000-00805F9B34FB")),
            ("Codec", ov(0u8)),
            ("Configuration", ov(vec![0x21u8, 0x15, 0x02, 0x35])),
            ("State", ov("idle")),
            ("Volume", ov(127u16)),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        let objects = vec![
            (
                path.clone(),
                Ifaces::from([
                    ("org.bluez.Device1".to_string(), device),
                    ("org.bluez.MediaControl1".to_string(), control),
                ]),
            ),
            (fd, Ifaces::from([("org.bluez.MediaTransport1".to_string(), transport)])),
            (player, Ifaces::from([("org.bluez.MediaPlayer1".to_string(), mplayer)])),
        ];
        Dev { mpris: mpris.to_string(), path, objects, stopped_since: None }
    }

    pub fn owns(&self, path: &str) -> bool {
        path == self.path || path.starts_with(&format!("{}/", self.path))
    }

    pub fn props(&self, path: &str, iface: &str) -> Option<&Props> {
        self.objects.iter().find(|(p, _)| p == path)?.1.get(iface)
    }

    // Обновить свойство; Some(путь, интерфейс) — если значение изменилось и нужен PropertiesChanged.
    pub fn set(&mut self, iface: &str, name: &str, v: OwnedValue) -> Option<String> {
        let (path, props) = self.objects.iter_mut().find_map(|(p, i)| i.get_mut(iface).map(|pr| (p, pr)))?;
        if props.get(name).is_some_and(|old| *old == v) {
            return None;
        }
        props.insert(name.to_string(), v);
        Some(path.clone())
    }
}

// Status/State для BlueZ из MPRIS PlaybackStatus.
pub fn status(playback: &str) -> (&'static str, &'static str) {
    match playback {
        "Playing" => ("playing", "active"),
        "Paused" => ("paused", "idle"),
        _ => ("stopped", "idle"),
    }
}

// Track BlueZ из Metadata MPRIS.
pub fn track(meta: &HashMap<String, OwnedValue>) -> OwnedValue {
    let s = |k: &str| meta.get(k).and_then(|v| String::try_from(v.clone()).ok());
    let mut t: HashMap<String, Value> = HashMap::new();
    if let Some(v) = s("xesam:title") {
        t.insert("Title".into(), v.into());
    }
    let artist = meta
        .get("xesam:artist")
        .and_then(|v| Vec::<String>::try_from(v.clone()).ok())
        .map(|a| a.join(", "))
        .or_else(|| s("xesam:artist"));
    if let Some(v) = artist {
        t.insert("Artist".into(), v.into());
    }
    if let Some(v) = s("xesam:album") {
        t.insert("Album".into(), v.into());
    }
    let us = meta.get("mpris:length").and_then(|v| {
        i64::try_from(v.clone()).ok().or_else(|| u64::try_from(v.clone()).ok().map(|u| u as i64))
    });
    if let Some(us) = us.filter(|&u| u > 0) {
        t.insert("Duration".into(), Value::from((us / 1000) as u32));
    }
    ov(t)
}

// MPRIS Volume 0..1 <-> BlueZ Volume 0..127
pub fn to_bt_volume(v: f64) -> u16 {
    (v.clamp(0.0, 1.0) * 127.0).round() as u16
}
pub fn to_mpris_volume(v: u16) -> f64 {
    f64::from(v.min(127)) / 127.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_shape() {
        let d = Dev::new("org.mpris.MediaPlayer2.ShairportSync", "AirPlay");
        assert!(d.path.starts_with("/org/bluez/hci0/dev_02_A1_"));
        assert_eq!(d.objects.len(), 3);
        // транспорт раньше плеера — иначе maind не признаёт источник подключённым
        assert!(d.objects[1].0.ends_with("/fd0") && d.objects[2].0.ends_with("/player0"));
        assert!(d.owns(&format!("{}/fd0", d.path)) && !d.owns("/org/bluez/hci0"));
        assert!(d.props(&format!("{}/player0", d.path), "org.bluez.MediaPlayer1").is_some());
        // стабильный MAC
        assert_eq!(d.path, Dev::new("org.mpris.MediaPlayer2.ShairportSync", "x").path);
    }

    #[test]
    fn mapping() {
        assert_eq!(status("Playing"), ("playing", "active"));
        assert_eq!(status("Stopped"), ("stopped", "idle"));
        for v in [0u16, 1, 64, 126, 127] {
            assert_eq!(to_bt_volume(to_mpris_volume(v)), v);
        }
        let mut d = Dev::new("org.mpris.MediaPlayer2.a", "a");
        assert!(d.set("org.bluez.MediaTransport1", "Volume", ov(127u16)).is_none());
        assert!(d.set("org.bluez.MediaTransport1", "Volume", ov(50u16)).is_some());
        let meta = HashMap::from([
            ("xesam:title".to_string(), ov("Песня")),
            ("xesam:artist".to_string(), ov(vec!["A".to_string(), "B".to_string()])),
            ("mpris:length".to_string(), ov(256_603_000i64)),
        ]);
        let t = HashMap::<String, OwnedValue>::try_from(track(&meta)).unwrap();
        assert_eq!(String::try_from(t["Artist"].clone()).unwrap(), "A, B");
        assert_eq!(u32::try_from(t["Duration"].clone()).unwrap(), 256_603);
    }
}
