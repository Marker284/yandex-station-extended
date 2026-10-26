// alice-text: печатает финальный текст распознанной команды из локального IPC Алисы
// (127.0.0.1:9875 на самой колонке), по строке на фразу.
// Кадр = 4 байта длины (LE) + protobuf (разбор — docs/09-voice.md derangedabbot):
//   поле 253 — тип сообщения, 3 = состояние Алисы;
//   поле 252 — вложенное сообщение: поле 1 — статус (3 = финальное), поле 2 — текст.
// Одна фраза приходит в нескольких кадрах — повтор той же строки в течение 3 с не печатаем.
// Смену статуса (слушает, думает, свободна) печатаем строкой «@state N» — по ней
// voice-spotify.sh приглушает музыку, пока Алиса слушает.
#include <arpa/inet.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define PORT 9875
#define MAX_FRAME 600000
#define MAX_TEXT 1024
#define REPEAT_SECONDS 3

static int read_full(int fd, void *buf, size_t n) {
  size_t got = 0;
  while (got < n) {
    ssize_t r = read(fd, (char *)buf + got, n - got);
    if (r <= 0) return -1;
    got += (size_t)r;
  }
  return 0;
}

static int read_varint(const uint8_t **p, const uint8_t *end, uint64_t *v) {
  uint64_t x = 0;
  for (int shift = 0; *p < end && shift < 64; shift += 7) {
    uint8_t b = *(*p)++;
    x |= (uint64_t)(b & 0x7f) << shift;
    if (!(b & 0x80)) {
      *v = x;
      return 0;
    }
  }
  return -1;
}

// Ищет поле field на верхнем уровне сообщения [p, end). Для varint возвращает значение
// в *v, для length-delimited — указатель и длину. 0 — найдено, -1 — нет или битые данные.
static int find_field(const uint8_t *p, const uint8_t *end, uint64_t field, int want_bytes,
                      uint64_t *v, const uint8_t **data) {
  while (p < end) {
    uint64_t tag, x;
    if (read_varint(&p, end, &tag)) return -1;
    uint64_t f = tag >> 3;
    switch (tag & 7) {
      case 0:
        if (read_varint(&p, end, &x)) return -1;
        if (f == field && !want_bytes) {
          *v = x;
          return 0;
        }
        break;
      case 1:
        if (end - p < 8) return -1;
        p += 8;
        break;
      case 5:
        if (end - p < 4) return -1;
        p += 4;
        break;
      case 2:
        if (read_varint(&p, end, &x) || x > (uint64_t)(end - p)) return -1;
        if (f == field && want_bytes) {
          *data = p;
          *v = x;
          return 0;
        }
        p += x;
        break;
      default:
        return -1;
    }
  }
  return -1;
}

static void handle_frame(const uint8_t *buf, uint32_t n, char *last, time_t *last_at,
                         int64_t *last_status) {
  uint64_t type, state_len, status, text_len;
  const uint8_t *state, *text;
  if (find_field(buf, buf + n, 253, 0, &type, NULL) || type != 3) return;
  if (find_field(buf, buf + n, 252, 1, &state_len, &state)) return;
  // Нулевое значение protobuf не передаёт: нет поля статуса — значит, статус 0
  if (find_field(state, state + state_len, 1, 0, &status, NULL)) status = 0;
  if ((int64_t)status != *last_status) {
    *last_status = (int64_t)status;
    printf("@state %llu\n", (unsigned long long)status);
    fflush(stdout);
  }
  if (status != 3) return;
  if (find_field(state, state + state_len, 2, 1, &text_len, &text) || text_len == 0) return;

  char line[MAX_TEXT];
  size_t len = text_len < MAX_TEXT - 1 ? text_len : MAX_TEXT - 1;
  memcpy(line, text, len);
  line[len] = '\0';
  for (size_t i = 0; i < len; i++)
    if (line[i] == '\n' || line[i] == '\r') line[i] = ' ';

  time_t now = time(NULL);
  if (strcmp(line, last) == 0 && now - *last_at < REPEAT_SECONDS) return;
  strcpy(last, line);
  *last_at = now;
  printf("%s\n", line);
  fflush(stdout);
}

int main(void) {
  uint8_t *buf = malloc(MAX_FRAME);
  char last[MAX_TEXT] = "";
  time_t last_at = 0;
  int64_t last_status = -1;
  if (!buf) return 1;

  for (;;) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(PORT)};
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (fd < 0 || connect(fd, (struct sockaddr *)&addr, sizeof addr) < 0) {
      if (fd >= 0) close(fd);
      sleep(2);
      continue;
    }
    for (;;) {
      uint8_t hdr[4];
      if (read_full(fd, hdr, sizeof hdr)) break;
      uint32_t n = hdr[0] | hdr[1] << 8 | hdr[2] << 16 | (uint32_t)hdr[3] << 24;
      if (n == 0 || n > MAX_FRAME || read_full(fd, buf, n)) break;
      handle_frame(buf, n, last, &last_at, &last_status);
    }
    close(fd);
    sleep(2);
  }
}
