// Связь виртуальных устройств (virt.rs) с MPRIS-плеерами и с maind.
//  - watch: следит за org.mpris.MediaPlayer2.* на шине плееров и шлёт maind InterfacesAdded/
//    InterfacesRemoved/PropertiesChanged от имени org.bluez;
//  - local: отвечает maind на вызовы к путям виртуальных устройств (свойства, MediaPlayer1).
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use futures_util::StreamExt;
use zbus::message::Type;
use zbus::zvariant::{ObjectPath, OwnedValue, Value};
use zbus::{Connection, Message, MessageStream};

use crate::virt::{self, Dev, Ifaces, Props, MPRIS_PATH, MPRIS_PLAYER, MPRIS_PREFIX};
use crate::State;

const PROPS: &str = "org.freedesktop.DBus.Properties";
const OM: &str = "org.freedesktop.DBus.ObjectManager";
const DBUS: &str = "org.freedesktop.DBus";

fn changed(path: &str, iface: &str, props: Props) -> zbus::Result<Message> {
    Message::signal(path, PROPS, "PropertiesChanged")?.build(&(iface, props, Vec::<String>::new()))
}

fn added(path: &str, ifaces: &Ifaces) -> zbus::Result<Message> {
    Message::signal("/", OM, "InterfacesAdded")?.build(&(ObjectPath::try_from(path)?, ifaces))
}

fn removed(path: &str, ifaces: &Ifaces) -> zbus::Result<Message> {
    let names: Vec<&String> = ifaces.keys().collect();
    Message::signal("/", OM, "InterfacesRemoved")?.build(&(ObjectPath::try_from(path)?, names))
}

fn remove(st: &mut State, pred: impl Fn(&Dev) -> bool) -> zbus::Result<Vec<Out>> {
    let mut out = Vec::new();
    while let Some(i) = st.devs.iter().position(&pred) {
        for (path, ifaces) in st.devs.remove(i).objects.iter().rev() {
            out.push(Out::Send(removed(path, ifaces)?));
        }
    }
    Ok(out)
}

// SIGTERM/SIGINT: убрать виртуальные устройства у maind и выйти — иначе он держит призраков.
pub fn on_exit(sys: Connection, st: Arc<Mutex<State>>) {
    use signal_hook::consts::{SIGINT, SIGTERM};
    let Ok(mut signals) = signal_hook::iterator::Signals::new([SIGTERM, SIGINT]) else { return };
    std::thread::spawn(move || {
        if signals.forever().next().is_some() {
            let out = remove(&mut st.lock().unwrap(), |_| true).unwrap_or_default();
            let _ = async_io::block_on(emit(&sys, out));
            std::process::exit(0);
        }
    });
}

// Убирать устройства, простоявшие в Stopped дольше STOPPED_GRACE.
pub async fn sweep(sys: Connection, st: Arc<Mutex<State>>) -> zbus::Result<()> {
    loop {
        async_io::Timer::after(std::time::Duration::from_secs(5)).await;
        let sigs = remove(&mut st.lock().unwrap(), |d| {
            d.stopped_since.is_some_and(|t| t.elapsed() >= virt::STOPPED_GRACE)
        })?;
        emit(&sys, sigs).await?;
    }
}

// Сигнал для maind или пауза перед следующим: maind подписывается на сигналы устройства только
// после обработки InterfacesAdded, и пачка в одну миллисекунду до него не доходит.
pub enum Out {
    Send(Message),
    Wait(u64),
    // арбитраж «последний заигравший побеждает»: AirPlay идёт мимо bluealsa-aplay -S,
    // который разводит только настоящие телефоны
    PauseMpris(String),
    PauseReal(String),
}

async fn emit(sys: &Connection, out: Vec<Out>) -> zbus::Result<()> {
    emit_all(sys, None, out).await
}

async fn emit_all(sys: &Connection, pause: Option<(&Connection, &Connection)>, out: Vec<Out>) -> zbus::Result<()> {
    for o in out {
        match (o, pause) {
            (Out::Send(m), _) => sys.send(&m).await?,
            (Out::Wait(ms), _) => {
                async_io::Timer::after(std::time::Duration::from_millis(ms)).await;
            }
            (Out::PauseMpris(name), Some((mp, _))) => pause_mpris(mp, &name).await,
            (Out::PauseReal(path), Some((_, prv))) => {
                eprintln!("bt-proxy: пауза {path}");
                let r = prv.call_method(Some("org.bluez"), path.as_str(), Some("org.bluez.MediaPlayer1"), "Pause", &());
                let _ = r.await;
            }
            _ => {}
        }
    }
    Ok(())
}

pub async fn pause_mpris(mp: &Connection, name: &str) {
    eprintln!("bt-proxy: пауза {name}");
    let _ = mp.call_method(Some(name), MPRIS_PATH, Some(MPRIS_PLAYER), "Pause", &()).await;
}

fn is_playing(d: &Dev) -> bool {
    d.props(&format!("{}/player0", d.path), "org.bluez.MediaPlayer1")
        .and_then(|p| p.get("Status"))
        .is_some_and(|v| String::try_from(v.clone()).is_ok_and(|s| s == "playing"))
}

// Виртуальные плееры, которые играют, — для паузы, когда заиграл настоящий телефон.
pub fn playing_virtual(st: &State) -> Vec<String> {
    st.devs.iter().filter(|d| is_playing(d)).map(|d| d.mpris.clone()).collect()
}

// Объекты виртуальных устройств для ответа GetManagedObjects.
pub fn managed_objects(st: &State) -> Vec<(String, Ifaces)> {
    st.devs.iter().flat_map(|d| d.objects.clone()).collect()
}

// Применить свойства MPRIS к устройству плеера; вернуть сигналы для maind.
fn apply(st: &mut State, name: &str, identity: &str, p: &HashMap<String, OwnedValue>) -> zbus::Result<Vec<Out>> {
    let mut out = Vec::new();
    let playback = p.get("PlaybackStatus").and_then(|v| String::try_from(v.clone()).ok());
    let exists = st.devs.iter().any(|d| d.mpris == name);
    if !exists && playback.as_deref() != Some("Playing") {
        return Ok(out);
    }
    if !exists {
        // как настоящее подключение: Device1 (Connected=false) -> Connected=true -> MediaControl1 ->
        // транспорт и player0 -> MediaControl1 {Player, Connected}; maind пишет «Bt source connected»
        let mut dev = Dev::new(name, identity);
        let yes = Value::from(true).try_to_owned()?;
        let (dpath, difaces) = dev.objects[0].clone();
        let mut d1 = difaces["org.bluez.Device1"].clone();
        d1.insert("Connected".into(), Value::from(false).try_to_owned()?);
        out.push(Out::Send(added(&dpath, &Ifaces::from([("org.bluez.Device1".to_string(), d1)]))?));
        out.push(Out::Wait(400));
        let conn = Props::from([("Connected".to_string(), yes.clone())]);
        out.push(Out::Send(changed(&dpath, "org.bluez.Device1", conn)?));
        out.push(Out::Wait(400));
        let mc = Ifaces::from([("org.bluez.MediaControl1".to_string(), difaces["org.bluez.MediaControl1"].clone())]);
        out.push(Out::Send(added(&dpath, &mc)?));
        out.push(Out::Wait(400));
        for (path, ifaces) in &dev.objects[1..] {
            out.push(Out::Send(added(path, ifaces)?));
        }
        out.push(Out::Wait(400));
        let player = Value::from(ObjectPath::try_from(format!("{}/player0", dev.path))?).try_to_owned()?;
        dev.set("org.bluez.MediaControl1", "Player", player.clone());
        let ctl = Props::from([("Player".to_string(), player), ("Connected".to_string(), yes)]);
        out.push(Out::Send(changed(&dev.path, "org.bluez.MediaControl1", ctl)?));
        out.push(Out::Wait(400));
        st.devs.push(dev);
    }
    if playback.as_deref() == Some("Playing") && !st.devs.iter().any(|d| d.mpris == name && is_playing(d)) {
        for other in st.devs.iter().filter(|d| d.mpris != name && is_playing(d)) {
            out.push(Out::PauseMpris(other.mpris.clone()));
        }
        for real in &st.real_playing {
            out.push(Out::PauseReal(real.clone()));
        }
    }
    let dev = st.devs.iter_mut().find(|d| d.mpris == name).expect("только что добавлено");
    if let Some(pb) = &playback {
        dev.stopped_since = (pb == "Stopped").then(std::time::Instant::now);
    }
    let mut set = |iface: &str, key: &str, v: OwnedValue, out: &mut Vec<Out>| -> zbus::Result<()> {
        if let Some(path) = dev.set(iface, key, v.clone()) {
            out.push(Out::Send(changed(&path, iface, Props::from([(key.to_string(), v)]))?));
        }
        Ok(())
    };
    if let Some(pb) = playback {
        let (status, state) = virt::status(&pb);
        if state == "active" {
            set("org.bluez.MediaTransport1", "State", Value::from("pending").try_to_owned()?, &mut out)?;
        }
        set("org.bluez.MediaTransport1", "State", Value::from(state).try_to_owned()?, &mut out)?;
        set("org.bluez.MediaPlayer1", "Status", Value::from(status).try_to_owned()?, &mut out)?;
    }
    if let Some(meta) = p.get("Metadata").and_then(|v| HashMap::<String, OwnedValue>::try_from(v.clone()).ok()) {
        set("org.bluez.MediaPlayer1", "Track", virt::track(&meta), &mut out)?;
    }
    if let Some(vol) = p.get("Volume").and_then(|v| f64::try_from(v.clone()).ok()) {
        let v = Value::from(virt::to_bt_volume(vol)).try_to_owned()?;
        set("org.bluez.MediaTransport1", "Volume", v, &mut out)?;
    }
    Ok(out)
}

// Имя «телефона» у Алисы: BT_PROXY_ALIASES="ShairportSync=AirPlay,spotifyd=Spotify" (по суффиксу
// имени MPRIS), иначе Identity плеера.
fn alias(name: &str) -> Option<String> {
    let suffix = name.trim_start_matches(MPRIS_PREFIX);
    std::env::var("BT_PROXY_ALIASES").ok()?.split(',').find_map(|kv| {
        let (k, v) = kv.split_once('=')?;
        (k.trim() == suffix || suffix.starts_with(&format!("{}.", k.trim()))).then(|| v.trim().to_string())
    })
}

async fn identity(mp: &Connection, name: &str) -> String {
    if let Some(a) = alias(name) {
        return a;
    }
    let r = mp
        .call_method(Some(name), MPRIS_PATH, Some(PROPS), "Get", &("org.mpris.MediaPlayer2", "Identity"))
        .await;
    r.ok()
        .and_then(|m| m.body().deserialize::<OwnedValue>().ok())
        .and_then(|v| String::try_from(v).ok())
        .unwrap_or_else(|| name.trim_start_matches(MPRIS_PREFIX).to_string())
}

async fn get_all(mp: &Connection, name: &str) -> HashMap<String, OwnedValue> {
    let r = mp.call_method(Some(name), MPRIS_PATH, Some(PROPS), "GetAll", &(MPRIS_PLAYER,)).await;
    r.ok().and_then(|m| m.body().deserialize().ok()).unwrap_or_default()
}

pub async fn watch(sys: Connection, mp: Connection, prv: Connection, st: Arc<Mutex<State>>) -> zbus::Result<()> {
    for rule in [
        format!("type='signal',sender='{DBUS}',member='NameOwnerChanged',arg0namespace='org.mpris.MediaPlayer2'"),
        format!("type='signal',interface='{PROPS}',member='PropertiesChanged',path='{MPRIS_PATH}'"),
    ] {
        mp.call_method(Some(DBUS), "/org/freedesktop/DBus", Some(DBUS), "AddMatch", &(rule,)).await?;
    }
    // уникальное имя -> (well-known имя, Identity)
    let mut players: HashMap<String, (String, String)> = HashMap::new();
    let names: Vec<String> = mp
        .call_method(Some(DBUS), "/org/freedesktop/DBus", Some(DBUS), "ListNames", &())
        .await?
        .body()
        .deserialize()?;
    // отладка без источника: BT_PROXY_FAKE=<имя> — сразу устройство в Playing
    if let Ok(fake) = std::env::var("BT_PROXY_FAKE") {
        let p = HashMap::from([("PlaybackStatus".to_string(), Value::from("Playing").try_to_owned()?)]);
        let sigs = apply(&mut st.lock().unwrap(), &format!("{MPRIS_PREFIX}{fake}"), &fake, &p)?;
        emit_all(&sys, Some((&mp, &prv)), sigs).await?;
    }
    let mut stream = MessageStream::from(&mp);
    let mut pending: Vec<String> = names.into_iter().filter(|n| n.starts_with(MPRIS_PREFIX)).collect();
    loop {
        for name in pending.drain(..) {
            let owner: Option<String> = mp
                .call_method(Some(DBUS), "/org/freedesktop/DBus", Some(DBUS), "GetNameOwner", &(name.as_str(),))
                .await
                .ok()
                .and_then(|m| m.body().deserialize().ok());
            let Some(owner) = owner else { continue };
            let id = identity(&mp, &name).await;
            let props = get_all(&mp, &name).await;
            eprintln!("bt-proxy: плеер {name} ({id})");
            players.insert(owner, (name.clone(), id.clone()));
            let sigs = apply(&mut st.lock().unwrap(), &name, &id, &props)?;
            emit_all(&sys, Some((&mp, &prv)), sigs).await?;
        }
        let Some(m) = stream.next().await else { break };
        let Ok(m) = m else { continue };
        if m.message_type() != Type::Signal {
            continue;
        }
        let h = m.header();
        match h.member().map(|x| x.as_str()) {
            Some("NameOwnerChanged") => {
                let Ok((name, _old, new)) = m.body().deserialize::<(String, String, String)>() else { continue };
                if !name.starts_with(MPRIS_PREFIX) {
                    continue;
                }
                players.retain(|_, (n, _)| *n != name);
                if new.is_empty() {
                    let sigs = remove(&mut st.lock().unwrap(), |d| d.mpris == name)?;
                    emit_all(&sys, Some((&mp, &prv)), sigs).await?;
                } else {
                    pending.push(name);
                }
            }
            Some("PropertiesChanged") => {
                let sender = h.sender().map(|s| s.to_string()).unwrap_or_default();
                let Some((name, id)) = players.get(&sender).cloned() else { continue };
                let Ok((iface, props, _)) = m.body().deserialize::<(String, HashMap<String, OwnedValue>, Vec<String>)>()
                else {
                    continue;
                };
                if iface != MPRIS_PLAYER {
                    continue;
                }
                let sigs = apply(&mut st.lock().unwrap(), &name, &id, &props)?;
                emit_all(&sys, Some((&mp, &prv)), sigs).await?;
            }
            _ => {}
        }
    }
    Ok(())
}

// Вызов maind к пути виртуального устройства.
pub async fn local(sys: &Connection, mp: &Connection, st: &Arc<Mutex<State>>, m: &Message) -> zbus::Result<()> {
    let h = m.header();
    let path = h.path().map(|p| p.to_string()).unwrap_or_default();
    let iface = h.interface().map(|i| i.to_string()).unwrap_or_default();
    let member = h.member().map(|x| x.to_string()).unwrap_or_default();
    let mpris = st.lock().unwrap().devs.iter().find(|d| d.owns(&path)).map(|d| d.mpris.clone());
    let Some(mpris) = mpris else {
        return sys.send(&Message::error(&h, "org.freedesktop.DBus.Error.UnknownObject")?.build(&())?).await;
    };
    let reply = match (iface.as_str(), member.as_str()) {
        (PROPS, "Get") => {
            let (i, n): (String, String) = m.body().deserialize()?;
            let v = st.lock().unwrap().devs.iter().find(|d| d.mpris == mpris).and_then(|d| d.props(&path, &i)?.get(&n).cloned());
            match v {
                Some(v) => Message::method_return(&h)?.build(&(v,))?,
                None => Message::error(&h, "org.freedesktop.DBus.Error.InvalidArgs")?.build(&("No such property",))?,
            }
        }
        (PROPS, "GetAll") => {
            let (i,): (String,) = m.body().deserialize()?;
            let p = st.lock().unwrap().devs.iter().find(|d| d.mpris == mpris).and_then(|d| d.props(&path, &i).cloned());
            Message::method_return(&h)?.build(&(p.unwrap_or_default(),))?
        }
        (PROPS, "Set") => {
            let (i, n, v): (String, String, OwnedValue) = m.body().deserialize()?;
            let sig = {
                let mut s = st.lock().unwrap();
                let d = s.devs.iter_mut().find(|d| d.mpris == mpris).expect("найдено выше");
                d.set(&i, &n, v.clone()).map(|p| changed(&p, &i, Props::from([(n.clone(), v.clone())])))
            };
            if let Some(sig) = sig {
                sys.send(&sig?).await?;
            }
            // общая громкость: Алиса двигает Volume транспорта — двигаем плеер
            if i == "org.bluez.MediaTransport1" && n == "Volume" {
                if let Ok(vol) = u16::try_from(v) {
                    let mv = Value::from(virt::to_mpris_volume(vol));
                    let _ = mp.call_method(Some(mpris.as_str()), MPRIS_PATH, Some(PROPS), "Set", &(MPRIS_PLAYER, "Volume", mv)).await;
                }
            }
            Message::method_return(&h)?.build(&())?
        }
        ("org.bluez.MediaPlayer1", cmd @ ("Play" | "Pause" | "Stop" | "Next" | "Previous")) => {
            eprintln!("bt-proxy: {mpris}.{cmd}");
            let _ = mp.call_method(Some(mpris.as_str()), MPRIS_PATH, Some(MPRIS_PLAYER), cmd, &()).await;
            Message::method_return(&h)?.build(&())?
        }
        ("org.bluez.MediaPlayer1", "FastForward" | "Rewind") => Message::method_return(&h)?.build(&())?,
        ("org.freedesktop.DBus.Introspectable", "Introspect") => {
            let xml = "<node></node>";
            Message::method_return(&h)?.build(&(xml,))?
        }
        _ => Message::error(&h, "org.freedesktop.DBus.Error.UnknownMethod")?.build(&())?,
    };
    if crate::no_reply(m) {
        return Ok(());
    }
    sys.send(&reply).await
}
