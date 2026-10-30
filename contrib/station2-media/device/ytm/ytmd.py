# YouTube Music на Станции 2: плеер с очередью, управление через сокет и голосом.
#   ytmd.py            — демон (его запускает ap2.sh run-ytm)
#   ytmd.py ctl <cmd>  — команда демону: play <auto|track|album|playlist> <запрос>,
#                        pause, resume, next, prev, stop, status, queue
# yt-dlp держим в памяти: импорт стоит ~3 с, ссылка на трек из живого процесса — 2–5 с.
# Звук: куски m4a по HTTP -> ytm-dec (AAC -> S16LE) -> ytm-sink.sh (aplay -D youtube).
# Пауза гасит вывод целиком, чтобы распорядитель вернул звук Алисе; продолжение качает
# трек заново и пропускает уже сыгранное.
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

AP = '/data/local/opt/ap2'
B = AP + '/bin'
HERE = os.path.dirname(os.path.abspath(__file__))
SOCK = '/run/ytm.sock'
LOG = '/data/local/tmp/ap2/ytm.log'
CONF = AP + '/etc/ytm.conf'
BYTES_PER_SEC = 44100 * 4          # S16LE стерео
CHUNK = 2 << 20                    # кусок загрузки: без Range YouTube отдаёт медленно
MAX_BUFFER = 16 << 20              # больше вперёд не качаем
RECENT_SECONDS = 3600              # «пауза», «дальше» — нам, если играли в последний час
# Метка «очередь играет»: между треками ytm-sink.sh на миг пропадает, и без неё
# audio-owner.sh успевал бы вернуть звук Алисе. Пишем в неё время каждые 3 с.
MARK = '/tmp/ytm.playing'


def log(*a):
    with open(LOG, 'a') as f:
        f.write(time.strftime('%c') + ': ' + ' '.join(str(x) for x in a) + '\n')


def conf():
    c = {}
    try:
        with open(CONF) as f:
            for line in f:
                k, _, v = line.partition('=')
                if v and not k.strip().startswith('#'):
                    c[k.strip()] = v.strip()
    except OSError:
        pass
    return c


# ---------- ссылки на звук (yt-dlp) ----------

class Resolver:
    def __init__(self):
        sys.path.insert(0, os.path.join(HERE, 'lib'))
        import yt_dlp
        # visionos отдаёт m4a без JS-проверок: QuickJS на колонке решает их ~100 с на трек.
        # Переведённые субтитры, HLS и DASH не нужны, а их разбор стоит секунды.
        self.ydl = yt_dlp.YoutubeDL({
            'quiet': True, 'no_warnings': True, 'format': '140/bestaudio[ext=m4a]',
            'js_runtimes': {}, 'cachedir': os.path.join(HERE, 'cache'),
            'extractor_args': {'youtube': {'skip': ['translated_subs', 'hls', 'dash'],
                                           'player_skip': ['configs', 'js']}}})
        self.cache = {}
        self.lock = threading.Lock()

    def url(self, vid, fresh=False):
        with self.lock:
            hit = self.cache.get(vid)
            if hit and not fresh and hit[1] > time.time() + 600:
                return hit[0]
            info = self.ydl.extract_info('https://music.youtube.com/watch?v=' + vid, download=False)
            u = info['url']
            exp = urllib.parse.parse_qs(urllib.parse.urlparse(u).query).get('expire', ['0'])[0]
            self.cache[vid] = (u, int(exp) or time.time() + 3600)
            return u


# ---------- плеер ----------

class Player:
    def __init__(self, resolver):
        self.r = resolver
        self.lock = threading.RLock()
        self.queue = []          # [(videoId, название)]
        self.pos = 0
        self.state = 'stop'      # stop | play | pause
        self.offset = 0          # сыграно байт PCM в текущем треке
        self.gen = 0             # номер запуска: старые потоки видят, что их сменили
        self.procs = []
        self.last_active = 0
        self.fails = 0

    # --- управление ---

    def set_queue(self, items):
        with self.lock:
            self.queue = list(items)
            self._start(0, 0)

    def pause(self):
        with self.lock:
            if self.state == 'play':
                self._halt('pause')

    def resume(self):
        with self.lock:
            if self.state == 'pause' and self.queue:
                self._start(self.pos, self.offset)

    def next(self):
        with self.lock:
            if self.queue:
                self._advance()

    def prev(self):
        with self.lock:
            if not self.queue:
                return
            # как у плееров: дальше 5 с — сначала трек, иначе предыдущий
            back = 0 if self.offset > 5 * BYTES_PER_SEC else 1
            self._start(max(0, self.pos - back), 0)

    def stop(self):
        with self.lock:
            self._halt('stop')

    def status(self):
        with self.lock:
            if not self.queue:
                return self.state
            return '%s %d/%d %s %d:%02d' % (self.state, self.pos + 1, len(self.queue),
                                           self.queue[self.pos][1], *divmod(self.offset // BYTES_PER_SEC, 60))

    def recent(self):
        return self.state != 'stop' and time.time() - self.last_active < RECENT_SECONDS

    # --- внутреннее ---

    def _halt(self, state):
        self._kill()
        self.state = state
        try:
            os.unlink(MARK)
        except OSError:
            pass

    def _kill(self):
        self.gen += 1
        for p in self.procs:
            try:
                p.kill()
            except OSError:
                pass
        self.procs = []

    def _start(self, pos, offset):
        self._kill()
        self.pos, self.offset, self.state = pos, offset, 'play'
        self.last_active = time.time()
        threading.Thread(target=self._play, args=(self.gen, self.queue[pos][0], offset), daemon=True).start()

    def _advance(self):
        if self.pos + 1 >= len(self.queue):
            self._extend()
        if self.pos + 1 < len(self.queue):
            self._start(self.pos + 1, 0)
        else:
            self._halt('stop')

    def _extend(self):
        """Очередь кончилась — дописываем радио от последнего трека."""
        try:
            seen = {v for v, _ in self.queue}
            more = [x for x in __import__('ytmusic').radio(self.queue[-1][0]) if x[0] not in seen]
            self.queue += more
            log('очередь +%d (радио)' % len(more))
        except Exception as e:  # noqa: BLE001 — сеть, формат ответа: просто стоп
            log('радио не продлилось:', e)

    def _done(self, gen, ok):
        with self.lock:
            if gen != self.gen:
                return
            self.fails = 0 if ok else self.fails + 1
            if self.fails >= 3:
                log('три трека подряд не сыгрались — стоп')
                self._halt('stop')
                return
            self._advance()

    def _prefetch(self, gen):
        with self.lock:
            if gen != self.gen or self.pos + 1 >= len(self.queue):
                return
            vid = self.queue[self.pos + 1][0]
        try:
            self.r.url(vid)
        except Exception:  # noqa: BLE001 — разберётся, когда дойдёт очередь
            pass

    def _play(self, gen, vid, offset):
        title = dict(self.queue).get(vid, vid)
        if gen != self.gen:  # пока ждали очереди к yt-dlp, включили другое
            return
        try:
            url = self.r.url(vid)
        except Exception as e:  # noqa: BLE001
            log('нет ссылки:', title, '-', e)
            return self._done(gen, False)
        with self.lock:
            if gen != self.gen:
                return
            dec = subprocess.Popen([B + '/ytm-dec'], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            sink = subprocess.Popen(['/bin/sh', AP + '/ytm-sink.sh'], stdin=subprocess.PIPE)
            self.procs = [dec, sink]
        log('играет:', title, '(с %d с)' % (offset // BYTES_PER_SEC) if offset else '')
        fetch = threading.Thread(target=self._fetch, args=(gen, vid, url, dec), daemon=True)
        fetch.start()
        threading.Thread(target=self._prefetch, args=(gen,), daemon=True).start()
        played, skip, marked = 0, offset, 0
        try:
            while True:
                buf = dec.stdout.read(16384)
                if not buf:
                    break
                if skip:
                    cut = min(skip, len(buf))
                    skip -= cut
                    played += cut
                    buf = buf[cut:]
                    if not buf:
                        continue
                sink.stdin.write(buf)
                played += len(buf)
                if gen == self.gen:
                    self.offset = played
                    if time.time() - marked > 3:
                        marked = time.time()
                        with open(MARK, 'w') as f:
                            f.write('%d\n' % marked)
        except (BrokenPipeError, ValueError, OSError):
            pass
        for p in (dec, sink):
            try:
                p.stdin.close()
            except OSError:
                pass
        sink.wait()
        dec.wait()
        self._done(gen, played > offset)

    def _fetch(self, gen, vid, url, dec):
        """Качаем кусками в память и кормим декодер; держим не больше MAX_BUFFER вперёд."""
        chunks, cond, done = [], threading.Condition(), [False]

        def feed():
            while True:
                with cond:
                    while not chunks and not done[0]:
                        cond.wait()
                    if not chunks:
                        break
                    c = chunks.pop(0)
                    cond.notify_all()
                try:
                    dec.stdin.write(c)
                except (BrokenPipeError, ValueError, OSError):
                    break
            try:
                dec.stdin.close()
            except OSError:
                pass

        threading.Thread(target=feed, daemon=True).start()
        pos, refreshed = 0, False
        while gen == self.gen:
            with cond:
                while sum(map(len, chunks)) > MAX_BUFFER and gen == self.gen:
                    cond.wait(1)
            req = urllib.request.Request(url, headers={'Range': 'bytes=%d-%d' % (pos, pos + CHUNK - 1),
                                                       'User-Agent': 'Mozilla/5.0'})
            try:
                with urllib.request.urlopen(req, timeout=15) as r:
                    data = r.read()
                    total = int((r.headers.get('Content-Range') or '/0').rsplit('/', 1)[1] or 0)
            except urllib.error.HTTPError as e:
                if e.code == 416:
                    break
                if e.code == 403 and not refreshed:  # ссылка протухла — берём новую
                    refreshed = True
                    try:
                        url = self.r.url(vid, fresh=True)
                        continue
                    except Exception:  # noqa: BLE001
                        pass
                log('загрузка оборвалась:', e)
                break
            except OSError as e:
                log('загрузка оборвалась:', e)
                break
            with cond:
                chunks.append(data)
                cond.notify_all()
            pos += len(data)
            if not data or (total and pos >= total):
                break
        with cond:
            done[0] = True
            cond.notify_all()


# ---------- голос ----------

def not_music(q):
    """Умный дом, таймеры, громкость и прочее — не музыка, оставляем Алисе."""
    return re.search(r'свет|ламп|люстр|телевизор|кондиционер|обогрев|увлажн|розетк|пылесос|чайник|'
                     r'будильник|таймер|напомин|блютуз|bluetooth|радио|сказк|новост|погод|звук|'
                     r'громче|тише|громкост', q) is not None


YT = r'(ютуб\w*|youtube|you tube)( музык\w*| music)?'
GENERIC = {'музыку', 'музыка', 'что-нибудь', 'мою музыку', 'любимое', 'любимую музыку', 'любимые песни'}


class Voice:
    """Текст фраз из локального канала Алисы (127.0.0.1:9875) — то же, что alice-text.c:
    кадр = 4 байта длины (LE) + protobuf; поле 253 = 3 — состояние, в поле 252 статус (1)
    и текст (2). Статус 1 — слушает, 3 — фраза распознана, 0 — свободна."""

    def __init__(self, player, mode):
        self.p = player
        self.mode = mode           # all — все «поставь …», youtube — только «… в ютубе»
        self.status = -1
        self.last = ('', 0)
        self.duck_mark = 0

    @staticmethod
    def _varint(b, i):
        x = s = 0
        while True:
            c = b[i]
            i += 1
            x |= (c & 0x7f) << s
            if not c & 0x80:
                return x, i
            s += 7

    def _fields(self, b):
        i, out = 0, {}
        while i < len(b):
            tag, i = self._varint(b, i)
            f, t = tag >> 3, tag & 7
            if t == 0:
                v, i = self._varint(b, i)
            elif t == 1:
                v, i = None, i + 8
            elif t == 5:
                v, i = None, i + 4
            elif t == 2:
                n, i = self._varint(b, i)
                v, i = b[i:i + n], i + n
            else:
                raise ValueError('wire type %d' % t)
            out.setdefault(f, v)
        return out

    def run(self):
        while True:
            try:
                s = socket.create_connection(('127.0.0.1', 9875), timeout=None)
                f = s.makefile('rb')
                while True:
                    hdr = f.read(4)
                    if len(hdr) < 4:
                        break
                    n = struct.unpack('<I', hdr)[0]
                    if not 0 < n <= 600000:
                        break
                    frame = f.read(n)
                    if len(frame) < n:
                        break
                    try:
                        self._frame(frame)
                    except (ValueError, IndexError):
                        pass
                s.close()
            except OSError:
                pass
            time.sleep(2)

    def _frame(self, b):
        top = self._fields(b)
        if top.get(253) != 3 or not isinstance(top.get(252), bytes):
            return
        st = self._fields(top[252])
        status = st.get(1) or 0   # нулевое значение protobuf не передаёт
        if status != self.status:
            self.status = status
            self._duck(status == 1)
        text = st.get(2)
        if status != 3 or not isinstance(text, bytes) or not text:
            return
        t = text.decode('utf-8', 'replace').replace('\n', ' ').strip()
        if self.last[0] == t and time.time() - self.last[1] < 3:
            return
        self.last = (t, time.time())
        self.handle(t)

    def _duck(self, on):
        """Пока Алиса слушает, наша музыка тише (регулятор AP2 Duck, как у voice-spotify.sh)."""
        if not on and not self.duck_mark:
            return
        if on and self.p.state != 'play':
            return
        self.duck_mark = time.time() if on else 0
        subprocess.call([B + '/amixer', '-q', '-D', 'default', 'set', 'AP2 Duck', '25%' if on else '100%'],
                        env=dict(os.environ, ALSA_CONFIG_PATH=AP + '/etc/asound.conf'),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if on:  # страховка, если «свободна» не придёт
            mark = self.duck_mark
            threading.Timer(15, lambda: self.duck_mark == mark and self._duck(False)).start()

    def handle(self, text):
        t = text.lower().replace('ё', 'е')
        explicit = re.search(YT, t) is not None
        if not_music(t):
            return
        # \b: иначе «выключи музыку» нашлось бы как «включи музыку»
        m = re.search(r'\b(?:поставь|включи|играй|сыграй)\s+(.+)$', t)
        if m and not re.match(r'(дальше|следующ|предыдущ|на пауз|паузу)', m.group(1)):
            if self.mode != 'all' and not explicit:
                return
            q = re.sub(r'\s+пожалуйста$', '', m.group(1))
            q = re.sub(r'\s+(в|на|из|с|по)\s+' + YT + r'$', '', q).strip()
            mode = 'auto'
            for words, md in (('песню|трек|композицию', 'track'), ('альбом', 'album'),
                              ('плейлист|подборку', 'playlist')):
                mm = re.match(r'(?:%s)\s+(.+)$' % words, q)
                if mm:
                    mode, q = md, mm.group(1)
            if not q or q in GENERIC:
                return  # без входа в Google своей музыки нет — пусть играет Алиса
            log('голос: play', mode, q)
            threading.Thread(target=play_query, args=(self.p, mode, q), daemon=True).start()
            return
        if not (self.p.recent() or explicit):
            return
        for pat, act in ((r'\b(пауз|стоп|хватит|выключи)', self.p.pause), (r'\bпродолж', self.p.resume),
                         (r'\b(следующ|дальше)', self.p.next), (r'\b(предыдущ|назад)', self.p.prev)):
            if re.search(pat, t):
                log('голос:', act.__name__)
                act()
                return


# ---------- команды ----------

def play_query(player, mode, q):
    import ytmusic
    try:
        items = ytmusic.MODES[mode](q)
    except Exception as e:  # noqa: BLE001
        log('поиск не удался:', q, '-', e)
        return 'ошибка поиска: %s' % e
    if not items:
        log('не нашлось:', q)
        return 'не нашлось «%s»' % q
    player.set_queue(items)
    return 'очередь %d, первый: %s' % (len(items), items[0][1])


def serve(player):
    try:
        os.unlink(SOCK)
    except OSError:
        pass
    srv = socket.socket(socket.AF_UNIX)
    srv.bind(SOCK)
    srv.listen(4)
    while True:
        c, _ = srv.accept()
        try:
            args = c.makefile('r').readline().split(None, 2)
            cmd = args[0] if args else ''
            if cmd == 'play' and len(args) == 3 and args[1] in ('auto', 'track', 'album', 'playlist'):
                out = play_query(player, args[1], args[2].strip())
            elif cmd in ('pause', 'resume', 'next', 'prev', 'stop'):
                getattr(player, cmd)()
                out = 'ok'
            elif cmd == 'status':
                out = player.status()
            elif cmd == 'queue':
                with player.lock:
                    out = '\n'.join(('> ' if i == player.pos else '  ') + t
                                    for i, (_, t) in enumerate(player.queue)) or 'пусто'
            else:
                out = 'команды: play <auto|track|album|playlist> <запрос> | pause | resume | next | prev | stop | status | queue'
            c.sendall((out + '\n').encode())
        except OSError:
            pass
        finally:
            c.close()


def ctl(argv):
    s = socket.socket(socket.AF_UNIX)
    try:
        s.connect(SOCK)
    except OSError:
        print('ytmd не запущен', file=sys.stderr)
        return 1
    s.sendall((' '.join(argv) + '\n').encode())
    s.settimeout(30)
    sys.stdout.write(s.makefile('r').read())
    return 0


def main():
    try:
        if os.path.getsize(LOG) > 1 << 20:  # /data маленький
            open(LOG, 'w').close()
    except OSError:
        pass
    os.environ.setdefault('XDG_CACHE_HOME', os.path.join(HERE, 'cache'))
    sys.path.insert(0, HERE)
    t = time.time()
    player = Player(Resolver())
    log('ytmd запущен, yt-dlp загружен за %.1f с' % (time.time() - t))
    c = conf()
    voice = c.get('voice', 'auto')
    if voice == 'auto':  # «поставь …» без уточнения — Spotify, если у него есть голос
        voice = 'youtube' if os.path.exists(AP + '/etc/spotify-webapi.json') else 'all'
    if voice != 'off':
        log('голос:', voice)
        threading.Thread(target=Voice(player, voice).run, daemon=True).start()
    serve(player)


if __name__ == '__main__':
    if sys.argv[1:2] == ['ctl']:
        sys.exit(ctl(sys.argv[2:]))
    main()
