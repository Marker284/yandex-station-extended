"""Parse a synthetic spotter model built in the same byte layout as the station's .nnet files."""
import importlib.util
from pathlib import Path
import struct
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'spotter_nnet.py'
SPEC = importlib.util.spec_from_file_location('spotter_nnet', SOURCE)
nnet = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(nnet)


def i32(v):
    return b'\x04' + struct.pack('<i', v)


def f32(v):
    return b'\x04' + struct.pack('<f', v)


def model():
    config = (b'input-node name=input dim=2\n'
              b'component-node name=svdf_features_0 component=svdf_features_0 input=input\n'
              b'component-node name=softmax_1 component=softmax_1 input=svdf_features_0\n'
              b'output-node name=output input=softmax_1 objective=linear\n\n')
    q16 = (b'<ComponentName> svdf_features_0 <Q16FixedAffineComponent> <S> ' + f32(0.5)
           + b'<LinearParams> SIM ' + i32(2) + i32(2) + struct.pack('<4h', 1, -2, 3, -4)
           + b'<BiasParams> FV ' + i32(2) + struct.pack('<2f', 0.25, -0.25)
           + b'</Q16FixedAffineComponent> ')
    softmax = (b'<ComponentName> softmax_1 <SoftmaxComponent> <Dim> ' + i32(2)
               + b'<ValueAvg> FV ' + i32(0) + b'<DerivAvg> FV ' + i32(0)
               + b'<Count> \x08' + struct.pack('<d', 0) + b'</SoftmaxComponent> ')
    return b'\0B<Nnet3> ' + config + b'<NumComponents> ' + i32(2) + q16 + softmax + b'</Nnet3> \n'


class SpotterNnet(unittest.TestCase):
    def test_parses_graph_and_q16_layer(self):
        config, comps = nnet.parse(model())
        self.assertEqual(config[0], 'input-node name=input dim=2')
        self.assertEqual([(n, k) for n, k, _ in comps],
                         [('svdf_features_0', 'Q16FixedAffineComponent'), ('softmax_1', 'SoftmaxComponent')])
        fields = comps[0][2]
        self.assertEqual(fields['S'], 0.5)
        self.assertEqual(fields['LinearParams'], ('SIM', (2, 2), (1, -2, 3, -4)))
        self.assertEqual(fields['BiasParams'][2], (0.25, -0.25))
        self.assertEqual(comps[1][2]['Dim'], 2)

    def test_rejects_trailing_or_truncated_data(self):
        with self.assertRaises(ValueError):
            nnet.parse(model() + b'junk')
        with self.assertRaises(Exception):
            nnet.parse(model()[:-40])

    def test_rejects_unknown_field(self):
        with self.assertRaisesRegex(ValueError, 'неизвестное поле'):
            nnet.parse(model().replace(b'<Dim> ', b'<Xyz> '))


if __name__ == '__main__':
    unittest.main()
