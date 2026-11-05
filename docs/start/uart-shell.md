# UART SHELL

Инструкция по настройке автоматического запуска root-оболочки (shell) на порту UART (`/dev/ttyS0`) при каждой загрузке устройства.

!!! note "Проверено"
    Пока проверено только на **Яндекс Станции Мини (1 поколение)**.
    Вероятно, это будет работать и на других колонках с
    **Buildroot** (есть скрипты в `/etc/init.d`),
    но это не проверялось — проверяйте на свой риск.

## Что понадобится

- колонка с root ([шаг 1](../start/root.md));
- UART-адаптер, подключённый к `ttyS0`;
- Buildroot (в `/etc/init.d` лежат разные скрипты);

## Шаги

1. **Создать init-скрипт `/etc/init.d/S99uart_sh`**

   ```sh
   [ -e /etc/init.d/S99uart_sh ] && chattr -i /etc/init.d/S99uart_sh

   cat > /etc/init.d/S99uart_sh <<'EOF'
   #!/bin/sh
   # /etc/init.d/S99uart_sh
   # Запускает shell на /dev/ttyS0 всегда
   # кроме rabbit_hole_debug=1

   TTY=/dev/ttyS0
   ENV=rabbit_hole_debug

   VAL=$(/bin/fw_printenv "$ENV" 2>/dev/null)
   [ "$VAL" = "$ENV=1" ] && exit 0

   [ -e "$TTY" ] || exit 0

   if command -v setsid >/dev/null 2>&1; then
       setsid sh -c "exec sh <$TTY >$TTY 2>&1" &
   elif busybox --list 2>/dev/null | grep -qw setsid; then
       busybox setsid sh -c "exec sh <$TTY >$TTY 2>&1" &
   elif command -v getty >/dev/null 2>&1; then
       getty -n -l /bin/sh -L "$TTY" 115200 vt100 &
   else
       nohup sh -c "exec sh <$TTY >$TTY 2>&1" >/dev/null 2>&1 &
   fi

   exit 0
   EOF

   chmod 777 /etc/init.d/S99uart_sh
   chattr +i /etc/init.d/S99uart_sh
   sync
   ```

   Почему так:

   - `setsid` — новая сессия, `ttyS0` становится управляющим
     терминалом, иначе фоновый `sh` получает `SIGTTIN` и уходит
     в `Stopped (tty input)`;
   - `exec sh` — целевой `sh` становится управляющим процессом
     на tty;
   - `chattr +i` — защищает файл от удаления и изменения

2. **Проверить без перезагрузки**

   ```sh
   cat /etc/init.d/S99uart_sh
   ls -la /etc/init.d/S99uart_sh
   /etc/init.d/S99uart_sh
   ```

   В UART на `ttyS0` должен появиться shell. После `reboot`
   он запустится автоматически

## Вернуть обратно

```sh
chattr -i /etc/init.d/S99uart_sh
rm -f /etc/init.d/S99uart_sh
reboot
```