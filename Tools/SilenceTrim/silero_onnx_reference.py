#!/usr/bin/env python3
"""Reference for the Swift Silero port: speech probabilities per 512-sample chunk of a 16 kHz mono
WAV, from ONNX Runtime and from a numpy re-implementation of the same graph. Measured 21.11.2026
on 92 s of Bits und so #1032: numpy vs ONNX max 2.1e-6, Swift (ICSileroVAD) vs ONNX max 1.3e-6,
no differing decision at 0.5.

    venv/bin/python -I Tools/SilenceTrim/silero_onnx_reference.py <16k.wav> <probs.npy> <silero_vad_16k_op15.onnx>
"""
import sys, wave, numpy as np, onnxruntime as ort
def read16k(path):
    w = wave.open(path); assert w.getframerate() == 16000 and w.getnchannels() == 1
    return np.frombuffer(w.readframes(w.getnframes()), dtype='<i2').astype(np.float32) / 32768.0
def onnx_probs(x, model):
    s = ort.InferenceSession(model, providers=['CPUExecutionProvider'])
    state = np.zeros((2, 1, 128), np.float32); ctx = np.zeros(64, np.float32); out = []
    for i in range(0, len(x) - 511, 512):
        chunk = np.concatenate([ctx, x[i:i+512]])[None, :]
        p, state = s.run(None, {'input': chunk, 'state': state, 'sr': np.array(16000, dtype=np.int64)})
        ctx = chunk[0, -64:]; out.append(float(p[0, 0]))
    return np.array(out)
import onnx
_m = onnx.load(sys.argv[3])
_I = {t.name: onnx.numpy_helper.to_array(t) for t in _m.graph.initializer}
W = {'stft_conv.weight': _I['model.stft.forward_basis_buffer']}
for k in range(4):
    W[f'conv{k+1}.weight'] = _I[f'model.encoder.{k}.reparam_conv.weight']; W[f'conv{k+1}.bias'] = _I[f'model.encoder.{k}.reparam_conv.bias']
W['lstm_cell.weight_ih'] = _I['model.decoder.rnn.weight_ih']; W['lstm_cell.weight_hh'] = _I['model.decoder.rnn.weight_hh']
W['lstm_cell.bias_ih'] = _I['model.decoder.rnn.bias_ih']; W['lstm_cell.bias_hh'] = _I['model.decoder.rnn.bias_hh']
W['final_conv.weight'] = _I['model.decoder.decoder.2.weight']; W['final_conv.bias'] = _I['model.decoder.decoder.2.bias']
def conv1d(x, w, b, stride, pad):
    # x [C, T], w [O, C, K]
    if pad: x = np.pad(x, ((0, 0), (pad, pad)))
    O, C, K = w.shape; T = (x.shape[1] - K) // stride + 1
    cols = np.stack([x[:, t*stride:t*stride+K] for t in range(T)], 0)  # [T, C, K]
    y = np.einsum('tck,ock->ot', cols, w)
    return y + (b[:, None] if b is not None else 0)
def numpy_probs(x):
    h = np.zeros(128, np.float32); c = np.zeros(128, np.float32); ctx = np.zeros(64, np.float32); out = []
    sig = lambda v: 1 / (1 + np.exp(-v))
    for i in range(0, len(x) - 511, 512):
        chunk = np.concatenate([ctx, x[i:i+512]]); ctx = chunk[-64:]
        padded = np.concatenate([chunk, chunk[-2:-66:-1]])  # reflect right by 64
        f = conv1d(padded[None, :], W['stft_conv.weight'], None, 128, 0)
        mag = np.sqrt(f[:129] ** 2 + f[129:] ** 2)
        y = np.maximum(conv1d(mag, W['conv1.weight'], W['conv1.bias'], 1, 1), 0)
        y = np.maximum(conv1d(y, W['conv2.weight'], W['conv2.bias'], 2, 1), 0)
        y = np.maximum(conv1d(y, W['conv3.weight'], W['conv3.bias'], 2, 1), 0)
        y = np.maximum(conv1d(y, W['conv4.weight'], W['conv4.bias'], 1, 1), 0)[:, 0]
        g = W['lstm_cell.weight_ih'] @ y + W['lstm_cell.bias_ih'] + W['lstm_cell.weight_hh'] @ h + W['lstm_cell.bias_hh']
        ig, fg, gg, og = sig(g[:128]), sig(g[128:256]), np.tanh(g[256:384]), sig(g[384:])
        c = fg * c + ig * gg; h = og * np.tanh(c)
        p = sig(W['final_conv.weight'][0, :, 0] @ np.maximum(h, 0) + W['final_conv.bias'][0])
        out.append(float(p))
    return np.array(out)
if __name__ == '__main__':
    x = read16k(sys.argv[1])
    a = onnx_probs(x, sys.argv[3]); b = numpy_probs(x)
    print('chunks', len(a), 'max |onnx-numpy|', np.abs(a - b).max(), 'speech share (p>0.5) onnx %.3f numpy %.3f' % ((a > .5).mean(), (b > .5).mean()))
    np.save(sys.argv[2], a)
