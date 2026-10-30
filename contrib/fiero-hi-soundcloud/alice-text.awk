# Проверено: Fiero Hi (Станция Лайт, blackthorn), прошивка 0.369.1.50.*. Откат — README.md рядом.
# Разбор локального канала Алисы (127.0.0.1:9875) — то же, что alice-text.c из station2-media.
# На входе hex-дамп socat -x, на выходе по строке на фразу и «@state N» при смене состояния.
# Кадр = 4 байта длины (LE) + protobuf: поле 253 — тип (3 = состояние Алисы),
# поле 252 — вложенное: поле 1 — статус (3 = финальное), поле 2 — текст.
# Текст печатается escape-последовательностями \0ooo: awk не везде умеет выводить сырые байты,
# декодирует их printf '%b' в voice-soundcloud.sh.
BEGIN {
    for (i = 0; i < 256; i++) H[sprintf("%02x", i)] = i
    n = 0; p = 0; last = ""; last_at = 0; last_status = -1
}
/^ / {
    for (i = 1; i <= NF; i++) if ($i in H) B[n++] = H[$i]
    drain()
}

function drain(   len) {
    while (n - p >= 4) {
        len = B[p] + B[p + 1] * 256 + B[p + 2] * 65536 + B[p + 3] * 16777216
        if (len == 0 || len > 600000) { reset(); return }
        if (n - p - 4 < len) return
        handle(p + 4, p + 4 + len)
        p += 4 + len
    }
    if (p == n) reset()
}

function reset() { delete B; n = 0; p = 0 }

function varint(end,   x, m, b) {
    x = 0; m = 1
    while (P < end) {
        b = B[P++]
        x += (b % 128) * m; m *= 128
        if (b < 128) return x
    }
    BAD = 1; return 0
}

# Ищет поле на верхнем уровне [s, e): varint — в FV, length-delimited — FST (начало) и FL (длина)
function find(s, e, field, want_bytes,   tag, f, w, x) {
    P = s; BAD = 0
    while (P < e) {
        tag = varint(e); if (BAD) return 0
        f = int(tag / 8); w = tag % 8
        if (w == 0) {
            x = varint(e); if (BAD) return 0
            if (f == field && !want_bytes) { FV = x; return 1 }
        } else if (w == 1) { P += 8
        } else if (w == 5) { P += 4
        } else if (w == 2) {
            x = varint(e); if (BAD || x > e - P) return 0
            if (f == field && want_bytes) { FST = P; FL = x; return 1 }
            P += x
        } else return 0
    }
    return 0
}

function handle(s, e,   ss, se, status, i, c, txt, now, rid) {
    if (!find(s, e, 253, 0) || FV != 3) return
    if (!find(s, e, 252, 1)) return
    ss = FST; se = FST + FL
    # нулевое значение protobuf не передаёт: нет поля статуса — значит, статус 0
    status = find(ss, se, 1, 0) ? FV : 0
    if (status != last_status) { last_status = status; print "@state " status; fflush() }
    if (status != 3) return
    # окончательная фраза приходит несколько раз за 5–6 с — печатаем один раз на запрос
    # (поле 7 — id запроса); без id — по тексту, как в alice-text.c
    rid = ""
    if (find(ss, se, 7, 1)) for (i = FST; i < FST + FL; i++) rid = rid "." B[i]
    if (rid != "" && rid == last_rid) return
    if (!find(ss, se, 2, 1) || FL == 0) return
    txt = ""
    for (i = FST; i < FST + FL && i < FST + 1023; i++) {
        c = B[i]; if (c == 10 || c == 13) c = 32
        txt = txt sprintf("\\0%03o", c)
    }
    srand(); now = srand()
    # одна фраза приходит в нескольких кадрах — повтор в течение 3 с не печатаем
    if (rid == "" && txt == last && now - last_at < 3) return
    last = txt; last_at = now; last_rid = rid
    print txt; fflush()
}
