#!/bin/sh
# Spotify Web API с колонки: найти и включить на этой колонке, пауза, дальше, назад.
#   spotify-api.sh play <auto|track|album|playlist> <запрос>
#   spotify-api.sh liked | pause | resume | next | prev | devices
# Ключи — etc/spotify-webapi.json ({client_id, refresh_token}), их кладёт
# spotify-webapi-login.sh с Mac. Запросы идут через XKeen на роутере, как и сам Spotify.
. /data/local/opt/ap2/common.sh
CFG=$E/spotify-webapi.json
TOK=/tmp/spotify-webapi.token
JQ=$B/jq
API=https://api.spotify.com/v1

curl_() { "$B/curl" -sS -m 10 --cacert "$AP/lib/ca-certificates.crt" "$@"; }

# Токен доступа живёт час: держим его в /tmp вместе со временем истечения
access_token() {
  if [ -s "$TOK" ] && [ "$(date +%s)" -lt "$(cut -d' ' -f1 "$TOK")" ]; then
    cut -d' ' -f2 "$TOK"
    return 0
  fi
  [ -s "$CFG" ] || { echo "нет $CFG — сначала spotify-webapi-login.sh" >&2; return 1; }
  cid=$("$JQ" -r .client_id "$CFG")
  rt=$("$JQ" -r .refresh_token "$CFG")
  resp=$(curl_ -X POST https://accounts.spotify.com/api/token \
    -d grant_type=refresh_token --data-urlencode "refresh_token=$rt" -d "client_id=$cid") || return 1
  at=$(echo "$resp" | "$JQ" -r '.access_token // empty')
  [ -n "$at" ] || { echo "токен не выдан: $resp" >&2; return 1; }
  # С PKCE Spotify меняет refresh_token при обновлении — новый сохраняем
  nrt=$(echo "$resp" | "$JQ" -r '.refresh_token // empty')
  if [ -n "$nrt" ] && [ "$nrt" != "$rt" ]; then
    (umask 077; "$JQ" --arg r "$nrt" '.refresh_token = $r' "$CFG" > "$CFG.new") && mv "$CFG.new" "$CFG"
  fi
  ttl=$(echo "$resp" | "$JQ" -r '.expires_in // 3600')
  (umask 077; echo "$(( $(date +%s) + ttl - 60 )) $at" > "$TOK")
  echo "$at"
}

api() { # метод путь [тело JSON]
  at=$(access_token) || return 1
  if [ -n "${3:-}" ]; then
    curl_ -X "$1" -H "Authorization: Bearer $at" -H "Content-Type: application/json" -d "$3" "$API$2"
  else
    curl_ -X "$1" -H "Authorization: Bearer $at" "$API$2"
  fi
}

device_id() {
  api GET /me/player/devices |
    "$JQ" -r --arg n "$SPOTIFY_NAME" '.devices[]? | select(.name == $n) | .id' | head -1
}

play_body() { # body JSON -> включить на этой колонке
  dev=$(device_id)
  [ -n "$dev" ] || { echo "колонка «$SPOTIFY_NAME» не видна в Spotify" >&2; return 1; }
  out=$(api PUT "/me/player/play?device_id=$dev" "$1")
  [ -z "$out" ] || { echo "$out" >&2; return 1; }
}

# Строчные для кириллицы и латиницы: ascii_downcase в jq кириллицу не трогает
JQ_LC='def lc: explode | map(if (. >= 65 and . <= 90) or (. >= 1040 and . <= 1071) then . + 32
  elif . == 1025 then 1105 else . end) | implode;'

pick_uri() { # mode query <- JSON поиска на stdin
  "$JQ" -r --arg mode "$1" --arg q "$2" "$JQ_LC"'
    ($q | lc) as $lq
    | (.tracks.items[0] // null) as $t
    | (.artists.items[0] // null) as $a
    | if $mode == "album" then (.albums.items[0].uri // empty)
      elif $mode == "playlist" then ([.playlists.items[]? | select(. != null)][0].uri // empty)
      elif $t != null and ($mode == "track" or ($lq | contains($t.name | lc))) then $t.uri
      elif $a != null and ($t == null or ([$t.artists[].id] | index($a.id)) != null) then $a.uri
      elif $t != null then $t.uri
      else empty end'
}

# Падежное окончание мешает поиску («маркула» -> «маркул»)
strip_case() { echo "$1" | sed -E 's/(ой|ом|ою|а|у|ю|я|ы|и|е)$//'; }

play_query() { # mode query
  mode=$1; q=$2
  case "$mode" in
    album) types=album ;;
    playlist) types=playlist ;;
    *) types=artist,track ;;
  esac
  for try in "$q" "$(strip_case "$q")"; do
    enc=$(printf '%s' "$try" | "$JQ" -sRr @uri)
    uri=$(api GET "/search?q=$enc&type=$types&limit=3&market=from_token" | pick_uri "$mode" "$try")
    [ -n "$uri" ] && break
  done
  [ -n "$uri" ] || { echo "в Spotify не нашлось «$q»" >&2; return 1; }
  case "$uri" in
    spotify:track:*) play_body "$("$JQ" -nc --arg u "$uri" '{uris: [$u]}')" ;;
    *) play_body "$("$JQ" -nc --arg u "$uri" '{context_uri: $u}')" ;;
  esac && echo "$uri"
}

# «Поставь музыку» — любимые треки; если их нельзя включить контекстом, то списком
play_liked() {
  me=$(api GET /me | "$JQ" -r '.id // empty')
  [ -n "$me" ] || return 1
  play_body "$("$JQ" -nc --arg u "spotify:user:$me:collection" '{context_uri: $u}')" 2>/dev/null && return 0
  uris=$(api GET "/me/tracks?limit=50" | "$JQ" -c '[.items[].track.uri]')
  play_body "$("$JQ" -nc --argjson u "$uris" '{uris: $u}')"
}

case "${1:-}" in
  play)    play_query "${2:-auto}" "${3:?запрос}" ;;
  liked)   play_liked ;;
  pause)   api PUT /me/player/pause ;;
  resume)  api PUT /me/player/play ;;
  next)    api POST /me/player/next ;;
  prev)    api POST /me/player/previous ;;
  devices) api GET /me/player/devices | "$JQ" -r '.devices[]? | "\(.name)\t\(.is_active)\t\(.id)"' ;;
  *) echo "usage: $0 play <auto|track|album|playlist> <запрос> | liked | pause | resume | next | prev | devices" >&2
     exit 1 ;;
esac
