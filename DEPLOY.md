# Yandex Station Lite Wiki — запуск и деплой

Движок: **Material for MkDocs** (9.7.7, MkDocs 1.6.1). Контент — Markdown в `docs/`.

## Локально (dev, с live-reload)

```sh
cd ~/yandex-wiki
python3 -m venv venv              # один раз
./venv/bin/pip install -r requirements.txt
./venv/bin/mkdocs serve -a 127.0.0.1:8000
# → http://127.0.0.1:8000
```

## Веб-редактор

Страница `/edit/` — редактор вики (исходники в `editor/`, настройка — `editor/README.md`).
Его сборка кладёт `docs/assets/editor/`, поэтому перед `mkdocs build` / `serve`:

```sh
cd editor && npm ci && npm run build && cd ..
```

В CI это делает `deploy.yml`. Пока в `mkdocs.yml` пуст `extra.editor.api`, кнопки правки
ведут на GitHub, как раньше.

## Сборка статики

```sh
./venv/bin/mkdocs build           # кладёт готовый сайт в ./site/
```
`site/` — это обычная статика (HTML/CSS/JS), ей не нужен Python на проде.

## Перенос на VPS

Три варианта, от простого к «правильному».

### 1. Статика за nginx (рекомендуется)

Собрать локально и залить `site/`:

```sh
./venv/bin/mkdocs build
rsync -az --delete site/ user@vps:/var/www/yandex-wiki/
```

nginx:

```nginx
server {
    listen 80;
    server_name wiki.example.com;
    root /var/www/yandex-wiki;
    index index.html;
    location / { try_files $uri $uri/ =404; }
}
```

Потом `certbot --nginx -d wiki.example.com` для HTTPS.

### 2. Собирать на самом VPS

```sh
git clone <repo> yandex-wiki && cd yandex-wiki
python3 -m venv venv && ./venv/bin/pip install -r requirements.txt
./venv/bin/mkdocs build
# раздать ./site/ через nginx (root = .../site)
```

### 3. Docker

```dockerfile
FROM squidfunk/mkdocs-material:9.7.7
WORKDIR /docs
# mkdocs serve -a 0.0.0.0:8000  (для билда: mkdocs build)
```
```sh
docker run --rm -v "$PWD":/docs -p 8000:8000 squidfunk/mkdocs-material:9.7.7
```

## Правка `site_url` для прода

Перед билдом на прод добавь в `mkdocs.yml`:

```yaml
site_url: https://wiki.example.com/
```
(нужно для корректных canonical-ссылок, sitemap и соцкарточек).

## Community-правки

Контент — plain Markdown в `docs/`, навигация — в `mkdocs.yml` (`nav:`). Правки
принимаются через PR на GitHub; CI может собирать и деплоить `site/` автоматически
(GitHub Pages / rsync на VPS).

## Заметка про будущее

Material for MkDocs с ноября 2025 в режиме поддержки (фиксы до ноября 2026),
команда делает новый движок **Zensical**. Для нас это не блокер: 9.7.7 стабилен.
Если захотим in-browser редактирование с аккаунтами — альтернатива **Wiki.js**
(Node + Postgres, тяжелее переносить).
