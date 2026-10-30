#!/usr/bin/env python3
"""Разбор моделей спотера Яндекса (spotter_models/*/acoustic_model.nnet) на компьютере.

Формат — бинарный Kaldi nnet3 со своими слоями Яндекса (Q16*, GroupConvCorou, hardswish).
Проверено на моделях Станции 2, прошивка 0.369.1.46: activation/{alisa,yandex,yasmina},
command, vad — каждый файл разбирается до последнего байта. Только чтение, ничего не меняет.

    python3 contrib/spotter_nnet.py acoustic_model.nnet            # граф и слои
    python3 contrib/spotter_nnet.py --config acoustic_model.nnet   # только текстовый граф
"""

import argparse
import struct
import sys

# Kaldi пишет матрицы с меткой типа; SIM — int16-матрица слоёв Q16* Яндекса.
MATRIX = {'FM': 'f', 'DM': 'd', 'SIM': 'h'}
VECTOR = {'FV': 'f', 'DV': 'd'}


class Reader:
    def __init__(self, data):
        self.b, self.i = data, 0

    def skip_space(self):
        while self.i < len(self.b) and self.b[self.i] in (32, 10):
            self.i += 1

    def token(self):
        self.skip_space()
        end = self.b.index(b' ', self.i)
        tok = self.b[self.i:end].decode()
        self.i = end + 1
        return tok

    def expect(self, tok):
        got = self.token()
        if got != tok:
            raise ValueError(f'ожидался {tok}, а не {got} (байт {self.i})')

    def number(self, fmt):
        size = struct.calcsize(fmt)
        if self.b[self.i] != size:
            raise ValueError(f'размер числа {self.b[self.i]} вместо {size} (байт {self.i})')
        value = struct.unpack_from('<' + fmt, self.b, self.i + 1)[0]
        self.i += 1 + size
        return value

    def array(self, kinds):
        kind = self.token()
        if kind not in kinds:
            raise ValueError(f'неизвестный тип {kind} (байт {self.i})')
        shape = (self.number('i'), self.number('i')) if kind in MATRIX else (self.number('i'),)
        count = shape[0] * (shape[1] if len(shape) == 2 else 1)
        values = struct.unpack_from(f'<{count}{kinds[kind]}', self.b, self.i)
        self.i += count * struct.calcsize(kinds[kind])
        return kind, shape, values


FIELDS = {
    'LinearParams': lambda r: r.array(MATRIX),
    'BiasParams': lambda r: r.array(VECTOR),
    'Bias': lambda r: r.array(VECTOR),
    'Scales': lambda r: r.array(VECTOR),
    'ValueAvg': lambda r: r.array(VECTOR),
    'DerivAvg': lambda r: r.array(VECTOR),
    'Dim': lambda r: r.number('i'),
    'ContextParam': lambda r: r.number('i'),
    'S': lambda r: r.number('f'),
    'Count': lambda r: r.number('d'),
}


def parse(data):
    """Вернуть (строки текстового графа, [(имя, тип, поля)]); ошибка, если файл не разобран целиком."""
    if data[:2] != b'\0B':
        raise ValueError('не бинарный файл Kaldi')
    r = Reader(data)
    r.i = 2
    r.expect('<Nnet3>')
    end = data.index(b'<NumComponents>', r.i)
    config = [line for line in data[r.i:end].decode().split('\n') if line.strip()]
    r.i = end
    r.expect('<NumComponents>')
    components = []
    for _ in range(r.number('i')):
        r.expect('<ComponentName>')
        name, kind = r.token(), r.token()[1:-1]
        fields = {}
        while (tok := r.token()) != f'</{kind}>':
            key = tok[1:-1]
            if key not in FIELDS:
                raise ValueError(f'неизвестное поле {tok} в {kind} (байт {r.i})')
            fields[key] = FIELDS[key](r)
        components.append((name, kind, fields))
    r.expect('</Nnet3>')
    r.skip_space()
    if r.i != len(data):
        raise ValueError(f'после </Nnet3> осталось {len(data) - r.i} байт')
    return config, components


def describe(fields):
    parts = []
    for key, value in fields.items():
        if key == 'LinearParams':
            parts.append(f'W {value[0]} {value[1][0]}x{value[1][1]}')
        elif key in ('BiasParams', 'Bias', 'Scales'):
            parts.append(f'{key}[{value[1][0]}]')
        elif key in ('S', 'Dim', 'ContextParam'):
            parts.append(f'{key}={value:.6g}' if isinstance(value, float) else f'{key}={value}')
    return ' '.join(parts)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    parser.add_argument('model', nargs='+', help='acoustic_model.nnet')
    parser.add_argument('--config', action='store_true', help='только текстовый граф сети')
    args = parser.parse_args()
    for path in args.model:
        with open(path, 'rb') as f:
            config, components = parse(f.read())
        print(f'# {path}: {len(config)} строк графа, {len(components)} слоёв')
        print('\n'.join(config))
        if not args.config:
            for name, kind, fields in components:
                print(f'{name:24} {kind:28} {describe(fields)}')


if __name__ == '__main__':
    sys.exit(main())
