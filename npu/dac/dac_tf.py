# Запуск в CI: .github/workflows/dac.yml (нужно ~6 ГБ ОЗУ: конвертер TFLite копирует веса много раз).
# Qwen3-TTS-Tokenizer-12Hz DAC decoder -> TFLite (fold2). Usage: python3 dac_tf.py model.safetensors T50 out.tflite [fp16|fp32]
import sys, json, struct, numpy as np
ST = sys.argv[1]; T = int(sys.argv[2]); OUT = sys.argv[3]; MODE = sys.argv[4] if len(sys.argv) > 4 else "fp16"
def load(path, prefix):
    f = open(path, "rb"); n = struct.unpack("<Q", f.read(8))[0]; h = json.loads(f.read(n)); base = 8 + n; W = {}
    for k, v in h.items():
        if k.startswith(prefix):
            a, b = v["data_offsets"]; f.seek(base + a); assert v["dtype"] == "F32"
            W[k[len(prefix):]] = np.frombuffer(f.read(b - a), dtype=np.float32).reshape(v["shape"])
    return W
W = load(ST, "decoder.decoder.")
STR = [8, 5, 4, 3]; DIL = [1, 3, 9]
def snake_p(p): return np.exp(W[p + ".alpha"]), 1.0 / (np.exp(W[p + ".beta"]) + 1e-9)
# ---------- numpy reference (PyTorch semantics, [T, C]) ----------
def np_snake(x, p): a, ib = snake_p(p); return x + np.sin(a * x) ** 2 * ib
def np_conv(x, w, b, d=1):  # w [OC, IC, K], causal
    K = w.shape[2]; xp = np.concatenate([np.zeros(((K - 1) * d, x.shape[1]), np.float32), x]); Tn = x.shape[0]
    y = np.zeros((Tn, w.shape[0]), np.float32) + b
    for k in range(K): y += xp[k * d:k * d + Tn] @ w[:, :, k].T
    return y
def np_tconv(x, w, b, s):  # w [IC, OC, K] ConvTranspose1d, trim right K-s
    K = w.shape[2]; Tn = x.shape[0]; y = np.zeros(((Tn - 1) * s + K, w.shape[1]), np.float32)
    for i in range(Tn):
        for k in range(K): y[i * s + k] += x[i] @ w[:, :, k]
    return y[:Tn * s] + b
def np_dac(x):
    x = np_conv(x, W["0.conv.weight"], W["0.conv.bias"])
    for i in range(4):
        p = "%d.block." % (i + 1); x = np_snake(x, p + "0"); x = np_tconv(x, W[p + "1.conv.weight"], W[p + "1.conv.bias"], STR[i])
        for r in range(3):
            q = p + "%d." % (r + 2); y = np_snake(x, q + "act1"); y = np_conv(y, W[q + "conv1.conv.weight"], W[q + "conv1.conv.bias"], DIL[r])
            y = np_snake(y, q + "act2"); y = np_conv(y, W[q + "conv2.conv.weight"], W[q + "conv2.conv.bias"]); x = x + y
    x = np_snake(x, "5"); x = np_conv(x, W["6.conv.weight"], W["6.conv.bias"])
    return np.clip(x[:, 0], -1, 1)
# ---------- TF graph, NHWC [1, 1, T, C] ----------
import tensorflow as tf
def tf_snake(x, p): a, ib = snake_p(p); return x + tf.square(tf.sin(x * a.astype(np.float32))) * ib.astype(np.float32)
def tf_conv(x, w, b, d=1):
    K = w.shape[2]
    if K > 1: x = tf.pad(x, [[0, 0], [0, 0], [(K - 1) * d, 0], [0, 0]])
    k = np.ascontiguousarray(w.transpose(2, 1, 0)[None])  # [1, K, IC, OC]
    return tf.nn.conv2d(x, k, 1, "VALID", dilations=[1, 1, d, 1]) + b
def tf_tconv(x, w, b, s):  # K = 2s: causal k=2 conv to s*OC channels + reshape (depth-to-time)
    IC, OC, K = w.shape; assert K == 2 * s
    k = np.zeros((1, 2, IC, s * OC), np.float32)
    for r in range(s): k[0, 0, :, r * OC:(r + 1) * OC] = w[:, :, r + s]; k[0, 1, :, r * OC:(r + 1) * OC] = w[:, :, r]
    x = tf.pad(x, [[0, 0], [0, 0], [1, 0], [0, 0]]); y = tf.nn.conv2d(x, k, 1, "VALID") + np.tile(b, s)
    Tn = x.shape[2] - 1
    return tf.reshape(y, [1, 1, Tn * s, OC])
def tf_dac(x):  # x [1, T, 1024]
    x = tf.reshape(x, [1, 1, T, 1024]); x = tf_conv(x, W["0.conv.weight"], W["0.conv.bias"])
    for i in range(4):
        p = "%d.block." % (i + 1); x = tf_snake(x, p + "0"); x = tf_tconv(x, W[p + "1.conv.weight"], W[p + "1.conv.bias"], STR[i])
        for r in range(3):
            q = p + "%d." % (r + 2); y = tf_snake(x, q + "act1"); y = tf_conv(y, W[q + "conv1.conv.weight"], W[q + "conv1.conv.bias"], DIL[r])
            y = tf_snake(y, q + "act2"); y = tf_conv(y, W[q + "conv2.conv.weight"], W[q + "conv2.conv.bias"]); x = x + y
    x = tf_snake(x, "5"); x = tf_conv(x, W["6.conv.weight"], W["6.conv.bias"])
    return tf.reshape(tf.clip_by_value(x, -1.0, 1.0), [1, T * 480])
f = tf.function(tf_dac, input_signature=[tf.TensorSpec([1, T, 1024], tf.float32, name="latent")])
rng = np.random.default_rng(0); xin = (rng.standard_normal((T, 1024)) * 0.5).astype(np.float32)
if T <= 16 and MODE != "nocheck":
    ref = np_dac(xin); got = f(xin[None]).numpy()[0]
    print("TF vs numpy: max|d| %.2e, ref rms %.4f" % (np.abs(ref - got).max(), np.sqrt((ref ** 2).mean())))
conv = tf.lite.TFLiteConverter.from_concrete_functions([f.get_concrete_function()], f)
if MODE == "fp16":
    conv.optimizations = [tf.lite.Optimize.DEFAULT]; conv.target_spec.supported_types = [tf.float16]
open(OUT, "wb").write(conv.convert())
it = tf.lite.Interpreter(model_path=OUT); it.allocate_tensors()
ops = {}
for d in it._get_ops_details(): ops[d["op_name"]] = ops.get(d["op_name"], 0) + 1
print(OUT, "ops:", ops)
if T <= 16 and MODE != "nocheck":
    it.set_tensor(it.get_input_details()[0]["index"], xin[None]); it.invoke(); y = it.get_tensor(it.get_output_details()[0]["index"])[0]
    print("TFLite(%s) vs numpy: max|d| %.2e" % (MODE, np.abs(ref - y).max()))
