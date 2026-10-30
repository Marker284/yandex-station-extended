#!/system/bin/sh
# Interactive key import; no key argument, shell-history entry or extra key file.
set -e
set +x
export ANDROID_DATA=/data ANDROID_ROOT=/system PATH=/system/bin:/sbin:/bin
export CLASSPATH=/data/station1-soundcloud/vless-import.jar
[ "$(id -u)" = 0 ] || { echo 'Run in AliceBridge Station terminal with root'; exit 1; }
case "$(pm path com.v2ray.ang 2>/dev/null)" in package:*) ;; *) echo 'Install v2rayNG first'; exit 1;; esac
if [ -t 0 ]; then
    old=$(stty -g)
    trap 'stty "$old"; unset key' EXIT
    trap 'exit 130' INT TERM HUP
    printf 'Paste the VLESS link, then press Enter (input is hidden): '
    stty -echo
    IFS= read -r key || { printf '\nInput cancelled\n'; exit 1; }
    stty "$old"
    printf '\n'
    printf '%s\n' "$key" | app_process /system/bin VlessImport
    unset key
else
    # Piped input is useful for private local automation; do not put real keys in shell command history.
    app_process /system/bin VlessImport
fi
