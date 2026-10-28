"""Check the embedded release archive without running or extracting its code."""
import base64
import hashlib
import io
import re
import tarfile
import zipfile
from pathlib import Path

root = Path(__file__).resolve().parent
shell = (root / "install.sh").read_text(encoding="utf-8")
encoded = re.search(r"begin-base64 600 payload.tar.gz\n(.*?)\n====", shell, re.S).group(1)
payload = base64.b64decode("".join(encoded.split()), validate=True)
assert hashlib.sha256(payload).hexdigest() in shell, "Archive checksum differs"
assert "__PAYLOAD_" not in shell, "Unexpanded template"
ps = (root / "install.ps1").read_text(encoding="utf-8-sig")
assert base64.b64encode(payload).decode() in ps, "Installers embed different archives"
with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
    expected = {"station-remote.jar", "index.html", "remote-start.sh", "install-on-speaker.sh"}
    assert set(archive.getnames()) == expected, "Unexpected payload files"
    for member in archive.getmembers():
        assert member.isfile(), "Links are not allowed"
        data = archive.extractfile(member).read()
        if member.name.endswith(".jar"):
            with zipfile.ZipFile(io.BytesIO(data)) as jar:
                assert jar.read("classes.dex").startswith(b"dex\n"), "Missing DEX"
        else:
            assert data == (root / "src" / member.name).read_bytes(), member.name
print("OK: SHA-256, archive contents, sources and both installers match")
