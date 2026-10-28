"""Build the reproducible DEX payload and self-contained AliceBridge and Windows installers."""
from pathlib import Path
import subprocess, zipfile, tarfile, io, gzip, hashlib, base64, os

ROOT = Path(__file__).resolve().parent
import shutil
JAVA_HOME = os.environ.get('JAVA_HOME')
def java_tool(name):
    filename = name + ('.exe' if os.name == 'nt' else '')
    value = str(Path(JAVA_HOME)/'bin'/filename) if JAVA_HOME else shutil.which(name)
    if not value: raise SystemExit('Install JDK 17+ and set JAVA_HOME or PATH')
    return value
TOOLS, SRC, DIST = ROOT/'tools', ROOT/'src', ROOT/'dist'
CLASSES = TOOLS/'classes'
TOOLS.mkdir(exist_ok=True)
CLASSES.mkdir(exist_ok=True)
for old in CLASSES.glob('*.class'): old.unlink()
DIST.mkdir(exist_ok=True)

subprocess.run([java_tool('javac'), '--release', '7', '-Xlint:-options', '-encoding', 'UTF-8', '-d', str(CLASSES), str(SRC/'StationRemote.java')], check=True)
with zipfile.ZipFile(TOOLS/'classes.jar', 'w', zipfile.ZIP_DEFLATED) as jar:
    for f in sorted(CLASSES.glob('*.class')):
        jar.write(f, f.name)
subprocess.run([java_tool('java'), '-cp', os.environ.get('R8_JAR', str(TOOLS/'r8.jar')), 'com.android.tools.r8.D8', '--min-api', '23', '--release', '--no-desugaring', '--output', str(DIST/'station-remote.jar'), str(TOOLS/'classes.jar')], check=True)

payload = io.BytesIO()
files = {'station-remote.jar': DIST/'station-remote.jar', 'index.html': SRC/'index.html'}
for name in ['remote-start.sh', 'install-on-speaker.sh']:
    if (SRC/name).exists(): files[name] = SRC/name
with tarfile.open(fileobj=payload, mode='w') as tar:
    for name, path in sorted(files.items()):
        data = path.read_bytes()
        info = tarfile.TarInfo(name); info.size = len(data); info.mode = 0o700 if name.endswith('.sh') else 0o600; info.mtime = 0
        tar.addfile(info, io.BytesIO(data))
compressed = gzip.compress(payload.getvalue(), mtime=0)
(DIST/'payload.tar.gz').write_bytes(compressed)
template = SRC/'install.template.ps1'
if template.exists():
    code = template.read_text(encoding='utf-8').replace('__PAYLOAD_SHA256__', hashlib.sha256(compressed).hexdigest()).replace('__PAYLOAD_BASE64__', base64.b64encode(compressed).decode())
    (DIST/'install-station-remote.ps1').write_text(code, encoding='utf-8-sig', newline='\n')
    (ROOT/'install.ps1').write_text(code, encoding='utf-8-sig', newline='\n')
shell_template=SRC/'install.template.sh'
if shell_template.exists():
    wrapped='\n'.join(__import__('textwrap').wrap(base64.b64encode(compressed).decode(),76))
    code=shell_template.read_text(encoding='utf-8').replace('__PAYLOAD_SHA256__',hashlib.sha256(compressed).hexdigest()).replace('__PAYLOAD_BASE64_WRAPPED__',wrapped)
    (DIST/'install-station-remote.sh').write_text(code,encoding='utf-8',newline='\n')
    (ROOT/'install.sh').write_text(code,encoding='utf-8',newline='\n')
print('DEX:', (DIST/'station-remote.jar').stat().st_size, 'bytes; payload:', len(compressed), 'bytes')
