#!/usr/bin/env python3
"""Speak text through an existing Alice session over an authenticated SSH tunnel.

Host tool: Python 3.11+, OpenSSH. Station: root-SSH and socat.
Protocol checked on Lite 2 YNDX-00028 / Plum,
firmware 0.369.1.50.4794654278.20261021.133.
Adapted from the say.py helper in rison1337/Alisa-ChatGPT-voice-assistant.
No installation, firmware edits or rollback needed; run while Alice is idle.
"""
import argparse
import asyncio
import contextlib
import sys


def varint(value):
    output = bytearray()
    while value >= 128:
        output.append((value & 127) | 128)
        value >>= 7
    output.append(value)
    return bytes(output)


def integer(field, value):
    return varint(field * 8) + varint(value)


def byte_field(field, value):
    return varint(field * 8 + 2) + varint(len(value)) + value


def fields(data):
    """Read the small protobuf envelopes, rejecting truncated or invalid fields."""
    if not isinstance(data, bytes):
        raise ValueError('Некорректное protobuf-сообщение.')
    offset = 0

    def number():
        nonlocal offset
        value = 0
        for shift in range(0, 70, 7):
            if offset >= len(data):
                raise ValueError('Неполное protobuf-сообщение.')
            byte = data[offset]
            offset += 1
            if shift == 63 and byte > 1:
                raise ValueError('Некорректное protobuf-число.')
            value |= (byte & 127) << shift
            if byte < 128:
                return value
        raise ValueError('Некорректное protobuf-число.')

    result = {}
    while offset < len(data):
        key = number()
        if key >> 3 == 0:
            raise ValueError('Некорректный номер protobuf-поля.')
        wire = key & 7
        if wire == 0:
            value = number()
        elif wire in (1, 2, 5):
            size = number() if wire == 2 else (8 if wire == 1 else 4)
            if offset + size > len(data):
                raise ValueError('Неполное protobuf-поле.')
            value = data[offset:offset + size] if wire == 2 else None
            offset += size
        else:
            raise ValueError('Неподдерживаемый тип protobuf-поля.')
        result[key >> 3] = value
    return result


def rpc_frame(field, payload):
    remote = byte_field(7, b'AliceCapability') + byte_field(field, payload)
    envelope = byte_field(252, remote) + integer(253, 210)
    return len(envelope).to_bytes(4, 'little') + envelope


def vocalize_frame(text):
    # START_VOCALIZE=18, events=true, TVocalizeDirective(text, Append=1).
    directive = byte_field(1, text.encode('utf-8')) + integer(2, 1)
    return rpc_frame(8, integer(1, 18) + integer(3, 1) + byte_field(13, directive))


def ssh_command(host):
    if not host or host.startswith('-') or any(char.isspace() for char in host):
        raise ValueError('Нужен настроенный SSH-псевдоним без пробелов.')
    return ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
            '-o', 'ConnectTimeout=6', '-o', 'ServerAliveInterval=5',
            '-o', 'ServerAliveCountMax=2', host,
            'exec socat STDIO TCP:127.0.0.1:9875,connect-timeout=2']


async def speak(host, text, timeout):
    proc = await asyncio.create_subprocess_exec(
        *ssh_command(host), stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    started = False
    try:
        async with asyncio.timeout(timeout):
            # Keep the subscription and request on the same live IPC connection.
            subscribe = rpc_frame(20, byte_field(1, b'AliceCapability'))
            proc.stdin.write(subscribe + vocalize_frame(text))
            await proc.stdin.drain()
            while True:
                size = int.from_bytes(await proc.stdout.readexactly(4), 'little')
                if not 0 < size <= 512 * 1024:
                    raise ValueError('Некорректный размер ответа колонки.')
                envelope = fields(await proc.stdout.readexactly(size))
                if envelope.get(253) != 210:
                    continue
                remote = fields(envelope.get(252, b''))
                if 18 not in remote:
                    continue
                event = fields(remote[18]).get(1)
                if event == 6:  # TTS_STARTED
                    started = True
                    print('Озвучка началась.', flush=True)
                elif event == 1 and started:  # TTS_COMPLETED
                    print('Колонка подтвердила завершение озвучки.', flush=True)
                    return
                elif event == 4:  # ON_ALICE_ERROR; never print private event payloads.
                    raise RuntimeError('Штатный речевой сервис сообщил об ошибке.')
    finally:
        proc.stdin.close()
        with contextlib.suppress(Exception):
            await asyncio.wait_for(proc.stdin.wait_closed(), 1)
        try:
            await asyncio.wait_for(proc.wait(), 2)
        except asyncio.TimeoutError:
            with contextlib.suppress(ProcessLookupError):
                proc.terminate()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(proc.wait(), 2)
            if proc.returncode is None:
                with contextlib.suppress(ProcessLookupError):
                    proc.kill()
                await proc.wait()


def main(argv=None):
    parser = argparse.ArgumentParser(description='Озвучить текст штатным голосом Алисы.')
    parser.add_argument('text', help='Фраза в кавычках, до 2000 символов')
    parser.add_argument('--host', default='alice', help='Настроенный SSH-псевдоним колонки')
    parser.add_argument('--timeout', type=float, default=30, help='Ожидание, от 3 до 120 секунд')
    parser.add_argument('--dry-run', action='store_true', help='Проверить запрос без подключения')
    args = parser.parse_args(argv)
    if not args.text.strip() or len(args.text) > 2000:
        parser.error('Нужна непустая фраза длиной до 2000 символов.')
    if not 3 <= args.timeout <= 120:
        parser.error('--timeout должен быть от 3 до 120 секунд.')
    try:
        ssh_command(args.host)
        if args.dry_run:
            print(f'Запрос собран: {len(vocalize_frame(args.text))} байт; подключения не было.')
        else:
            asyncio.run(speak(args.host, args.text, args.timeout))
    except TimeoutError:
        parser.exit(1, 'Нет подтверждения завершения за отведённое время.\n')
    except asyncio.IncompleteReadError:
        parser.exit(1, 'SSH/IPC-соединение закрылось до подтверждения озвучки.\n')
    except (RuntimeError, OSError, ValueError):
        parser.exit(1, 'Не удалось выполнить озвучку; проверьте SSH и доступность Алисы.\n')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
