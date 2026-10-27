# Веб-редактор вики

Редактор на странице `https://hackalice.me/edit/`: человек правит Markdown в браузере, входит
через GitHub, а правка уходит Pull Request'ом в этот репозиторий. Git знать не нужно, права на
репозиторий тоже: редактор сам делает форк и ветку от имени пользователя.

```
браузер (hackalice.me/edit/)  ──Bearer-сессия──▶  Cloudflare Worker  ──OAuth-токен──▶  GitHub API
  CodeMirror + превью                              OAuth, форк, коммит, PR
```

- `web/` — фронтенд: CodeMirror 6, превью через markdown-it с плагинами под синтаксис вики
  (`!!!`, `???`, `===`, `{ #id }`, `++ctrl++`), стили Material. Собирается в `docs/assets/editor/`.
- `worker/` — бэкенд на Cloudflare Workers. Хранилища нет: токен GitHub лежит внутри
  зашифрованной сессии (AES-GCM) у пользователя в браузере. Сессией можно только читать вики
  и предлагать правки в `docs/` и `nav` — других операций Worker не делает.
- `shared/` — общий код: поиск ключей/токенов/MAC (`scan.js`), пути и правка `nav` (`paths.js`).
- `../overrides/` — шаблоны темы: карандаш и карточка «Нашли ошибку?» ведут в редактор,
  страница `/edit/`. `../docs/javascripts/editor-entry.js` — кнопка над выделенным текстом.

Пока в `mkdocs.yml` пуст `extra.editor.api`, сайт ведёт себя как раньше (карандаш → GitHub).

## Что умеет

- правка любой страницы и создание новой (с пунктом в меню раздела);
- превью рядом, только исходник или только превью; синхронная прокрутка;
- тулбар: заголовок, жирный, курсив, ссылка, код, списки, заметки `!!!`/`???`, блок команд,
  вкладки, таблица, картинки (кнопкой, из буфера, перетаскиванием), клавиши `++ctrl+c++`;
- выделили текст на странице → редактор открывается на этом месте;
- черновик в браузере (переживает перезагрузку), подсветка изменённых строк, «+N −M»;
- поиск личных данных в добавленных строках: в редакторе, на сервере и в CI;
- конфликт (страницу изменили, пока правили) — правка переносится на свежую версию;
- доработка своего PR после ревью — новым коммитом в ту же ветку;
- экран «Готово» со статусом проверок и ревью.

## Запуск в продакшене

### 1. GitHub OAuth App

https://github.com/settings/applications/new (или в организации — Settings → Developer settings):

- **Application name:** `hackalice.me — редактор вики`
- **Homepage URL:** `https://hackalice.me`
- **Authorization callback URL:** `https://<адрес Worker>/auth/callback`
  (например, `https://yse-wiki-editor.<аккаунт>.workers.dev/auth/callback`)

Сохраните **Client ID** и создайте **Client secret**.

### 2. Cloudflare Worker

```sh
cd editor/worker
npx wrangler@4 login
# Client ID — в wrangler.toml, [vars] GITHUB_CLIENT_ID
npx wrangler@4 secret put GITHUB_CLIENT_SECRET
openssl rand -base64 48 | npx wrangler@4 secret put SESSION_KEY
npx wrangler@4 deploy
```

Проверка: `curl https://<адрес Worker>/health` → `{"ok":true,…}`.

Свой поддомен (`edit-api.hackalice.me`) — раскомментируйте `routes` в `wrangler.toml`; для этого
зона `hackalice.me` должна быть в Cloudflare. Без него работает адрес `*.workers.dev`.

Автодеплой: секрет репозитория `CLOUDFLARE_API_TOKEN` (шаблон «Edit Cloudflare Workers») —
тогда `.github/workflows/editor-worker.yml` деплоит Worker при изменениях в `editor/worker/`.

### 3. Включить на сайте

В `mkdocs.yml`:

```yaml
extra:
  editor:
    api: "https://<адрес Worker>"
```

После пуша в `main` сайт пересоберётся с редактором.

`SESSION_KEY` можно сменить в любой момент — все войдут заново.

## Разработка

```sh
cd editor
npm ci
npm test                       # общий код, Worker на фейковом GitHub, markdown
npm run dev:worker -- --fake   # Worker на :8787 + фейковый GitHub из файлов репозитория
npm run watch                  # пересборка редактора в docs/assets/editor/
# во втором терминале, в корне репозитория, с extra.editor.api: http://127.0.0.1:8787:
mkdocs serve
```

С `--fake` вход проходит сразу как `@tester`, PR создаются в памяти. Для настоящего GitHub —
OAuth App с callback `http://127.0.0.1:8787/auth/callback` и переменные `GITHUB_CLIENT_ID`,
`GITHUB_CLIENT_SECRET`, `SESSION_KEY` для `npm run dev:worker`.

Сквозной тест в браузере (Playwright, нужен Chromium):

```sh
npm i --no-save playwright && npx playwright install chromium
npm run build && (cd .. && mkdocs build)   # с extra.editor.api: http://127.0.0.1:8787
node test/e2e.mjs ./shots                  # скриншоты каждого шага — в ./shots
```

## API Worker

| Метод | Что делает |
|---|---|
| `GET /auth/login?origin&mode=popup\|redirect&return` | вход через GitHub |
| `GET /auth/callback` | обмен кода на токен, сессия — в окно редактора (`postMessage`) |
| `POST /auth/logout` | отзыв токена у GitHub |
| `GET /api/me` | профиль |
| `GET /api/file?path=docs/…md[&pr=N]` | текст страницы и её `sha` (из `main` или из ветки своего PR) |
| `GET /api/sections` | разделы `nav` для новой страницы |
| `GET /api/prs?path=` | свои открытые PR по странице |
| `GET /api/pr?number=` | статус PR и проверок |
| `POST /api/submit` | `{ title, description, tested, page: { path, content, baseSha }, images: [{ path, base64 }], newPage?: { section, title }, pr? }` → коммит и PR |

Ограничения: только `docs/**/*.md` (латиница), картинки PNG/JPG/WebP/GIF до 2 МБ в
`docs/assets/images/` без перезаписи существующих, страница до 300 КБ, `mkdocs.yml` — только
добавление пункта в раздел `nav`. Запросы с чужих сайтов (`Origin` не из `ALLOWED_ORIGINS`)
отклоняются.
