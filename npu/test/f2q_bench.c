// f2q_bench.c - проверка и замер f2qdsp на телефоне: DSP против CPU (NEON) на случайной матрице.
// f2q-bench [M K] : для Q4 и Q8, n = 1 (генерация) и n = 64 (обработка промпта)
// Нужно: F2QDSP=1, root (или доступ к /dev/adsprpc-smd), libf2qdsp_skel.so в ADSP_LIBRARY_PATH.
#include "../ap/f2q_cpu.h"
#include "../ap/f2q_dev.h"
#include "../common/f2q_format.h"
#include "../common/f2q_pack.h"
#include "../dsp/f2q_kernel.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t rs = 2463534242u;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }

typedef struct { const uint8_t * w; int wtype, k, t0, t1; const uint8_t * x; int n, xs; float * y; int ys, m; } job;
static void * cpu_job(void * p) {
    job * j = (job *) p;
    f2q_cpu_tiles(j->w, j->wtype, j->k, j->t0, j->t1, j->x, j->n, j->xs, j->y, j->ys, j->m);
    return NULL;
}
static void cpu_mm(int nth, const uint8_t * w, int wtype, int k, int tiles, const uint8_t * x, int n, int xs, float * y, int ys, int m) {
    pthread_t th[16];
    job       j[16];
    if (nth > 16) nth = 16;
    for (int i = 0; i < nth; i++) {
        j[i] = (job) { w, wtype, k, tiles * i / nth, tiles * (i + 1) / nth, x, n, xs, y, ys, m };
        if (i) pthread_create(&th[i], NULL, cpu_job, &j[i]);
    }
    cpu_job(&j[0]);
    for (int i = 1; i < nth; i++) pthread_join(th[i], NULL);
}

int main(int argc, char ** argv) {
    const int M = argc > 1 ? atoi(argv[1]) : 2048, K = argc > 2 ? atoi(argv[2]) : 2048;
    const int nth = getenv("THREADS") ? atoi(getenv("THREADS")) : 4;
    if (M <= 0 || K <= 0 || K % 32) { fprintf(stderr, "K должно делиться на 32\n"); return 2; }
    const int dsp = f2q_dev_init();
    printf("f2qdsp: %s\nстатус: %s\n", dsp ? "DSP ГОТОВ" : "DSP недоступен", f2q_dev_status());
    const int nb = K / 32, tiles = (M + 31) / 32, ns[2] = { 1, 64 };
    const size_t xs = f2q_x_stride(K);
    int fails = 0;
    for (int wt = 0; wt < 2; wt++) {
        const int wtype = wt ? F2Q_W_Q8 : F2Q_W_Q4, bsz = wtype == F2Q_W_Q4 ? 18 : 34;
        const size_t wb = (size_t) tiles * f2q_tile_bytes(wtype, K);
        uint8_t * src = (uint8_t *) malloc((size_t) M * nb * bsz);
        uint8_t * w   = (uint8_t *) f2q_dev_alloc(wb);
        if (!src || !w) { fprintf(stderr, "нет памяти\n"); return 1; }
        for (size_t i = 0; i < (size_t) M * nb; i++) {
            uint8_t * b = src + i * bsz;
            const uint16_t d = f2q_fp32_to_fp16(0.001f + (float) (rnd() % 1000) * 1e-5f);
            memcpy(b, &d, 2);
            for (int q = 2; q < bsz; q++) b[q] = (uint8_t) (wtype == F2Q_W_Q4 ? rnd() : (rnd() % 255) + 129);
        }
        f2q_pack_weights(src, wtype, M, K, w, 0, tiles);
        f2q_dev_weights_written(w, wb);
        const int shared = f2q_dev_is_shared(w, wb);
        for (int ni = 0; ni < 2; ni++) {
            const int n = ns[ni], ys = tiles * 32;
            uint8_t * x  = (uint8_t *) malloc((size_t) n * xs);
            float *   yc = (float *) calloc((size_t) n * ys, 4);
            float *   xf = (float *) malloc(sizeof(float) * (size_t) K * n);
            for (size_t i = 0; i < (size_t) K * n; i++) xf[i] = (float) ((int) (rnd() % 2001) - 1000) / 1000.0f;
            for (int t = 0; t < n; t++) f2q_quant_x(xf + (size_t) t * K, K, x + (size_t) t * xs);
            const int it = n == 1 ? 50 : 5;
            cpu_mm(nth, w, wtype, K, tiles, x, n, (int) xs, yc, ys, M);
            int64_t t0 = f2q_dev_time_us();
            for (int r = 0; r < it; r++) cpu_mm(nth, w, wtype, K, tiles, x, n, (int) xs, yc, ys, M);
            const double tc = (double) (f2q_dev_time_us() - t0) / it;
            const double gop = 2.0 * M * K * n / 1e9;
            printf("%s M=%d K=%d n=%-3d CPU(%d потока): %8.0f мкс %6.1f GOPS", wtype == F2Q_W_Q4 ? "Q4" : "Q8", M, K, n, nth, tc, gop / (tc / 1e6));
            uint8_t * dx;
            float *   dy;
            if (dsp && shared && f2q_dev_begin((size_t) n * xs, (size_t) n * ys * 4, &dx, &dy)) {
                memcpy(dx, x, (size_t) n * xs);
                int rc = f2q_dev_mm(w, wb, wtype, K, tiles, dx, n, (int) xs, dy, ys);
                t0 = f2q_dev_time_us();
                for (int r = 0; r < it && !rc; r++) rc = f2q_dev_mm(w, wb, wtype, K, tiles, dx, n, (int) xs, dy, ys);
                const double td = (double) (f2q_dev_time_us() - t0) / it;
                int bad = 0;
                for (int t = 0; t < n && !rc; t++) bad += memcmp(dy + (size_t) t * ys, yc + (size_t) t * ys, (size_t) M * 4) != 0;
                f2q_dev_end();
                if (rc) printf(" | DSP: ошибка rc=0x%x\n", (unsigned) rc);
                else printf(" | DSP: %8.0f мкс %6.1f GOPS %s\n", td, gop / (td / 1e6), bad ? "РАСХОЖДЕНИЕ" : "совпадает с CPU");
                fails += rc != 0 || bad != 0;
            } else {
                printf(" | DSP: -\n");
            }
            // контроль CPU против эталона
            float * yr = (float *) calloc((size_t) n * ys, 4);
            f2q_mm_tiles_ref(w, wtype, K, 0, tiles, x, n, (int) xs, yr, ys);
            for (int t = 0; t < n; t++) if (memcmp(yr + (size_t) t * ys, yc + (size_t) t * ys, (size_t) M * 4)) { fails++; printf("CPU != эталон (строка %d)\n", t); break; }
            free(yr); free(x); free(yc); free(xf);
        }
        f2q_dev_free(w);
        free(src);
    }
    printf(fails ? "ИТОГ: ЕСТЬ ОШИБКИ\n" : "ИТОГ: OK\n");
    return fails ? 1 : 0;
}
