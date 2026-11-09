@echo off
rem install-ssh.bat - Windows helper: catch a Yandex Station on the LAN right after reset
rem and install Dropbear SSH on port 2222 while network ADB is still open.
rem
rem What it does:
rem   1. Finds this PC's local networks and scans them for ADB (5555).
rem   2. Skips devices that are not a Yandex speaker (no /data/quasar), e.g. Android TVs.
rem   3. Pushes contrib/bin/dropbear + dropbearkey, makes a host key, installs
rem      /etc/init.d/S99zdropbear (same script as in docs/start/ssh.md) and starts SSH.
rem   4. Optionally runs contrib/yandex-noupdate.sh over SSH.
rem If the speaker already has SSH on 2222, steps 1-3 are skipped.
rem
rem Tested: Station Mini 2 with clock (yandexmini_2), quasar 0.369.1.46, root via DNS method,
rem Windows 10/11 with OpenSSH client and Android platform-tools.
rem Rollback: ssh -p 2222 root@IP, then
rem   mount -o remount,rw / ; rm /etc/init.d/S99zdropbear ; mount -o remount,ro / ; rm -r /data/opt/bin/dropbear*
rem
rem Usage: keep this folder inside contrib/ (it needs ..\bin\dropbear and ..\yandex-noupdate.sh),
rem start install-ssh.bat, then reset the speaker and pair it in the app.
setlocal
set PATH=%PATH%;C:\Windows\System32\OpenSSH
set SSHO=-p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ConnectTimeout=5
set PROBE=%TEMP%\yse_probe.txt
cd /d "%~dp0"
set C=..

for %%f in (%C%\bin\dropbear %C%\bin\dropbearkey %C%\yandex-noupdate.sh S99zdropbear find-speaker.ps1) do (
  if not exist "%%f" (
    echo [!] Missing %%f - keep this folder inside contrib\ of yandex-station-extended
    pause
    exit /b 1
  )
)
where ssh >nul 2>&1 || (
  echo [!] ssh not found. Settings - Apps - Optional features - add "OpenSSH Client"
  pause
  exit /b 1
)

echo [*] Looking for a speaker that already has SSH on 2222 ...
set IP=
for /f "delims=" %%i in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0find-speaker.ps1" -Port 2222') do call :trysshhost %%i
if defined IP (
  echo [+] SSH already works on %IP%
  goto noupdate
)

set ADB=
for /f "delims=" %%a in ('where adb 2^>nul') do if not defined ADB set ADB=%%a
if not defined ADB if exist "C:\adb\adb.exe" set ADB=C:\adb\adb.exe
if not defined ADB if exist "%~dp0adb.exe" set ADB=%~dp0adb.exe
if not defined ADB (
  echo [!] adb.exe not found. Download platform-tools:
  echo     https://developer.android.com/tools/releases/platform-tools
  echo     and put adb.exe into C:\adb or next to this script.
  pause
  exit /b 1
)
echo [*] adb: %ADB%
"%ADB%" disconnect >nul 2>&1
"%ADB%" kill-server >nul 2>&1
"%ADB%" start-server >nul 2>&1

echo [*] NOW reset the speaker and pair it in the app. Just wait here.
echo [*] Scanning the local network for ADB port 5555 ... Ctrl+C to stop
set BAD=_
:wait
set IP=
for /f "delims=" %%i in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0find-speaker.ps1" -Port 5555') do call :tryadb %%i
if not defined IP (
  timeout /t 1 >nul
  goto wait
)
set S="%ADB%" -s %IP%:5555
echo [+] Speaker %IP%, root OK
goto main

rem ---- one IP: Yandex speaker with root over ADB? ----
:tryadb
if defined IP exit /b
echo %BAD%_ | find "_%1_" >nul
if not errorlevel 1 exit /b
"%ADB%" disconnect %1:5555 >nul 2>&1
"%ADB%" connect %1:5555 | find "connected to" >nul
if errorlevel 1 exit /b
"%ADB%" -s %1:5555 shell "echo SHELL_OK; id; [ -d /data/quasar ] && echo YANDEX_SPEAKER" > "%PROBE%" 2>&1
find "YANDEX_SPEAKER" "%PROBE%" >nul
if not errorlevel 1 goto tryroot
find "SHELL_OK" "%PROBE%" >nul
if not errorlevel 1 goto trybad
find "unauthorized" "%PROBE%" >nul
if not errorlevel 1 goto trybad
rem "offline" or no answer yet - try again on the next round
"%ADB%" disconnect %1:5555 >nul 2>&1
exit /b
:trybad
echo [-] %1 is another device, not a Yandex speaker - skipping it
"%ADB%" disconnect %1:5555 >nul 2>&1
set BAD=%BAD%_%1
exit /b
:tryroot
find "uid=0" "%PROBE%" >nul
if errorlevel 1 (
  "%ADB%" disconnect %1:5555 >nul 2>&1
  exit /b
)
set IP=%1
exit /b

rem ---- one IP: SSH on 2222 and it is a Yandex speaker? ----
:trysshhost
if defined IP exit /b
ssh %SSHO% root@%1 "[ -d /data/quasar ] && echo YANDEX_SPEAKER" 2>nul < NUL | find "YANDEX_SPEAKER" >nul
if not errorlevel 1 set IP=%1
exit /b

:main
echo [*] 1/3 Pushing SSH files ...
%S% shell "mkdir -p /data/opt/bin /data/opt/etc/dropbear; rm -f /data/opt/bin/dropbear /data/opt/bin/dropbearkey"
%S% push %C%\bin\dropbear %C%\bin\dropbearkey /data/opt/bin/
%S% push S99zdropbear /data/opt/S99zdropbear
%S% shell "chmod +x /data/opt/bin/dropbear /data/opt/bin/dropbearkey /data/opt/S99zdropbear; [ -s /data/opt/etc/dropbear/hk_ed25519 ] || /data/opt/bin/dropbearkey -t ed25519 -f /data/opt/etc/dropbear/hk_ed25519 >/dev/null 2>&1; [ -x /etc/init.d/S99zdropbear ] || (mount -o remount,rw / && cp /data/opt/S99zdropbear /etc/init.d/S99zdropbear && chmod +x /etc/init.d/S99zdropbear; sync; mount -o remount,ro /); ls -l /data/opt/bin/ /etc/init.d/S99zdropbear"

echo [*] 2/3 Starting SSH ...
rem dropbear keeps the adb session open, so it runs in its own minimized window
start "dropbear" /min %S% shell "/etc/init.d/S99zdropbear start"
set N=0
:waitssh
powershell -NoProfile -Command "if((New-Object Net.Sockets.TcpClient).ConnectAsync('%IP%',2222).Wait(1000)){exit 0}else{exit 1}"
if not errorlevel 1 goto sshup
set /a N+=1
if %N% geq 20 (
  echo [!] SSH port 2222 did not open. Log: adb shell cat /data/opt/etc/dropbear/dropbear.log
  pause
  exit /b 1
)
goto waitssh
:sshup
echo [+] 3/3 SSH port 2222 is OPEN on %IP%

:noupdate
echo.
choice /c YN /n /m "Disable firmware updates with yandex-noupdate.sh now? [Y/N] "
if errorlevel 2 goto done
echo When asked for "password" - just press Enter (it is empty)
type %C%\yandex-noupdate.sh | ssh %SSHO% root@%IP% "cat > /data/opt/yandex-noupdate.sh && sh /data/opt/yandex-noupdate.sh; echo; sh /data/opt/yandex-noupdate.sh status"

:done
echo.
echo DONE. Speaker IP: %IP%
echo Login: ssh -p 2222 root@%IP%   (password is empty - press Enter)
echo Check autostart: unplug the speaker, wait 2 min, run this script again - it should find SSH.
pause
