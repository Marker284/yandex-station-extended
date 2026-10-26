// bt-proxy: прозрачный посредник между системной шиной D-Bus и приватной шиной Bluetooth.
//
// bluetoothd, bluealsa, bluealsa-aplay и агент сопряжения работают на приватной шине
// (DBUS_SYSTEM_BUS_ADDRESS), а на системной имена org.bluez и org.bluealsa держит этот процесс:
//  - вызовы клиентов системной шины (maind) пересылаются на приватную, ответы — обратно;
//  - сигналы приватной шины переизлучаются на системной;
//  - обратные вызовы bluetoothd в объекты клиентов (агенты, BLE-реклама, GATT) пересылаются тому,
//    кто эти объекты зарегистрировал.
// Тела сообщений и файловые дескрипторы передаются как есть, без разбора.
//
// Поверх этого — виртуальные устройства для MPRIS-плееров (virt.rs, mpris.rs): вызовы к их путям
// обрабатываются локально, ответ GetManagedObjects дополняется ими.
mod mpris;
mod virt;

use std::collections::HashMap;
use std::os::fd::AsFd;
use std::sync::{Arc, Mutex};

use futures_util::StreamExt;
use zbus::message::{Builder, Flags, Type};
use zbus::{Connection, Message, MessageStream};

const NAMES: [&str; 2] = ["org.bluez", "org.bluealsa"];
const DBUS: &str = "org.freedesktop.DBus";

#[derive(Default)]
struct State {
    // serial пересланного на приватную шину вызова -> исходный вызов с системной
    to_private: HashMap<u32, Message>,
    // serial пересланного на системную шину обратного вызова -> исходный вызов с приватной
    to_system: HashMap<u32, Message>,
    // путь зарегистрированного объекта -> уникальное имя клиента на системной шине
    owners: Vec<(String, String)>,
    last_client: Option<String>,
    // виртуальные устройства MPRIS-плееров
    devs: Vec<virt::Dev>,
    // serial пересланных GetManagedObjects, ответ на которые надо дополнить ими
    patch: std::collections::HashSet<u32>,
    // плееры настоящих Bluetooth-телефонов в статусе playing (по сигналам bluetoothd)
    real_playing: std::collections::HashSet<String>,
    // уникальные имена bluetoothd и bluealsa на приватной шине: на системную уходят только их
    // сигналы, а не avahi и плееров, если те живут на той же шине
    backends: HashMap<String, String>,
}

impl State {
    fn owner_of(&self, path: &str) -> Option<String> {
        self.owners
            .iter()
            .filter(|(p, _)| path == p || path.starts_with(&format!("{p}/")))
            .max_by_key(|(p, _)| p.len())
            .map(|(_, o)| o.clone())
            .or_else(|| self.last_client.clone())
    }
}

pub(crate) fn no_reply(m: &Message) -> bool {
    m.primary_header().flags().contains(Flags::NoReplyExpected)
}

fn with_body(b: Builder<'_>, m: &Message) -> zbus::Result<Message> {
    let body = m.body();
    let data = body.data();
    let fds = data
        .fds()
        .iter()
        .map(|fd| fd.as_fd().try_clone_to_owned().map(zbus::zvariant::OwnedFd::from))
        .collect::<Result<Vec<_>, _>>()?;
    // SAFETY: тело и сигнатура взяты из корректного входящего сообщения без изменений
    unsafe { b.build_raw_body(data.bytes(), body.signature().clone(), fds) }
}

fn call_to(m: &Message, dest: &str) -> zbus::Result<Message> {
    let h = m.header();
    let (Some(path), Some(member)) = (h.path(), h.member()) else {
        return Err(zbus::Error::Failure("вызов без пути или метода".into()));
    };
    let mut b = Message::method_call(path.clone(), member.clone())?.destination(dest)?;
    if let Some(i) = h.interface() {
        b = b.interface(i.clone())?;
    }
    if no_reply(m) {
        b = b.with_flags(Flags::NoReplyExpected)?;
    }
    with_body(b, m)
}

// Ответ (return/error) на `orig`, тело — из `reply`.
fn reply_to(orig: &Message, reply: &Message) -> zbus::Result<Message> {
    let oh = orig.header();
    if reply.message_type() == Type::Error {
        let name = reply.header().error_name().map(|n| n.to_string());
        let name = name.as_deref().unwrap_or("org.freedesktop.DBus.Error.Failed");
        return with_body(Message::error(&oh, name)?, reply);
    }
    with_body(Message::method_return(&oh)?, reply)
}

fn signal_from(m: &Message, dest: Option<&str>) -> zbus::Result<Message> {
    let h = m.header();
    let (Some(path), Some(iface), Some(member)) = (h.path(), h.interface(), h.member()) else {
        return Err(zbus::Error::Failure("сигнал без пути, интерфейса или имени".into()));
    };
    let mut b = Message::signal(path.clone(), iface.clone(), member.clone())?;
    if let Some(d) = dest {
        b = b.destination(d)?;
    }
    with_body(b, m)
}

fn backend_for(path: &str) -> &'static str {
    if path.starts_with("/org/bluealsa") {
        "org.bluealsa"
    } else {
        "org.bluez"
    }
}

// Register*(object, ...) — запомнить, чей объект: bluetoothd будет вызывать его обратно.
fn note_registration(st: &mut State, m: &Message) {
    let h = m.header();
    let (Some(member), Some(sender)) = (h.member(), h.sender()) else { return };
    if !member.as_str().starts_with("Register") {
        return;
    }
    if let Ok(s) = m.body().deserialize::<zbus::zvariant::Structure>() {
        if let Some(zbus::zvariant::Value::ObjectPath(p)) = s.fields().first() {
            st.owners.retain(|(path, _)| path != p.as_str());
            st.owners.push((p.to_string(), sender.to_string()));
        }
    }
}

async fn from_system(sys: Connection, prv: Connection, mp: Connection, st: Arc<Mutex<State>>) -> zbus::Result<()> {
    let me = sys.unique_name().map(|n| n.to_string()).unwrap_or_default();
    let mut stream = MessageStream::from(&sys);
    while let Some(m) = stream.next().await {
        let Ok(m) = m else { continue };
        let h = m.header();
        match m.message_type() {
            Type::MethodCall => {
                let dest = h.destination().map(|d| d.to_string()).unwrap_or_default();
                if !NAMES.contains(&dest.as_str()) && dest != me {
                    continue;
                }
                let path = h.path().map(|p| p.to_string()).unwrap_or_default();
                let virt_path = st.lock().unwrap().devs.iter().any(|d| {
                    d.owns(&path) || path.contains(d.path.rsplit('/').next().unwrap_or("-"))
                });
                if virt_path {
                    // org.bluealsa про виртуальные устройства ничего не знает — mpris::local ответит UnknownObject
                    if let Err(e) = mpris::local(&sys, &mp, &st, &m).await {
                        eprintln!("bt-proxy: {path}: {e}");
                    }
                    continue;
                }
                let backend = if dest == me { backend_for(&path) } else if dest == "org.bluealsa" { "org.bluealsa" } else { "org.bluez" };
                let fwd = call_to(&m, backend)?;
                {
                    let mut s = st.lock().unwrap();
                    note_registration(&mut s, &m);
                    s.last_client = h.sender().map(|x| x.to_string());
                    if !no_reply(&m) {
                        let serial = fwd.primary_header().serial_num().get();
                        s.to_private.insert(serial, m.clone());
                        if backend == "org.bluez" && path == "/" && h.member().is_some_and(|x| x == "GetManagedObjects") {
                            s.patch.insert(serial);
                        }
                    }
                }
                prv.send(&fwd).await?;
            }
            Type::MethodReturn | Type::Error => {
                let Some(rs) = h.reply_serial() else { continue };
                let orig = st.lock().unwrap().to_system.remove(&rs.get());
                if let Some(orig) = orig {
                    prv.send(&reply_to(&orig, &m)?).await?;
                }
            }
            Type::Signal => {}
        }
    }
    Ok(())
}

async fn from_private(sys: Connection, prv: Connection, mp: Connection, st: Arc<Mutex<State>>) -> zbus::Result<()> {
    let mut stream = MessageStream::from(&prv);
    while let Some(m) = stream.next().await {
        let Ok(m) = m else { continue };
        let h = m.header();
        match m.message_type() {
            Type::MethodReturn | Type::Error => {
                let Some(rs) = h.reply_serial() else { continue };
                let (orig, extra) = {
                    let mut s = st.lock().unwrap();
                    let extra = s.patch.remove(&rs.get()).then(|| mpris::managed_objects(&s));
                    (s.to_private.remove(&rs.get()), extra)
                };
                let Some(orig) = orig else { continue };
                match extra.filter(|_| m.message_type() == Type::MethodReturn) {
                    Some(extra) => {
                        type Objects = HashMap<zbus::zvariant::OwnedObjectPath, virt::Ifaces>;
                        let mut objs: Objects = m.body().deserialize()?;
                        for (p, i) in extra {
                            objs.insert(zbus::zvariant::ObjectPath::try_from(p)?.into(), i);
                        }
                        sys.send(&Message::method_return(&orig.header())?.build(&(objs,))?).await?;
                    }
                    None => sys.send(&reply_to(&orig, &m)?).await?,
                }
            }
            Type::Signal => {
                if h.sender().is_some_and(|s| s.as_str() == DBUS) {
                    if h.member().is_some_and(|x| x == "NameOwnerChanged") {
                        if let Ok((name, _, new)) = m.body().deserialize::<(String, String, String)>() {
                            if NAMES.contains(&name.as_str()) {
                                st.lock().unwrap().backends.insert(name, new);
                            }
                        }
                    }
                    continue;
                }
                let sender = h.sender().map(|x| x.to_string()).unwrap_or_default();
                if !st.lock().unwrap().backends.values().any(|o| *o == sender) {
                    continue;
                }
                // заиграл настоящий телефон — виртуальные плееры уступают
                if h.member().is_some_and(|x| x == "PropertiesChanged") {
                    type Changed = (String, HashMap<String, zbus::zvariant::OwnedValue>, Vec<String>);
                    if let Ok((iface, props, _)) = m.body().deserialize::<Changed>() {
                        let status = props.get("Status").and_then(|v| String::try_from(v.clone()).ok());
                        if let (true, Some(status)) = (iface == "org.bluez.MediaPlayer1", status) {
                            let path = h.path().map(|p| p.to_string()).unwrap_or_default();
                            let pause = {
                                let mut s = st.lock().unwrap();
                                if status == "playing" {
                                    s.real_playing.insert(path);
                                    mpris::playing_virtual(&s)
                                } else {
                                    s.real_playing.remove(&path);
                                    Vec::new()
                                }
                            };
                            for name in pause {
                                mpris::pause_mpris(&mp, &name).await;
                            }
                        }
                    }
                }
                let dest = h.destination().is_some().then(|| {
                    let path = h.path().map(|p| p.to_string()).unwrap_or_default();
                    st.lock().unwrap().owner_of(&path)
                });
                let dest = dest.flatten();
                sys.send(&signal_from(&m, dest.as_deref())?).await?;
            }
            Type::MethodCall => {
                let path = h.path().map(|p| p.to_string()).unwrap_or_default();
                let target = st.lock().unwrap().owner_of(&path);
                let Some(target) = target else {
                    if !no_reply(&m) {
                        let e = Message::error(&h, "org.freedesktop.DBus.Error.UnknownObject")?.build(&())?;
                        prv.send(&e).await?;
                    }
                    continue;
                };
                let fwd = call_to(&m, &target)?;
                if !no_reply(&m) {
                    st.lock().unwrap().to_system.insert(fwd.primary_header().serial_num().get(), m.clone());
                }
                sys.send(&fwd).await?;
            }
        }
    }
    Ok(())
}

async fn run() -> zbus::Result<()> {
    let addr = std::env::var("BT_PRIVATE_BUS").unwrap_or_else(|_| "unix:path=/tmp/btbus/socket".into());
    let prv = zbus::connection::Builder::address(addr.as_str())?.build().await?;
    let sys = zbus::connection::Builder::system()?.build().await?;
    prv.call_method(Some(DBUS), "/org/freedesktop/DBus", Some(DBUS), "AddMatch", &("type='signal'"))
        .await?;
    for n in NAMES {
        sys.request_name(n).await?;
    }
    eprintln!("bt-proxy: {} <-> {}", sys.unique_name().map(|n| n.as_str()).unwrap_or("?"), addr);
    // шина MPRIS-плееров; по умолчанию — та же приватная
    let mp_addr = std::env::var("MPRIS_BUS").unwrap_or_else(|_| addr.clone());
    let mp = zbus::connection::Builder::address(mp_addr.as_str())?.build().await?;
    let st = Arc::new(Mutex::new(State::default()));
    for n in NAMES {
        let owner = prv
            .call_method(Some(DBUS), "/org/freedesktop/DBus", Some(DBUS), "GetNameOwner", &(n,))
            .await
            .ok()
            .and_then(|m| m.body().deserialize::<String>().ok());
        if let Some(o) = owner {
            st.lock().unwrap().backends.insert(n.to_string(), o);
        }
    }
    mpris::on_exit(sys.clone(), st.clone());
    let a = from_system(sys.clone(), prv.clone(), mp.clone(), st.clone());
    let b = from_private(sys.clone(), prv.clone(), mp.clone(), st.clone());
    let c = mpris::watch(sys.clone(), mp, prv, st.clone());
    let d = mpris::sweep(sys, st);
    let (ra, rb, rc, rd) = futures_util::future::join4(a, b, c, d).await;
    ra.and(rb).and(rc).and(rd)
}

fn main() {
    if let Err(e) = async_io::block_on(run()) {
        eprintln!("bt-proxy: {e}");
        std::process::exit(1);
    }
}
