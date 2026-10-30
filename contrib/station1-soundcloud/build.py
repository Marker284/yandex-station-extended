from pathlib import Path
import subprocess, os, json, secrets, zipfile,base64,hashlib,shutil
import urllib.request,sys

def encode_payload(data):
 encoded=base64.b64encode(data).decode()
 return '\n'.join(encoded[i:i+76] for i in range(0,len(encoded),76))

ROOT=Path(__file__).resolve().parent
TOOLS=ROOT/'tools'/'soundcloud'
SOURCE=ROOT/'soundcloud'
DIST=ROOT/'dist'
TOOLS.mkdir(parents=True,exist_ok=True);DIST.mkdir(parents=True,exist_ok=True)
suffix='.exe' if os.name=='nt' else ''
java_home=os.environ.get('JAVA_HOME')
if java_home: JAVA=Path(java_home)/'bin'
elif shutil.which('javac'): JAVA=Path(shutil.which('javac')).resolve().parent
else: raise SystemExit('Set JAVA_HOME to JDK 17')
SDK=Path(os.environ.get('ANDROID_SDK_ROOT',os.environ.get('ANDROID_HOME',str(ROOT/'tools'/'android-sdk'))))
build_tools=sorted((SDK/'build-tools').glob('*'),key=lambda p:[int(x) if x.isdigit() else 0 for x in p.name.split('.')])
BT=build_tools[-1] if build_tools else TOOLS
AAPT=BT/('aapt2'+suffix)
ANDROID=Path(os.environ.get('STATION_ANDROID_JAR',str(SDK/'platforms'/'android-23'/'android.jar')))
if not ANDROID.exists():
 platforms=sorted((SDK/'platforms').glob('android-*/android.jar'),key=lambda p:int(p.parent.name.split('-')[-1]))
 ANDROID=platforms[-1] if platforms else TOOLS/'android.jar'
R8=Path(os.environ.get('STATION_R8_JAR',str(BT/'lib'/'d8.jar')))
if not R8.exists(): R8=ROOT/'tools'/'r8.jar'
CLASSES=TOOLS/'classes-v2';CLASSES.mkdir(exist_ok=True)
DEX=TOOLS/'dex';DEX.mkdir(exist_ok=True)
subprocess.run([str(AAPT),'compile','--dir',str(SOURCE/'res'),'-o',str(TOOLS/'resources.zip')],check=True)
unsigned=TOOLS/'soundcloud-unsigned.apk'
subprocess.run([str(AAPT),'link','-I',str(ANDROID),'--manifest',str(SOURCE/'AndroidManifest.xml'),'-o',str(unsigned),str(TOOLS/'resources.zip')],check=True)
subprocess.run([str(JAVA/('javac'+suffix)),'--release','7','-Xlint:-options','-encoding','UTF-8','-cp',str(ANDROID),'-d',str(CLASSES)]+[str(p) for p in (SOURCE/'src').glob('*.java')],check=True)
with zipfile.ZipFile(TOOLS/'classes.jar','w') as z:
 for p in CLASSES.rglob('*.class'):z.write(p,p.relative_to(CLASSES).as_posix())
subprocess.run([str(JAVA/('java'+suffix)),'-cp',str(R8),'com.android.tools.r8.D8','--release','--min-api','23','--no-desugaring','--lib',str(ANDROID),'--output',str(DEX),str(TOOLS/'classes.jar')],check=True)
with zipfile.ZipFile(unsigned,'a') as z:z.write(DEX/'classes.dex','classes.dex')
private=Path.home()/'.codex'/'buildkeys';private.mkdir(parents=True,exist_ok=True,mode=0o700)
key=private/'station-soundcloud.jks';meta=private/'station-soundcloud.json'
if not meta.exists():meta.write_text(json.dumps({'password':secrets.token_urlsafe(32)}))
env=os.environ.copy();env['STATION_SOUNDCLOUD_STOREPASS']=json.loads(meta.read_text())['password']
if not key.exists():
 subprocess.run([str(JAVA/('keytool'+suffix)),'-genkeypair','-keystore',str(key),'-storetype','JKS','-alias','station-soundcloud','-keyalg','RSA','-keysize','2048','-validity','10000','-dname','CN=Station SoundCloud,O=Local','-storepass:env','STATION_SOUNDCLOUD_STOREPASS','-keypass:env','STATION_SOUNDCLOUD_STOREPASS','-noprompt'],env=env,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
sys.path.insert(0,str(SOURCE))
from newpipe_patch import patch
official=TOOLS/'NewPipe_v0.29.1.apk'
if not official.exists():
 urllib.request.urlretrieve('https://github.com/TeamNewPipe/NewPipe/releases/download/v0.29.1/NewPipe_v0.29.1.apk',official)
patched=TOOLS/'NewPipe-station-unsigned.apk';aligned=TOOLS/'NewPipe-station-aligned.apk'
bridge=TOOLS/'newpipe-bridge';(bridge/'classes').mkdir(parents=True,exist_ok=True);(bridge/'dex').mkdir(exist_ok=True)
subprocess.run([str(JAVA/('javac'+suffix)),'--release','7','-Xlint:-options','-encoding','UTF-8','-cp',str(ANDROID),'-d',str(bridge/'classes')]+[str(p) for p in (SOURCE/'newpipe').glob('*.java')],check=True)
with zipfile.ZipFile(bridge/'classes.jar','w') as z:
 for p in (bridge/'classes').rglob('*.class'):z.write(p,p.relative_to(bridge/'classes').as_posix())
subprocess.run([str(JAVA/('java'+suffix)),'-cp',str(R8),'com.android.tools.r8.D8','--release','--min-api','23','--no-desugaring','--lib',str(ANDROID),'--output',str(bridge/'dex'),str(bridge/'classes.jar')],check=True)
patch(official,patched,bridge/'dex'/'classes.dex')
subprocess.run([str(BT/('zipalign'+suffix)),'-p','-f','4',str(patched),str(aligned)],check=True)
newpipe=DIST/'NewPipe-station1.apk'
subprocess.run([str(JAVA/('java'+suffix)),'-jar',str(BT/'lib'/'apksigner.jar'),'sign','--ks',str(key),'--ks-pass','env:STATION_SOUNDCLOUD_STOREPASS','--key-pass','env:STATION_SOUNDCLOUD_STOREPASS','--ks-key-alias','station-soundcloud','--min-sdk-version','23','--out',str(newpipe),str(aligned)],env=env,check=True)
subprocess.run([str(BT/('zipalign'+suffix)),'-c','-p','4',str(newpipe)],check=True)
subprocess.run([str(JAVA/('java'+suffix)),'-jar',str(BT/'lib'/'apksigner.jar'),'verify',str(newpipe)],check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
signed=DIST/'station-soundcloud.apk'
subprocess.run([str(JAVA/('jarsigner'+suffix)),'-keystore',str(key),'-storepass:env','STATION_SOUNDCLOUD_STOREPASS','-keypass:env','STATION_SOUNDCLOUD_STOREPASS','-sigalg','SHA256withRSA','-digestalg','SHA-256','-signedjar',str(signed),str(unsigned),'station-soundcloud'],env=env,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
print('SoundCloud companion:',signed.stat().st_size,'bytes')
cli=ROOT/'tools'/'soundcloud-cli'
(cli/'classes').mkdir(parents=True,exist_ok=True)
subprocess.run([str(JAVA/('javac'+suffix)),'--release','7','-Xlint:-options','-encoding','UTF-8','-cp',str(ANDROID),'-d',str(cli/'classes')]+[str(p) for p in (SOURCE/'cli').glob('*.java')]+[str(ROOT/'src'/'VlessLink.java'),str(SOURCE/'src'/'CommandParser.java'),str(SOURCE/'check'/'Check.java')],check=True)
subprocess.run([str(JAVA/('java'+suffix)),'-cp',str(cli/'classes'),'Check'],check=True)
with zipfile.ZipFile(cli/'classes.jar','w') as z:
 for p in (cli/'classes').rglob('*.class'):
  if p.stem!='Check':z.write(p,p.relative_to(cli/'classes').as_posix())
subprocess.run([str(JAVA/('java'+suffix)),'-cp',str(R8),'com.android.tools.r8.D8','--release','--min-api','23','--no-desugaring','--lib',str(ANDROID),'--output',str(cli/'vless-import.jar'),str(cli/'classes.jar')],check=True)
template=(SOURCE/'install.template.sh').read_text(encoding='utf-8')
template=template.replace('__BOOT_SH__',(SOURCE/'boot.sh').read_text(encoding='utf-8').rstrip())
template=template.replace('__VLESS_SH__',(SOURCE/'vless.sh').read_text(encoding='utf-8').rstrip())
data=signed.read_bytes()
template=template.replace('__VOICE_APK_SHA256__',hashlib.sha256(data).hexdigest()).replace('__VOICE_APK_BASE64_WRAPPED__',encode_payload(data))
data=(cli/'vless-import.jar').read_bytes()
template=template.replace('__VLESS_JAR_SHA256__',hashlib.sha256(data).hexdigest()).replace('__VLESS_JAR_BASE64_WRAPPED__',encode_payload(data))
data=newpipe.read_bytes()
template=template.replace('__NEWPIPE_APK_SHA256__',hashlib.sha256(data).hexdigest()).replace('__NEWPIPE_APK_BASE64_WRAPPED__',encode_payload(data))
(DIST/'install-soundcloud.sh').write_text(template,encoding='utf-8',newline='\n')
