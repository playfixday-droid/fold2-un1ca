// dacgpu: декодер звука Qwen3-TTS (DAC) на GPU Adreno через TFLite (Fold2).
// latent-файл от qwen-tts (QT_DAC_EXT/QT_DAC_DUMP, патч fold2): заголовок int32 {'DAC1', T, C=1024, drop}, затем f32 [T][1024]
// (50 Гц). Модель dacN.tflite (npu/dac/dac_tf.py): вход [1,N,1024], выход [1,N*480] - фиксированный N, поэтому длинный
// latent идёт кусками по N с левым контекстом CTX кадров (DAC каузальный, рецептивное поле ~20 кадров -> результат тот же).
// Выход: wav 16 бит 24 кГц моно без первых drop кадров (затравка образца голоса).
// Запуск: LD_LIBRARY_PATH=. ./dacgpu dac256.tflite in.lat out.wav [cpu] (от root или shell; кэш ядер OpenCL: DACGPU_CACHE=dir)
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
typedef struct TfLiteModel TfLiteModel;
typedef struct TfLiteInterpreterOptions TfLiteInterpreterOptions;
typedef struct TfLiteInterpreter TfLiteInterpreter;
typedef struct TfLiteTensor TfLiteTensor;
typedef struct TfLiteDelegate TfLiteDelegate;
TfLiteModel * TfLiteModelCreateFromFile(const char *);
TfLiteInterpreterOptions * TfLiteInterpreterOptionsCreate(void);
void TfLiteInterpreterOptionsSetNumThreads(TfLiteInterpreterOptions *, int32_t);
void TfLiteInterpreterOptionsAddDelegate(TfLiteInterpreterOptions *, TfLiteDelegate *);
TfLiteInterpreter * TfLiteInterpreterCreate(const TfLiteModel *, const TfLiteInterpreterOptions *);
int TfLiteInterpreterAllocateTensors(TfLiteInterpreter *);
TfLiteTensor * TfLiteInterpreterGetInputTensor(const TfLiteInterpreter *, int32_t);
const TfLiteTensor * TfLiteInterpreterGetOutputTensor(const TfLiteInterpreter *, int32_t);
int TfLiteInterpreterInvoke(TfLiteInterpreter *);
int32_t TfLiteTensorDim(const TfLiteTensor *, int32_t);
int TfLiteTensorCopyFromBuffer(TfLiteTensor *, const void *, size_t);
int TfLiteTensorCopyToBuffer(const TfLiteTensor *, void *, size_t);
typedef struct {
    int32_t is_precision_loss_allowed, inference_preference, inference_priority1, inference_priority2, inference_priority3;
    int64_t experimental_flags;
    int32_t max_delegated_partitions;
    const char *serialization_dir, *model_token;
    int pad[8];  // запас под поля отладочных сборок
} GpuOpts;
GpuOpts TfLiteGpuDelegateOptionsV2Default(void);
TfLiteDelegate * TfLiteGpuDelegateV2Create(const GpuOpts *);

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static void wr32(FILE * f, uint32_t v) { fwrite(&v, 4, 1, f); }
static void wr16(FILE * f, uint16_t v) { fwrite(&v, 2, 1, f); }

int main(int argc, char ** argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s model.tflite in.lat out.wav [cpu]\n", argv[0]); return 2; }
    const int cpu = argc > 4 && !strcmp(argv[4], "cpu");
    const int CTX = getenv("DACGPU_CTX") ? atoi(getenv("DACGPU_CTX")) : 24;
    double t0 = now();
    FILE * f = fopen(argv[2], "rb"); if (!f) { perror(argv[2]); return 1; }
    int32_t hd[4]; if (fread(hd, 4, 4, f) != 4 || hd[0] != 0x31434144 || hd[2] != 1024) { fprintf(stderr, "bad latent header\n"); return 1; }
    const int T = hd[1], C = hd[2], drop = hd[3];
    float * lat = malloc((size_t) T * C * 4);
    if (fread(lat, 4, (size_t) T * C, f) != (size_t) T * C) { fprintf(stderr, "short latent\n"); return 1; }
    fclose(f);
    TfLiteModel * m = TfLiteModelCreateFromFile(argv[1]); if (!m) { fprintf(stderr, "model load failed\n"); return 1; }
    TfLiteInterpreterOptions * o = TfLiteInterpreterOptionsCreate();
    TfLiteInterpreterOptionsSetNumThreads(o, 4);
    if (!cpu) {
        GpuOpts g = TfLiteGpuDelegateOptionsV2Default();
        g.is_precision_loss_allowed = getenv("DACGPU_FP32") ? 0 : 1;
        g.inference_preference = 1;  // SUSTAINED_SPEED
        const char * cache = getenv("DACGPU_CACHE");
        if (cache) { g.experimental_flags |= 1 << 3; g.serialization_dir = cache; g.model_token = getenv("DACGPU_TOKEN") ? getenv("DACGPU_TOKEN") : "dac"; }
        TfLiteDelegate * d = TfLiteGpuDelegateV2Create(&g); if (!d) { fprintf(stderr, "gpu delegate failed\n"); return 1; }
        TfLiteInterpreterOptionsAddDelegate(o, d);
    }
    TfLiteInterpreter * it = TfLiteInterpreterCreate(m, o); if (!it) { fprintf(stderr, "interpreter failed\n"); return 1; }
    if (TfLiteInterpreterAllocateTensors(it)) { fprintf(stderr, "allocate failed\n"); return 1; }
    TfLiteTensor * in = TfLiteInterpreterGetInputTensor(it, 0); const TfLiteTensor * out = TfLiteInterpreterGetOutputTensor(it, 0);
    const int N = TfLiteTensorDim(in, 1), HOP = 480;
    if (TfLiteTensorDim(in, 2) != C || N <= CTX) { fprintf(stderr, "model input mismatch\n"); return 1; }
    double t1 = now();
    float * buf = malloc((size_t) N * C * 4), * ob = malloc((size_t) N * HOP * 4);
    int16_t * pcm = malloc((size_t) T * HOP * 2); size_t np = 0; int chunks = 0;
    for (int s = 0; s < T;) {  // s - первый новый кадр куска
        const int c = s == 0 ? 0 : CTX, b = s - c, n = (T - s < N - c) ? T - s : N - c;
        memset(buf, 0, (size_t) N * C * 4);
        memcpy(buf, lat + (size_t) b * C, (size_t) (c + n) * C * 4);  // хвост нулями: каузально, на выход не влияет
        if (TfLiteTensorCopyFromBuffer(in, buf, (size_t) N * C * 4) || TfLiteInterpreterInvoke(it) || TfLiteTensorCopyToBuffer(out, ob, (size_t) N * HOP * 4)) { fprintf(stderr, "invoke failed\n"); return 1; }
        for (int i = c * HOP; i < (c + n) * HOP; i++) {
            if (s * HOP + (i - c * HOP) < drop * HOP) continue;
            float v = ob[i]; v = v > 1 ? 1 : v < -1 ? -1 : v; pcm[np++] = (int16_t) lrintf(v * 32767.0f);
        }
        s += n; chunks++;
    }
    double t2 = now();
    FILE * w = fopen(argv[3], "wb"); if (!w) { perror(argv[3]); return 1; }
    fwrite("RIFF", 1, 4, w); wr32(w, 36 + np * 2); fwrite("WAVEfmt ", 1, 8, w); wr32(w, 16); wr16(w, 1); wr16(w, 1); wr32(w, 24000); wr32(w, 48000); wr16(w, 2); wr16(w, 16);
    fwrite("data", 1, 4, w); wr32(w, np * 2); fwrite(pcm, 2, np, w); fclose(w);
    fprintf(stderr, "dacgpu: %s T=%d drop=%d N=%d chunks=%d init %.2f s, decode %.2f s, audio %.2f s\n", cpu ? "cpu" : "gpu", T, drop, N, chunks, t1 - t0, t2 - t1, np / 24000.0);
    return 0;
}
