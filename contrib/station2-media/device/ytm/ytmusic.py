# Поиск и очереди YouTube Music через InnerTube (то, чем ходит music.youtube.com), без входа.
# Очередь — список (videoId, «название — исполнитель»). Ссылки на звук здесь не берём:
# это делает yt-dlp в ytmd.py.
import json
import urllib.request

API = 'https://music.youtube.com/youtubei/v1/'
CTX = {'client': {'clientName': 'WEB_REMIX', 'clientVersion': '1.20261026.01.00', 'hl': 'ru'}}
# Фильтры поиска music.youtube.com: только песни, только альбомы, только плейлисты
SONGS = 'EgWKAQIIAWoQEAMQBBAJEAoQBRAREBAQFQ=='
ALBUMS = 'EgWKAQIYAWoQEAMQBBAJEAoQBRAREBAQFQ=='
PLAYLISTS = 'EgeKAQQoAEABahAQAxAEEAkQChAFEBEQEBAV'


def call(endpoint, body):
    body = dict(body, context=CTX)
    req = urllib.request.Request(
        API + endpoint + '?prettyPrint=false', json.dumps(body).encode(),
        {'Content-Type': 'application/json', 'User-Agent': 'Mozilla/5.0',
         'Origin': 'https://music.youtube.com'})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)


def walk(o, key):
    """Все значения ключа key на любой глубине — ответы InnerTube глубокие и меняются."""
    if isinstance(o, dict):
        for k, v in o.items():
            if k == key:
                yield v
            else:
                yield from walk(v, key)
    elif isinstance(o, list):
        for v in o:
            yield from walk(v, key)


def runs(r):
    return ''.join(x.get('text', '') for x in (r or {}).get('runs', []))


def first(gen, default=None):
    return next(gen, default)


def panel(playlist_id, video_id=None):
    """Очередь, как её строит сам плеер: радио, подборка исполнителя, альбом, плейлист."""
    body = {'playlistId': playlist_id, 'isAudioOnly': True}
    if video_id:
        body['videoId'] = video_id
    out = []
    for it in walk(call('next', body), 'playlistPanelVideoRenderer'):
        if 'videoId' in it:
            out.append((it['videoId'], runs(it.get('title')) + ' — ' + runs(it.get('shortBylineText'))))
    return out


def radio(video_id):
    return panel('RDAMVM' + video_id, video_id)


def _rows(query, params):
    return walk(call('search', {'query': query, 'params': params}), 'musicResponsiveListItemRenderer')


def _row_title(it):
    cols = [runs(c['musicResponsiveListItemFlexColumnRenderer']['text'])
            for c in it.get('flexColumns', []) if 'musicResponsiveListItemFlexColumnRenderer' in c]
    return ' — '.join(cols[:2])


def song(query):
    """Песня и радио от неё."""
    for it in _rows(query, SONGS):
        vid = first(walk(it.get('playlistItemData', {}), 'videoId')) or first(walk(it, 'videoId'))
        if vid:
            return radio(vid) or [(vid, _row_title(it))]
    return []


def _row_playlist(query, params):
    for it in _rows(query, params):
        pid = first(x.get('playlistId') for x in walk(it, 'watchPlaylistEndpoint') if x.get('playlistId'))
        pid = pid or first(x.get('playlistId') for x in walk(it, 'watchEndpoint') if x.get('playlistId'))
        if pid:
            return panel(pid)
    return []


def album(query):
    return _row_playlist(query, ALBUMS)


def playlist(query):
    return _row_playlist(query, PLAYLISTS)


def auto(query):
    """«Поставь X»: если верхняя карточка поиска — исполнитель, то его песни вперемешку
    (плейлист RDAO…, кнопка «Перемешать» на его странице), иначе — песня и радио от неё."""
    d = call('search', {'query': query})
    card = first(walk(d, 'musicCardShelfRenderer'))
    if card:
        bid = first(walk(card.get('title', {}), 'browseId'), '')
        if bid.startswith('UC'):
            pid = first(x.get('playlistId') for x in walk(card, 'watchPlaylistEndpoint')
                        if x.get('playlistId', '').startswith('RDAO'))
            if pid:
                q = panel(pid)
                if q:
                    return q
    return song(query)


MODES = {'auto': auto, 'track': song, 'album': album, 'playlist': playlist}
