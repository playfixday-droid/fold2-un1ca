// dacgpu: декодер звука Qwen3-TTS (DAC) на GPU Adreno через TFLite (Fold2).
// latent-файл от qwen-tts (QT_DAC_EXT/QT_DAC_DUMP, патч fold2): заголовок int32 {'DAC1', T, C=1024, drop}, затем f32 [T][1024]
// (50 Гц). Модель dacN.tflite (npu/dac/dac_tf.py): вход [1,N,1024], выход [1,N*480] - фиксированный N, поэтому длинный
// latent идёт кусками по N с левым контекстом CTX кадров (DAC каузальный, рецептивное поле ~20 кадров -> результат тот же).
// Выход: wav 16 бит 24 кГц моно без первых drop кадров (затравка образца голоса).
// Запуск: LD_LIBRARY_PATH=. ./dacgpu dac256.tflite in.lat out.wav [cpu]   (кэш ядер OpenCL: DACGPU_CACHE=dir)
// Сервер (модели загружены один раз, GPU-инициализация ~2 с не на каждую фразу):
//   ./dacgpu serve 8083 dac64.tflite dac256.tflite   запрос по TCP 127.0.0.1: "in.lat<TAB>out.wav\n" -> "ok ...\n" / "err ...\n"
//   кусок берёт самую маленькую модель, в которую влезает, иначе самую большую (и дальше кусками).
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <unistd.h>
#include <signal.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
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

typedef struct { TfLiteInterpreter * it; TfLiteTensor * in; const TfLiteTensor * out; int N; float * buf, * ob; } Model;
enum { C = 1024, HOP = 480, MAXM = 8 };
static Model M[MAXM]; static int NM = 0; static int CTX = 24;

static int load_model(const char * path, int cpu) {
    TfLiteModel * m = TfLiteModelCreateFromFile(path); if (!m) { fprintf(stderr, "model load failed: %s\n", path); return 1; }
    TfLiteInterpreterOptions * o = TfLiteInterpreterOptionsCreate();
    TfLiteInterpreterOptionsSetNumThreads(o, 4);
    if (!cpu) {
        GpuOpts g = TfLiteGpuDelegateOptionsV2Default();
        // DACGPU_PRECISION: f32f16 (по умолчанию: хранение fp16, накопление свёрток fp32), f16 (быстрее, но SNR ~15 дБ
        // против CPU на этой модели), f32 (~1,8x медленнее f16)
        const char * pr = getenv("DACGPU_PRECISION") ? getenv("DACGPU_PRECISION") : "f32f16";
        if (!strcmp(pr, "f32")) g.is_precision_loss_allowed = 0;
        else if (!strcmp(pr, "f16")) g.is_precision_loss_allowed = 1;
        else { g.is_precision_loss_allowed = -1; g.inference_priority1 = 2; g.inference_priority2 = 1; g.inference_priority3 = 3; }  // MIN_LATENCY, MAX_PRECISION, MIN_MEMORY -> F32_F16
        // 0 FAST_SINGLE_ANSWER (быстрая настройка ядер, init ~2 с); 1 SUSTAINED_SPEED - полный перебор размеров групп
        // при каждой инициализации (минуты на этой модели; имеет смысл только с DACGPU_CACHE)
        g.inference_preference = getenv("DACGPU_PREF") ? atoi(getenv("DACGPU_PREF")) : 0;
        const char * cache = getenv("DACGPU_CACHE");
        if (cache) {
            const char * b = strrchr(path, '/'); b = b ? b + 1 : path;
            char tok[256]; snprintf(tok, sizeof(tok), "%s_%s", b, pr);
            g.experimental_flags |= 1 << 3; g.serialization_dir = cache; g.model_token = strdup(tok);
        }
        TfLiteDelegate * d = TfLiteGpuDelegateV2Create(&g); if (!d) { fprintf(stderr, "gpu delegate failed\n"); return 1; }
        TfLiteInterpreterOptionsAddDelegate(o, d);
    }
    Model * x = &M[NM];
    x->it = TfLiteInterpreterCreate(m, o); if (!x->it) { fprintf(stderr, "interpreter failed: %s\n", path); return 1; }
    if (TfLiteInterpreterAllocateTensors(x->it)) { fprintf(stderr, "allocate failed\n"); return 1; }
    x->in = TfLiteInterpreterGetInputTensor(x->it, 0); x->out = TfLiteInterpreterGetOutputTensor(x->it, 0);
    x->N = TfLiteTensorDim(x->in, 1);
    if (TfLiteTensorDim(x->in, 2) != C || x->N <= CTX) { fprintf(stderr, "model input mismatch: %s\n", path); return 1; }
    x->buf = malloc((size_t) x->N * C * 4); x->ob = malloc((size_t) x->N * HOP * 4);
    for (int i = NM; i > 0 && M[i - 1].N > M[i].N; i--) { Model t = M[i]; M[i] = M[i - 1]; M[i - 1] = t; }  // по возрастанию N
    NM++;
    return 0;
}

// latent -> wav; возвращает 0 и пишет сводку в msg
static int decode(const char * lp, const char * wp, char * msg, size_t ml) {
    double t0 = now();
    FILE * f = fopen(lp, "rb"); if (!f) { snprintf(msg, ml, "cannot open %s", lp); return 1; }
    int32_t hd[4]; if (fread(hd, 4, 4, f) != 4 || hd[0] != 0x31434144 || hd[2] != C || hd[1] <= 0) { fclose(f); snprintf(msg, ml, "bad latent header"); return 1; }
    const int T = hd[1], drop = hd[3];
    float * lat = malloc((size_t) T * C * 4);
    if (fread(lat, 4, (size_t) T * C, f) != (size_t) T * C) { fclose(f); free(lat); snprintf(msg, ml, "short latent"); return 1; }
    fclose(f);
    int16_t * pcm = malloc((size_t) T * HOP * 2); size_t np = 0; int chunks = 0; char used[128] = "";
    for (int s = 0; s < T;) {  // s - первый новый кадр куска
        const int c = s == 0 ? 0 : CTX;
        Model * x = &M[NM - 1];
        for (int i = 0; i < NM; i++) if (M[i].N >= c + (T - s)) { x = &M[i]; break; }
        const int b = s - c, n = (T - s < x->N - c) ? T - s : x->N - c;
        memset(x->buf, 0, (size_t) x->N * C * 4);
        memcpy(x->buf, lat + (size_t) b * C, (size_t) (c + n) * C * 4);  // хвост нулями: DAC каузальный, на выход не влияет
        if (TfLiteTensorCopyFromBuffer(x->in, x->buf, (size_t) x->N * C * 4) || TfLiteInterpreterInvoke(x->it) ||
            TfLiteTensorCopyToBuffer(x->out, x->ob, (size_t) x->N * HOP * 4)) { free(lat); free(pcm); snprintf(msg, ml, "invoke failed"); return 1; }
        for (int i = c * HOP; i < (c + n) * HOP; i++) {
            if ((size_t) s * HOP + (i - c * HOP) < (size_t) drop * HOP) continue;
            float v = x->ob[i]; v = v > 1 ? 1 : v < -1 ? -1 : v; pcm[np++] = (int16_t) lrintf(v * 32767.0f);
        }
        snprintf(used + strlen(used), sizeof(used) - strlen(used), "%s%d", chunks ? "+" : "", x->N);
        s += n; chunks++;
    }
    free(lat);
    double t1 = now();
    FILE * w = fopen(wp, "wb"); if (!w) { free(pcm); snprintf(msg, ml, "cannot write %s", wp); return 1; }
    fwrite("RIFF", 1, 4, w); wr32(w, 36 + np * 2); fwrite("WAVEfmt ", 1, 8, w); wr32(w, 16); wr16(w, 1); wr16(w, 1); wr32(w, 24000); wr32(w, 48000); wr16(w, 2); wr16(w, 16);
    fwrite("data", 1, 4, w); wr32(w, np * 2); fwrite(pcm, 2, np, w); fclose(w); free(pcm);
    snprintf(msg, ml, "T=%d drop=%d models=%s decode %.2f s audio %.2f s", T, drop, used, t1 - t0, np / 24000.0);
    return 0;
}

static int serve(int port) {
    signal(SIGPIPE, SIG_IGN);
    int s = socket(AF_INET, SOCK_STREAM, 0), one = 1; setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in a = { 0 }; a.sin_family = AF_INET; a.sin_port = htons(port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(s, (struct sockaddr *) &a, sizeof(a)) || listen(s, 4)) { perror("bind"); return 1; }
    fprintf(stderr, "dacgpu: serving on 127.0.0.1:%d, models", port); for (int i = 0; i < NM; i++) fprintf(stderr, " %d", M[i].N); fprintf(stderr, "\n");
    for (;;) {
        int c = accept(s, NULL, NULL); if (c < 0) continue;
        char req[2048]; size_t n = 0; ssize_t r;
        while (n < sizeof(req) - 1 && (r = read(c, req + n, sizeof(req) - 1 - n)) > 0) { n += r; if (memchr(req, '\n', n)) break; }
        req[n] = 0; char * nl = strchr(req, '\n'); if (nl) *nl = 0;
        char msg[512], resp[600]; char * tab = strchr(req, '\t');
        if (!strcmp(req, "ping")) snprintf(resp, sizeof(resp), "ok pong\n");
        else if (!tab) snprintf(resp, sizeof(resp), "err usage: in.lat<TAB>out.wav\n");
        else { *tab = 0; int e = decode(req, tab + 1, msg, sizeof(msg)); snprintf(resp, sizeof(resp), "%s %s\n", e ? "err" : "ok", msg); fprintf(stderr, "dacgpu: %s", resp); }
        if (write(c, resp, strlen(resp)) < 0) {}
        close(c);
    }
}

int main(int argc, char ** argv) {
    if (getenv("DACGPU_CTX")) CTX = atoi(getenv("DACGPU_CTX"));
    if (argc >= 4 && !strcmp(argv[1], "serve")) {
        const int cpu = getenv("DACGPU_CPU") != NULL; double t0 = now();
        for (int i = 3; i < argc && NM < MAXM; i++) if (load_model(argv[i], cpu)) return 1;
        fprintf(stderr, "dacgpu: %s, init %.2f s\n", cpu ? "cpu" : "gpu", now() - t0);
        return serve(atoi(argv[2]));
    }
    if (argc < 4) { fprintf(stderr, "usage: %s model.tflite in.lat out.wav [cpu] | %s serve PORT model.tflite...\n", argv[0], argv[0]); return 2; }
    const int cpu = argc > 4 && !strcmp(argv[4], "cpu");
    double t0 = now();
    if (load_model(argv[1], cpu)) return 1;
    double t1 = now(); char msg[512];
    int e = decode(argv[2], argv[3], msg, sizeof(msg));
    fprintf(stderr, "dacgpu: %s init %.2f s, %s\n", cpu ? "cpu" : "gpu", t1 - t0, msg);
    return e;
}
