#!/usr/bin/env python3
"""Exports the Silero VAD weights for Classes/SilenceTrim/ICSileroVAD.swift.

Source: https://github.com/snakers4/silero-vad, tag v6.2.3, src/silero_vad/data/silero_vad_16k_op15.onnx
(SHA-256 7ed98ddbad84ccac4cd0aeb3099049280713df825c610a8ed34543318f1b2c49, MIT license).
The graph's initializers are written unchanged ("SVAD" format version 1: name, element count,
float32 little endian). The safetensors file in the same folder holds different weights; only the
ONNX initializers reproduce the ONNX Runtime output.

    python3 -m venv venv && venv/bin/pip install onnx numpy
    venv/bin/python Tools/SilenceTrim/silero_export_weights.py silero_vad_16k_op15.onnx Classes/SilenceTrim/silero_vad_16k_v6.2.3.bin
"""
import struct
import sys

import numpy as np
import onnx

model = onnx.load(sys.argv[1])
tensors = {t.name: onnx.numpy_helper.to_array(t).astype('<f4') for t in model.graph.initializer}
order = ['model.stft.forward_basis_buffer'] + \
        [f'model.encoder.{k}.reparam_conv.{p}' for k in range(4) for p in ('weight', 'bias')] + \
        ['model.decoder.rnn.weight_ih', 'model.decoder.rnn.weight_hh', 'model.decoder.rnn.bias_ih',
         'model.decoder.rnn.bias_hh', 'model.decoder.decoder.2.weight', 'model.decoder.decoder.2.bias']
out = bytearray(b'SVAD') + struct.pack('<II', 1, len(order))
for name in order:
    values = np.ascontiguousarray(tensors[name]).reshape(-1)
    encoded = name.encode()
    out += struct.pack('<I', len(encoded)) + encoded + struct.pack('<I', values.size) + values.tobytes()
open(sys.argv[2], 'wb').write(out)
print(len(out), 'bytes')
