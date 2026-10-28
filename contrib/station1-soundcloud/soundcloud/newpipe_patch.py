# SPDX-License-Identifier: GPL-3.0-or-later
"""Reproduce the Station 1 loading-animation workaround in the pinned official APK.

Corresponding source change in NewPipe v0.29.1, GPL-3.0-or-later:
app/src/main/java/org/schabi/newpipe/ktx/View.kt:
fun View.animateHideRecyclerViewAllowingScrolling() {
    animate().cancel()
    alpha = 0f
}
https://github.com/TeamNewPipe/NewPipe/tree/v0.29.1

Only the exact APK hash below is supported. R8 placed that function in AppKt.
Replace its 22-unit method body, retaining its size, branch/debug offsets and
register layout. The optional bridge adds two explicit Android components and
a DEX with their GPL source from newpipe/. Its receiver requires the companion's
signature permission. Network code, HTTPS checks and existing resources remain
unchanged. Both APKs must use the same separate local signing key.
"""
from pathlib import Path
import hashlib,struct,zipfile,zlib

OFFICIAL_SHA256='18447bfb1e06d113edc88df93f471827280de06f6f3d4dc42f56f28b9c1bab79'

def patch(source, destination, bridge_dex=None):
    source=Path(source);destination=Path(destination)
    assert hashlib.sha256(source.read_bytes()).hexdigest()==OFFICIAL_SHA256, 'Unexpected upstream APK; refusing to patch'
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination,'w') as result:
        for entry in original.infolist():
            name=entry.filename
            if name.upper()=='META-INF/MANIFEST.MF' or name.upper().startswith('META-INF/') and name.upper().endswith(('.SF','.RSA','.DSA','.EC')):continue
            data=original.read(entry)
            if name=='AndroidManifest.xml' and bridge_dex is not None:
                from manifest_patch import patch_manifest
                data=patch_manifest(data)
            if name=='classes.dex':
                data=bytearray(data)
                code=5639648
                assert struct.unpack_from('<HHHH',data,code)==(3,1,3,0), 'Unexpected animation method'
                assert struct.unpack_from('<I',data,code+12)[0]==22
                units=[0x106e,3286,2,0x000c,0x106e,3780,0,0x0015,0x0000,0x206e,3510,2,0x000e]+[0]*9
                data[code+16:code+16+44]=struct.pack('<22H',*units)
                data[12:32]=hashlib.sha1(data[32:]).digest()
                data[8:12]=struct.pack('<I',zlib.adler32(data[12:])&0xffffffff)
                data=bytes(data)
            result.writestr(entry,data)
        if bridge_dex is not None:
            number=2
            while 'classes%d.dex' % number in original.namelist(): number+=1
            result.writestr('classes%d.dex' % number,Path(bridge_dex).read_bytes())
