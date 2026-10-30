# SPDX-License-Identifier: GPL-3.0-or-later
"""Append two explicit components to the pinned APK's binary Android manifest.

Existing string indices, resources, permissions and attributes are preserved.
The exported receiver requires the companion's signature permission. The worker
service is private. There are no implicit intent filters.
"""
import struct


def patch_manifest(data):
    chunks = []
    offset = 8
    while offset < len(data):
        kind, header, size = struct.unpack_from('<HHI', data, offset)
        assert size >= header >= 8
        chunks.append([kind, data[offset:offset+size]])
        offset += size
    assert offset == len(data) and chunks[0][0] == 1
    pool = chunks[0][1]
    _, header, _, count, styles, flags, start, styles_start = struct.unpack_from('<HHIIIIII', pool)
    assert header == 28 and styles == 0 and styles_start == 0
    utf8 = bool(flags & 0x100)

    def read_length(buf, at, wide):
        if wide:
            value = struct.unpack_from('<H', buf, at)[0]
            return (((value & 0x7fff) << 16) | struct.unpack_from('<H', buf, at+2)[0], at+4) if value & 0x8000 else (value, at+2)
        value = buf[at]
        return (((value & 0x7f) << 8) | buf[at+1], at+2) if value & 0x80 else (value, at+1)

    strings = []
    offsets = list(struct.unpack_from('<%dI' % count, pool, header))
    for at in offsets:
        at += start
        length, at = read_length(pool, at, not utf8)
        if utf8:
            length, at = read_length(pool, at, False)
            strings.append(pool[at:at+length].decode('utf-8'))
        else:
            strings.append(pool[at:at+length*2].decode('utf-16-le'))
    raw = bytearray(pool[start:])

    def index(value):
        if value in strings:
            return strings.index(value)
        encoded = value.encode('utf-8' if utf8 else 'utf-16-le')
        units = len(value.encode('utf-16-le')) // 2
        assert units < 128 and (not utf8 or len(encoded) < 128)
        offsets.append(len(raw))
        raw.extend(bytes([units, len(encoded)])+encoded+b'\0' if utf8 else struct.pack('<H', units)+encoded+b'\0\0')
        strings.append(value)
        return len(strings)-1

    ns = strings.index('http://schemas.android.com/apk/res/android')
    no_index = 0xffffffff

    def component(tag, name, exported, permission=None):
        tag = index(tag)
        attrs = [(index('name'), 3, index(name)), (index('exported'), 0x12, int(exported))]
        if permission:
            attrs.append((index('permission'), 3, index(permission)))
        start_tag = struct.pack('<HHIIIIIHHHHHH', 0x102, 16, 36+20*len(attrs), 0, no_index, no_index, tag, 20, 20, len(attrs), 0, 0, 0)
        for name, kind, value in attrs:
            start_tag += struct.pack('<IIIHBBI', ns, name, value if kind == 3 else no_index, 8, 0, kind, value)
        return start_tag+struct.pack('<HHIIIII', 0x103, 16, 24, 0, no_index, no_index, tag)

    additions = component('receiver', 'org.schabi.newpipe.station.StationSoundCloudReceiver', True, 'me.hackalice.station.soundcloud.CONTROL')
    additions += component('service', 'org.schabi.newpipe.station.StationSoundCloudService', False)
    raw.extend(b'\0' * (-len(raw) % 4))
    new_start = 28+4*len(strings)
    chunks[0][1] = struct.pack('<HHIIIIII', 1, 28, new_start+len(raw), len(strings), 0, flags & ~1, new_start, 0)+struct.pack('<%dI' % len(offsets), *offsets)+raw
    inserted = False
    for i, (kind, chunk) in enumerate(chunks):
        if kind == 0x103 and strings[struct.unpack_from('<I', chunk, 20)[0]] == 'application':
            chunks.insert(i, [0, additions]); inserted = True; break
    assert inserted
    content = b''.join(chunk for _, chunk in chunks)
    return struct.pack('<HHI', 3, 8, 8+len(content))+content
