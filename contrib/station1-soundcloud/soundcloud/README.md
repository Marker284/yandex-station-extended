# Station 1 SoundCloud installer

The standalone `install.sh` contains NewPipe, a signed launcher/command permission,
a native Quasar voice worker and a VLESS importer. Run in AliceBridge's root terminal.
No TV kit, AirPlay or metrics script is needed. VPN credentials are supplied by the user;
Android VPN consent and first profile selection remain explicit actions in v2rayNG.
The worker starts that profile after reboot through the native Tasker API;
`vpn-autostart off` disables this without stopping the current connection.

Build with Python 3, JDK 17, Android SDK platform 23 or newer and build-tools
(aapt2, zipalign, apksigner), plus D8/R8. Set JAVA_HOME and ANDROID_SDK_ROOT;
STATION_ANDROID_JAR and STATION_R8_JAR can override individual inputs.
The parent `build.py` builds the APKs/CLI and creates `dist/install-soundcloud.sh`.
The Java check covers VLESS validation, voice parsing and bounded protobuf decoding.

`cli/NativeVoice.java` connects only to the existing aliced loopback IPC port from
quasar.cfg. It reads the recognized phrase from AliceState after the listening phase,
deduplicates native request IDs in memory, cancels the standard dialog only for an
explicit SoundCloud command, and sends the command to NewPipe's signature-protected
receiver. Ordinary Alice requests and volume commands remain native.
No accessibility, READ_LOGS, microphone capture, proxying Yandex or firmware edits.
The worker's diagnostic file contains counters, connection state and error class only.

The NewPipe 0.29.1 animation fix is `NewPipe-station1.patch`; the background
player adapter source is `newpipe/*.java`, component registration is
`manifest_patch.py`, and the pinned binary transformation is `newpipe_patch.py`.
No NewPipe network code or HTTPS validation is replaced. See COPYING.NewPipe
and https://github.com/TeamNewPipe/NewPipe/tree/v0.29.1 for the upstream source.
The installer backs up the pinned official APK and data before signature migration,
restores ownership using PackageManager's UID, and supports `restore-newpipe`.
Unknown APK signatures/versions are preserved.

Both APKs use the same local signing key, kept outside the repository in
~/.codex/buildkeys/. Preserve it for updates; never publish the key or password.
