import java.io.*;
import java.lang.reflect.*;
import java.net.*;
import java.nio.charset.Charset;
import java.security.*;
import java.util.*;
import java.util.concurrent.*;
import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;

/** Standalone Android 6 remote. No APK, monkey, instrumentation or per-key VM. */
public final class StationRemote {
  static final String VERSION = "2.0.0", COOKIE = "station_remote";
  static final Charset UTF8 = Charset.forName("UTF-8");
  static final SecureRandom RANDOM = new SecureRandom();
  static final Map<String, Integer> KEYS = new HashMap<String, Integer>();

  static {
    String[] names = {
      "up", "down", "left", "right", "ok", "back", "menu", "play", "volup", "voldown", "mute",
      "delete", "enter"
    };
    int[] codes = {19, 20, 21, 22, 23, 4, 82, 85, 24, 25, 164, 67, 66};
    for (int i = 0; i < names.length; i++) KEYS.put(names[i], codes[i]);
  }

  final File root;
  final String address;
  final int port;
  final Properties config = new Properties();
  final Object configLock = new Object();
  final ConcurrentMap<String, Session> sessions = new ConcurrentHashMap<String, Session>();
  final ConcurrentMap<String, Attempts> attempts = new ConcurrentHashMap<String, Attempts>();
  final ExecutorService workers =
      new ThreadPoolExecutor(2, 12, 60, TimeUnit.SECONDS, new SynchronousQueue<Runnable>());
  final ScheduledExecutorService clock = Executors.newScheduledThreadPool(1);
  final Input input = new Input();
  final long started = System.currentTimeMillis();
  byte[] html;

  static final class Session {
    final String id = token(), csrf = token();
    final long expires = System.currentTimeMillis() + 43200000L;
  }

  static final class Attempts {
    long since = System.currentTimeMillis();
    int failures;
  }

  StationRemote(File root, String address, int port) throws Exception {
    this.root = root;
    this.address = address;
    this.port = port;
    html = readFile(new File(root, "index.html"), 262144);
    File f = new File(root, "auth.properties");
    if (f.exists()) {
      FileInputStream in = new FileInputStream(f);
      try {
        config.load(in);
      } finally {
        in.close();
      }
    }
    if (!configured()) {
      if (config.getProperty("setupToken") == null) {
        config.setProperty("setupToken", token());
        saveConfig();
      }
      writeFile(new File(root, "setup.token"), config.getProperty("setupToken").getBytes(UTF8));
    }
    clock.scheduleAtFixedRate(
        new Runnable() {
          public void run() {
            input.repeat();
            for (Map.Entry<String, Session> e : sessions.entrySet())
              if (e.getValue().expires < System.currentTimeMillis()) sessions.remove(e.getKey());
          }
        },
        40,
        70,
        TimeUnit.MILLISECONDS);
    Runtime.getRuntime()
        .addShutdownHook(
            new Thread(
                new Runnable() {
                  public void run() {
                    input.releaseAll();
                  }
                },
                "release-input"));
  }

  boolean configured() {
    synchronized (configLock) {
      return config.getProperty("passwordHash") != null;
    }
  }

  void saveConfig() throws IOException {
    synchronized (configLock) {
      File f = new File(root, "auth.properties.new");
      FileOutputStream out = new FileOutputStream(f);
      try {
        config.store(out, "Station Remote credentials (PBKDF2, not plaintext)");
        out.getFD().sync();
      } finally {
        out.close();
      }
      if (!f.renameTo(new File(root, "auth.properties")))
        throw new IOException("Cannot save credentials");
    }
  }

  static String token() {
    byte[] b = new byte[32];
    RANDOM.nextBytes(b);
    return hex(b);
  }

  static String hex(byte[] b) {
    StringBuilder s = new StringBuilder();
    for (byte n : b) s.append(String.format(Locale.US, "%02x", n & 255));
    return s.toString();
  }

  static byte[] unhex(String s) {
    byte[] b = new byte[s.length() / 2];
    for (int i = 0; i < b.length; i++)
      b[i] = (byte) Integer.parseInt(s.substring(i * 2, i * 2 + 2), 16);
    return b;
  }

  static boolean equal(String a, String b) {
    return a != null && b != null && MessageDigest.isEqual(a.getBytes(UTF8), b.getBytes(UTF8));
  }

  static String hash(String password, String salt) throws Exception {
    PBEKeySpec spec = new PBEKeySpec(password.toCharArray(), unhex(salt), 100000, 256);
    try {
      return hex(
          SecretKeyFactory.getInstance("PBKDF2WithHmacSHA1").generateSecret(spec).getEncoded());
    } finally {
      spec.clearPassword();
    }
  }

  void setPassword(String password) throws Exception {
    if (password == null || password.length() < 8 || password.length() > 128)
      throw new Bad(400, "Пароль должен содержать от 8 до 128 символов");
    synchronized (configLock) {
      String salt = token();
      config.setProperty("salt", salt);
      config.setProperty("passwordHash", hash(password, salt));
      config.remove("setupToken");
      saveConfig();
      new File(root, "setup.token").delete();
    }
  }

  boolean passwordMatches(String password) throws Exception {
    synchronized (configLock) {
      return configured()
          && password != null
          && equal(config.getProperty("passwordHash"), hash(password, config.getProperty("salt")));
    }
  }

  void failed(String ip) {
    Attempts a = attempts.get(ip);
    if (a == null) {
      a = new Attempts();
      attempts.put(ip, a);
    }
    synchronized (a) {
      if (System.currentTimeMillis() - a.since > 60000) {
        a.since = System.currentTimeMillis();
        a.failures = 0;
      }
      a.failures++;
    }
  }

  void checkLimit(String ip) throws Bad {
    Attempts a = attempts.get(ip);
    if (a != null && System.currentTimeMillis() - a.since < 60000 && a.failures >= 8)
      throw new Bad(429, "Слишком много попыток. Подождите минуту");
  }

  Session session(Request r) {
    String cookies = r.headers.get("cookie");
    if (cookies != null)
      for (String c : cookies.split(";")) {
        String[] p = c.trim().split("=", 2);
        if (p.length == 2 && COOKIE.equals(p[0])) {
          Session s = sessions.get(p[1]);
          if (s != null && s.expires > System.currentTimeMillis()) return s;
        }
      }
    return null;
  }

  String sessionCookie(Session s) {
    return "Set-Cookie: "
        + COOKIE
        + "="
        + s.id
        + "; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200\r\n";
  }

  Session newSession() {
    if (sessions.size() > 64) sessions.clear();
    Session s = new Session();
    sessions.put(s.id, s);
    return s;
  }

  String state(Session s) {
    return "{\"version\":"
        + quote(VERSION)
        + ",\"setupRequired\":"
        + !configured()
        + ",\"authenticated\":"
        + (s != null)
        + ",\"csrf\":"
        + quote(s == null ? "" : s.csrf)
        + ",\"boot\":"
        + quote(boot())
        + ",\"uptime\":"
        + (System.currentTimeMillis() - started)
        + "}";
  }

  String boot() {
    try {
      return new String(readFile(new File("/data/dropbear/tv.conf"), 1024), UTF8)
              .contains("BOOT_LAUNCHER=couchy")
          ? "couchy"
          : "alice";
    } catch (Exception e) {
      return "alice";
    }
  }

  void serve() throws Exception {
    ServerSocket server = new ServerSocket();
    server.setReuseAddress(true);
    server.bind(new InetSocketAddress(InetAddress.getByName(address), port), 16);
    System.out.println(
        "Station Remote " + VERSION + " READY " + address + ":" + port + " input=InputManager");
    while (true) {
      final Socket socket = server.accept();
      socket.setTcpNoDelay(true);
      socket.setSoTimeout(10000);
      try {
        workers.execute(
            new Runnable() {
              public void run() {
                handle(socket);
              }
            });
      } catch (RejectedExecutionException e) {
        socket.close();
      }
    }
  }

  void handle(Socket socket) {
    try {
      Request r = Request.read(socket);
      String host = r.headers.get("host");
      String expected = address + ":" + port;
      if (!expected.equals(host)) throw new Bad(403, "Недопустимый адрес");
      String origin = r.headers.get("origin");
      if (origin != null && !origin.equals("http://" + expected))
        throw new Bad(403, "Недопустимый источник запроса");
      Session s = session(r);
      if (r.path.equals("/") && r.method.equals("GET")) {
        response(socket, 200, "text/html; charset=utf-8", html, "");
        return;
      }
      if (r.path.equals("/api/state") && r.method.equals("GET")) {
        json(socket, 200, state(s), "");
        return;
      }
      if (r.path.equals("/api/setup") && r.method.equals("POST")) {
        checkLimit(r.ip);
        synchronized (configLock) {
          if (configured()) throw new Bad(409, "Пароль уже задан");
          if (!equal(config.getProperty("setupToken"), r.params.get("token"))) {
            failed(r.ip);
            throw new Bad(403, "Откройте ссылку первого запуска из установщика");
          }
          setPassword(r.params.get("password"));
        }
        s = newSession();
        json(socket, 200, state(s), sessionCookie(s));
        return;
      }
      if (r.path.equals("/api/login") && r.method.equals("POST")) {
        checkLimit(r.ip);
        if (!passwordMatches(r.params.get("password"))) {
          failed(r.ip);
          throw new Bad(401, "Неверный пароль");
        }
        attempts.remove(r.ip);
        s = newSession();
        json(socket, 200, state(s), sessionCookie(s));
        return;
      }
      if (s == null) throw new Bad(401, "Нужен вход в пульт");
      if (r.path.equals("/ws") && r.method.equals("GET")) {
        if (origin == null || !equal(s.csrf, r.params.get("csrf")))
          throw new Bad(403, "Подключение отклонено");
        websocket(socket, r, s);
        return;
      }
      if (!r.method.equals("POST")) throw new Bad(404, "Не найдено");
      if (!equal(s.csrf, r.headers.get("x-remote-csrf"))) throw new Bad(403, "Обновите страницу");
      if (r.path.equals("/api/logout")) {
        sessions.remove(s.id);
        json(
            socket,
            200,
            "{\"ok\":true}",
            "Set-Cookie: " + COOKIE + "=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0\r\n");
        return;
      }
      if (r.path.equals("/api/password")) {
        if (!passwordMatches(r.params.get("current")))
          throw new Bad(401, "Неверный текущий пароль");
        setPassword(r.params.get("password"));
        sessions.clear();
        s = newSession();
        json(socket, 200, state(s), sessionCookie(s));
        return;
      }
      if (r.path.equals("/api/command")) {
        json(socket, 200, command(r.params, s.id), "");
        return;
      }
      throw new Bad(404, "Не найдено");
    } catch (Bad e) {
      try {
        json(socket, e.code, "{\"error\":" + quote(e.getMessage()) + "}", "");
      } catch (Exception ignored) {
      }
    } catch (Exception e) {
      System.err.println("Connection: " + e.getClass().getSimpleName());
      if (root.getAbsolutePath().startsWith("/data/local/tmp/")) e.printStackTrace();
      try {
        json(socket, 500, "{\"error\":\"Ошибка обработки команды\"}", "");
      } catch (Exception ignored) {
      }
    } finally {
      try {
        socket.close();
      } catch (Exception ignored) {
      }
    }
  }

  void websocket(Socket socket, Request r, Session session) throws Exception {
    if (!"websocket".equalsIgnoreCase(r.headers.get("upgrade"))
        || !"13".equals(r.headers.get("sec-websocket-version")))
      throw new Bad(400, "Неверное подключение");
    String key = r.headers.get("sec-websocket-key");
    if (key == null || key.length() > 64) throw new Bad(400, "Неверный ключ");
    String accept =
        base64(
            MessageDigest.getInstance("SHA-1")
                .digest((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").getBytes("US-ASCII")));
    OutputStream out = socket.getOutputStream();
    out.write(
        ("HTTP/1.1 101 Switching Protocols\r\n"
             + "Upgrade: websocket\r\n"
             + "Connection: Upgrade\r\n"
             + "Sec-WebSocket-Accept: "
                + accept
                + "\r\n\r\n")
            .getBytes("US-ASCII"));
    out.flush();
    socket.setSoTimeout(45000);
    String owner = token();
    InputStream in = socket.getInputStream();
    try {
      while (sessions.get(session.id) == session && session.expires > System.currentTimeMillis()) {
        int a = in.read();
        if (a < 0) break;
        int b = in.read();
        if (b < 0) break;
        if ((a & 0x80) == 0 || (a & 0x70) != 0 || (b & 0x80) == 0) break;
        int opcode = a & 15;
        long len = b & 127;
        if (len == 126) len = (readByte(in) << 8) | readByte(in);
        else if (len == 127) break;
        if (len > 8192) break;
        byte[] mask = new byte[4];
        readFully(in, mask);
        byte[] payload = new byte[(int) len];
        readFully(in, payload);
        for (int i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
        if (opcode == 8) {
          frame(out, 8, new byte[0]);
          break;
        }
        if (opcode == 9) {
          frame(out, 10, payload);
          continue;
        }
        if (opcode == 10) continue;
        if (opcode != 1) break;
        if (sessions.get(session.id) != session) break;
        Map<String, String> p = form(new String(payload, UTF8));
        String answer;
        try {
          answer = command(p, owner);
        } catch (Bad e) {
          answer = "{\"id\":" + quote(p.get("id")) + ",\"error\":" + quote(e.getMessage()) + "}";
        } catch (Exception e) {
          answer = "{\"id\":" + quote(p.get("id")) + ",\"error\":\"Команда не выполнена\"}";
          System.err.println("Command failed: " + e.getClass().getSimpleName());
        }
        frame(out, 1, answer.getBytes(UTF8));
      }
    } finally {
      input.release(owner);
    }
  }

  String command(Map<String, String> p, String owner) throws Exception {
    long start = System.nanoTime();
    String action = p.get("action"), result = "";
    if ("ping".equals(action)) {
    } else if ("key".equals(action)) {
      Integer code = KEYS.get(p.get("key"));
      if (code == null) throw new Bad(400, "Неизвестная кнопка");
      String phase = p.get("phase");
      if ("down".equals(phase)) input.down(code, owner);
      else if ("up".equals(phase)) input.up(code, owner);
      else input.tap(code);
    } else if ("hold".equals(action)) {
      input.refresh(owner);
    } else if ("release".equals(action)) {
      input.release(owner);
    } else if ("app".equals(action)) {
      result = input.open(p.get("app"));
    } else if ("text".equals(action)) {
      String text = p.get("text");
      if (text == null || text.length() > 1000) throw new Bad(400, "Слишком длинный текст");
      result = input.text(text);
    } else if ("vpn".equals(action)) {
      String link = p.get("link");
      if (link == null
          || link.length() > 6000
          || !link.matches("(?s)^(vless|vmess|trojan|ss|https?)://[^\\r\\n]+$"))
        throw new Bad(400, "Нужна ссылка VPN или подписки");
      input.vpn(link.trim());
      result = "Подтвердите импорт на телевизоре";
    } else if ("boot".equals(action)) {
      String boot = p.get("value");
      if (!"alice".equals(boot) && !"couchy".equals(boot))
        throw new Bad(400, "Неизвестный лаунчер");
      writeFile(
          new File("/data/dropbear/tv.conf"), ("BOOT_LAUNCHER=" + boot + "\n").getBytes(UTF8));
      result = "Сохранено для следующего включения";
    } else if ("reboot".equals(action)) {
      if (!"reboot".equals(p.get("confirm"))) throw new Bad(400, "Требуется подтверждение");
      clock.schedule(
          new Runnable() {
            public void run() {
              try {
                Runtime.getRuntime().exec(new String[] {"/system/bin/reboot"});
              } catch (Exception ignored) {
              }
            }
          },
          1,
          TimeUnit.SECONDS);
      result = "Перезагрузка…";
    } else throw new Bad(400, "Неизвестная команда");
    return "{\"id\":"
        + quote(p.get("id"))
        + ",\"ok\":true,\"ms\":"
        + ((System.nanoTime() - start) / 1000000.0)
        + ",\"message\":"
        + quote(result)
        + "}";
  }

  final class Input {
    final Class<?> keyClass, eventClass, intentClass;
    final Object manager, kcm, activity;
    final Method inject, uptime, getEvents, startActivity;
    final Constructor<?> keyConstructor;
    final Map<Integer, Held> held = new HashMap<Integer, Held>();

    final class Held {
      int code, repeats;
      long down, lastRepeat, refresh;
      String owner;
    }

    Input() {
      try {
        keyClass = Class.forName("android.view.KeyEvent");
        eventClass = Class.forName("android.view.InputEvent");
        intentClass = Class.forName("android.content.Intent");
        Class<?> im = Class.forName("android.hardware.input.InputManager");
        manager = im.getMethod("getInstance").invoke(null);
        inject = im.getMethod("injectInputEvent", eventClass, int.class);
        uptime = Class.forName("android.os.SystemClock").getMethod("uptimeMillis");
        keyConstructor =
            keyClass.getConstructor(
                long.class,
                long.class,
                int.class,
                int.class,
                int.class,
                int.class,
                int.class,
                int.class,
                int.class,
                int.class);
        Class<?> map = Class.forName("android.view.KeyCharacterMap");
        kcm = map.getMethod("load", int.class).invoke(null, -1);
        getEvents = map.getMethod("getEvents", char[].class);
        activity =
            Class.forName("android.app.ActivityManagerNative").getMethod("getDefault").invoke(null);
        Method found = null;
        for (Method m : Class.forName("android.app.IActivityManager").getMethods())
          if (m.getName().equals("startActivityAsUser") && m.getParameterTypes().length == 11) {
            found = m;
            break;
          }
        if (found == null) throw new NoSuchMethodException("startActivityAsUser");
        startActivity = found;
      } catch (Exception e) {
        throw new RuntimeException("Android input API unavailable", e);
      }
    }

    long now() throws Exception {
      return ((Long) uptime.invoke(null)).longValue();
    }

    void event(long down, int action, int code, int repeat, int meta) throws Exception {
      Object e =
          keyConstructor.newInstance(
              down, now(), action, code, repeat, meta, -1, 0, repeat == 1 ? 128 : 0, 0x101);
      if (!Boolean.TRUE.equals(inject.invoke(manager, e, 0)))
        throw new IOException("Input injection rejected");
    }

    synchronized void tap(int code) throws Exception {
      long t = now();
      event(t, 0, code, 0, 0);
      event(t, 1, code, 0, 0);
    }

    synchronized void down(int code, String owner) throws Exception {
      Held old = held.get(code);
      if (old != null) {
        old.refresh = System.currentTimeMillis();
        return;
      }
      Held h = new Held();
      h.code = code;
      h.owner = owner;
      h.down = now();
      h.lastRepeat = h.down;
      h.refresh = System.currentTimeMillis();
      held.put(code, h);
      event(h.down, 0, code, 0, 0);
    }

    synchronized void up(int code, String owner) throws Exception {
      Held h = held.get(code);
      if (h != null && h.owner.equals(owner)) {
        event(h.down, 1, code, 0, 0);
        held.remove(code);
      }
    }

    synchronized void refresh(String owner) {
      for (Held h : held.values())
        if (h.owner.equals(owner)) h.refresh = System.currentTimeMillis();
    }

    synchronized void release(String owner) {
      for (Held h : new ArrayList<Held>(held.values()))
        if (h.owner.equals(owner)) {
          try {
            event(h.down, 1, h.code, 0, 0);
          } catch (Exception ignored) {
          }
          held.remove(h.code);
        }
    }

    synchronized void releaseAll() {
      for (Held h : new ArrayList<Held>(held.values())) {
        try {
          event(h.down, 1, h.code, 0, 0);
        } catch (Exception ignored) {
        }
      }
      held.clear();
    }

    synchronized void repeat() {
      try {
        long n = now();
        for (Held h : new ArrayList<Held>(held.values())) {
          if (System.currentTimeMillis() - h.refresh > 1400) {
            up(h.code, h.owner);
            continue;
          }
          if (n - h.down >= 320
              && n - h.lastRepeat >= 100
              && (h.code == 19
                  || h.code == 20
                  || h.code == 21
                  || h.code == 22
                  || h.code == 24
                  || h.code == 25
                  || h.code == 67)) {
            h.repeats++;
            event(h.down, 0, h.code, h.repeats, 0);
            h.lastRepeat = n;
          }
        }
      } catch (Exception e) {
        held.clear();
      }
    }

    void launch(Object intent) throws Exception {
      intentClass.getMethod("addFlags", int.class).invoke(intent, 0x10000000);
      Object result =
          startActivity.invoke(activity, null, null, intent, null, null, null, 0, 0, null, null, 0);
      if (result instanceof Integer && ((Integer) result) < 0)
        throw new Bad(400, "Приложение не установлено или настройки недоступны");
    }

    Object component(String pkg, String cls) throws Exception {
      Object i = intentClass.getConstructor().newInstance();
      intentClass.getMethod("setClassName", String.class, String.class).invoke(i, pkg, cls);
      return i;
    }

    String open(String app) throws Exception {
      Object intent;
      if ("alice".equals(app))
        intent = component("ru.yandex.quasar.app", "ru.yandex.quasar.app.MainActivity");
      else if ("launcher".equals(app))
        intent = component("com.conreo.couchytv", "com.conreo.couchytv.MainActivity");
      else if ("youtube".equals(app))
        intent =
            component(
                "org.smarttube.stable",
                "com.liskovsoft.smartyoutubetv2.tv.ui.browse.BrowseActivity");
      else if ("vpn".equals(app))
        intent = component("com.v2ray.ang", "com.v2ray.ang.ui.MainActivity");
      else if ("settings".equals(app))
        intent = intentClass.getConstructor(String.class).newInstance("android.settings.SETTINGS");
      else if ("wifi".equals(app))
        intent =
            intentClass.getConstructor(String.class).newInstance("android.settings.WIFI_SETTINGS");
      else throw new Bad(400, "Неизвестное приложение");
      launch(intent);
      return "Открыто на телевизоре";
    }

    synchronized String text(String text) throws Exception {
      if (text.length() == 0) return "";
      Object events = getEvents.invoke(kcm, (Object) text.toCharArray());
      if (events != null) {
        int n = Array.getLength(events);
        for (int i = 0; i < n; i++)
          if (!Boolean.TRUE.equals(inject.invoke(manager, Array.get(events, i), 0)))
            throw new IOException("Input rejected");
        return "Текст введён";
      }
      paste(text);
      return "Текст вставлен";
    }

    void paste(final String text) throws Exception {
      Class<?> service = Class.forName("android.os.ServiceManager"),
          binder = Class.forName("android.os.IBinder"),
          clipClass = Class.forName("android.content.ClipData");
      Object raw = service.getMethod("getService", String.class).invoke(null, "clipboard");
      final Object clipboard =
          Class.forName("android.content.IClipboard$Stub")
              .getMethod("asInterface", binder)
              .invoke(null, raw);
      Class<?> iface = Class.forName("android.content.IClipboard");
      final Method get = iface.getMethod("getPrimaryClip", String.class),
          set = iface.getMethod("setPrimaryClip", clipClass, String.class);
      Object old = null;
      boolean readable = true;
      try {
        old = get.invoke(clipboard, "com.android.shell");
      } catch (InvocationTargetException e) {
        readable = false;
      }
      final boolean canRead = readable;
      final Object previous =
          old != null
              ? old
              : clipClass
                  .getMethod("newPlainText", CharSequence.class, CharSequence.class)
                  .invoke(null, "", "");
      Object clip =
          clipClass
              .getMethod("newPlainText", CharSequence.class, CharSequence.class)
              .invoke(null, "Station remote", text);
      set.invoke(clipboard, clip, "com.android.shell");
      long t = now();
      event(t, 0, 113, 0, 0x3000);
      event(t, 0, 50, 0, 0x3000);
      event(t, 1, 50, 0, 0x3000);
      event(t, 1, 113, 0, 0);
      clock.schedule(
          new Runnable() {
            public void run() {
              try {
                if (!canRead) {
                  set.invoke(clipboard, previous, "com.android.shell");
                  return;
                }
                Object current = get.invoke(clipboard, "com.android.shell");
                if (current != null) {
                  Object item =
                      current.getClass().getMethod("getItemAt", int.class).invoke(current, 0);
                  Object value = item.getClass().getMethod("getText").invoke(item);
                  if (text.equals(String.valueOf(value)))
                    set.invoke(clipboard, previous, "com.android.shell");
                }
              } catch (Exception ignored) {
              }
            }
          },
          1500,
          TimeUnit.MILLISECONDS);
    }

    void vpn(String link) throws Exception {
      link = VlessLink.normalize(link);
      String url =
          "v2rayng://"
              + (link.startsWith("http") ? "install-sub" : "install-config")
              + "?url="
              + URLEncoder.encode(URLEncoder.encode(link, "UTF-8"), "UTF-8");
      Object intent = component("com.v2ray.ang", "com.v2ray.ang.ui.UrlSchemeActivity");
      intentClass.getMethod("setAction", String.class).invoke(intent, "android.intent.action.VIEW");
      Class<?> uri = Class.forName("android.net.Uri");
      intentClass
          .getMethod("setData", uri)
          .invoke(intent, uri.getMethod("parse", String.class).invoke(null, url));
      launch(intent);
      if (!link.startsWith("http")) clock.schedule(new Runnable() {
        public void run() {
          try {
            Object main = component("com.v2ray.ang", "com.v2ray.ang.ui.MainActivity");
            intentClass.getMethod("addFlags", int.class).invoke(main, 0x00008000);
            launch(main);
          } catch (Exception ignored) { }
        }
      }, 2, TimeUnit.SECONDS);
    }
  }

  static final class Bad extends Exception {
    final int code;

    Bad(int code, String message) {
      super(message);
      this.code = code;
    }
  }

  static final class Request {
    String method, path, ip;
    Map<String, String> headers = new HashMap<String, String>(), params;

    static Request read(Socket socket) throws Exception {
      Request r = new Request();
      r.ip = socket.getInetAddress().getHostAddress();
      InputStream in = socket.getInputStream();
      String line = line(in, 2048);
      String[] first = line.split(" ");
      if (first.length != 3) throw new Bad(400, "Неверный запрос");
      r.method = first[0];
      String[] target = first[1].split("\\?", 2);
      r.path = target[0];
      int size = 0;
      while (!(line = line(in, 4096)).isEmpty()) {
        size += line.length();
        if (size > 8192) throw new Bad(413, "Запрос слишком большой");
        int colon = line.indexOf(':');
        if (colon < 1) throw new Bad(400, "Неверный заголовок");
        String key = line.substring(0, colon).toLowerCase(Locale.US);
        if (r.headers.containsKey(key) && key.equals("content-length"))
          throw new Bad(400, "Повторный размер запроса");
        r.headers.put(key, line.substring(colon + 1).trim());
      }
      if (r.headers.containsKey("transfer-encoding"))
        throw new Bad(400, "Кодирование не поддерживается");
      int length = 0;
      if (r.headers.containsKey("content-length"))
        length = Integer.parseInt(r.headers.get("content-length"));
      if (length < 0 || length > 16384) throw new Bad(413, "Запрос слишком большой");
      byte[] body = new byte[length];
      readFully(in, body);
      r.params = form(target.length == 2 ? target[1] : "");
      if (length > 0) r.params.putAll(form(new String(body, UTF8)));
      return r;
    }
  }

  static String line(InputStream in, int limit) throws IOException {
    ByteArrayOutputStream b = new ByteArrayOutputStream();
    int c;
    while ((c = in.read()) != -1) {
      if (c == 10) break;
      if (c != 13) b.write(c);
      if (b.size() > limit) throw new IOException("Header too long");
    }
    if (c == -1 && b.size() == 0) throw new EOFException();
    return new String(b.toByteArray(), UTF8);
  }

  static Map<String, String> form(String value) throws Exception {
    Map<String, String> p = new HashMap<String, String>();
    for (String part : value.split("&")) {
      if (part.isEmpty()) continue;
      String[] item = part.split("=", 2);
      p.put(
          URLDecoder.decode(item[0], "UTF-8"),
          item.length == 2 ? URLDecoder.decode(item[1], "UTF-8") : "");
    }
    return p;
  }

  static int readByte(InputStream in) throws IOException {
    int n = in.read();
    if (n < 0) throw new EOFException();
    return n;
  }

  static void readFully(InputStream in, byte[] b) throws IOException {
    int p = 0;
    while (p < b.length) {
      int n = in.read(b, p, b.length - p);
      if (n < 0) throw new EOFException();
      p += n;
    }
  }

  static byte[] readFile(File file, int max) throws IOException {
    FileInputStream in = new FileInputStream(file);
    try {
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      byte[] b = new byte[4096];
      int n;
      while ((n = in.read(b)) > 0) {
        out.write(b, 0, n);
        if (out.size() > max) throw new IOException("File too large");
      }
      return out.toByteArray();
    } finally {
      in.close();
    }
  }

  static void writeFile(File f, byte[] b) throws IOException {
    FileOutputStream out = new FileOutputStream(f);
    try {
      out.write(b);
      out.getFD().sync();
    } finally {
      out.close();
    }
  }

  static String quote(String s) {
    if (s == null) return "\"\"";
    StringBuilder b = new StringBuilder("\"");
    for (char c : s.toCharArray()) {
      if (c == '"' || c == '\\') b.append('\\').append(c);
      else if (c < 32) b.append(String.format(Locale.US, "\\u%04x", (int) c));
      else b.append(c);
    }
    return b.append('"').toString();
  }

  static String base64(byte[] bytes) {
    String chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    StringBuilder b = new StringBuilder();
    for (int i = 0; i < bytes.length; i += 3) {
      int n =
          ((bytes[i] & 255) << 16)
              | ((i + 1 < bytes.length ? bytes[i + 1] & 255 : 0) << 8)
              | (i + 2 < bytes.length ? bytes[i + 2] & 255 : 0);
      b.append(chars.charAt(n >>> 18))
          .append(chars.charAt((n >>> 12) & 63))
          .append(i + 1 < bytes.length ? chars.charAt((n >>> 6) & 63) : '=')
          .append(i + 2 < bytes.length ? chars.charAt(n & 63) : '=');
    }
    return b.toString();
  }

  static void frame(OutputStream out, int opcode, byte[] payload) throws IOException {
    int header = payload.length < 126 ? 2 : 4;
    byte[] data = new byte[header + payload.length];
    data[0] = (byte) (0x80 | opcode);
    if (header == 2) data[1] = (byte) payload.length;
    else {
      data[1] = 126;
      data[2] = (byte) (payload.length >>> 8);
      data[3] = (byte) payload.length;
    }
    System.arraycopy(payload, 0, data, header, payload.length);
    out.write(data);
    out.flush();
  }

  static void json(Socket s, int code, String body, String extra) throws IOException {
    response(s, code, "application/json; charset=utf-8", body.getBytes(UTF8), extra);
  }

  static void response(Socket s, int code, String type, byte[] body, String extra)
      throws IOException {
    String status =
        code == 200
            ? "OK"
            : code == 401
                ? "Unauthorized"
                : code == 403
                    ? "Forbidden"
                    : code == 404 ? "Not Found" : code == 429 ? "Too Many Requests" : "Error";
    String headers =
        "HTTP/1.1 "
            + code
            + " "
            + status
            + "\r\nContent-Type: "
            + type
            + "\r\nContent-Length: "
            + body.length
            + "\r\n"
            + "Connection: close\r\n"
            + "Cache-Control: no-store\r\n"
            + "X-Content-Type-Options: nosniff\r\n"
            + "X-Frame-Options: DENY\r\n"
            + "Referrer-Policy: no-referrer\r\n"
            + "Content-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src"
            + " 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none';"
            + " base-uri 'none'; form-action 'self'\r\n"
            + extra
            + "\r\n";
    OutputStream out = s.getOutputStream();
    out.write(headers.getBytes("US-ASCII"));
    out.write(body);
    out.flush();
  }

  public static void main(String[] args) throws Exception {
    if (args.length < 3) throw new IllegalArgumentException("root bind-ip port");
    new StationRemote(new File(args[0]), args[1], Integer.parseInt(args[2])).serve();
  }
}
