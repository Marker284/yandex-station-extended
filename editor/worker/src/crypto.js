// Шифрование сессии и state. Ключ — секрет SESSION_KEY (любая длинная строка).
// Сессия: AES-GCM(JSON), кодируется base64url. Сервер ничего не хранит.

const enc = new TextEncoder();
const dec = new TextDecoder();
const keyCache = new Map();

async function aesKey(secret) {
  if (!secret || secret.length < 32) throw new Error('SESSION_KEY не задан или короче 32 символов');
  if (!keyCache.has(secret)) {
    const raw = await crypto.subtle.digest('SHA-256', enc.encode(secret));
    keyCache.set(secret, crypto.subtle.importKey('raw', raw, 'AES-GCM', false, ['encrypt', 'decrypt']));
  }
  return keyCache.get(secret);
}

export function b64url(bytes) {
  let s = '';
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function fromB64url(str) {
  const s = atob(str.replace(/-/g, '+').replace(/_/g, '/'));
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

/** Шифрует объект; `kind` защищает от подмены state на сессию и наоборот. */
export async function seal(secret, kind, data, ttlSeconds) {
  const payload = { ...data, k: kind, exp: Math.floor(Date.now() / 1000) + ttlSeconds };
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(
    await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await aesKey(secret), enc.encode(JSON.stringify(payload))),
  );
  const out = new Uint8Array(iv.length + ct.length);
  out.set(iv);
  out.set(ct, iv.length);
  return b64url(out);
}

/** Расшифровывает; null — если подделано, просрочено или другого вида. */
export async function open(secret, kind, token) {
  try {
    const bytes = fromB64url(token);
    const pt = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: bytes.slice(0, 12) },
      await aesKey(secret),
      bytes.slice(12),
    );
    const data = JSON.parse(dec.decode(pt));
    if (data.k !== kind || typeof data.exp !== 'number' || data.exp < Date.now() / 1000) return null;
    return data;
  } catch {
    return null;
  }
}

export function randomId(len = 6) {
  const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
  const bytes = crypto.getRandomValues(new Uint8Array(len));
  return Array.from(bytes, (b) => alphabet[b % alphabet.length]).join('');
}

/** base64 ⇄ UTF-8 для GitHub API. */
export function utf8ToB64(text) {
  const bytes = enc.encode(text);
  let s = '';
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

export function b64ToUtf8(b64) {
  const s = atob(b64.replace(/\s/g, ''));
  const bytes = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) bytes[i] = s.charCodeAt(i);
  return dec.decode(bytes);
}

/** git blob SHA-1 — как считает сам Git. */
export async function gitBlobSha(text) {
  const body = enc.encode(text);
  const header = enc.encode(`blob ${body.length}\0`);
  const all = new Uint8Array(header.length + body.length);
  all.set(header);
  all.set(body, header.length);
  const h = new Uint8Array(await crypto.subtle.digest('SHA-1', all));
  return Array.from(h, (b) => b.toString(16).padStart(2, '0')).join('');
}
