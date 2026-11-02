// kernel_test.c - проверка формата f2q и ядра: эталон ggml (float) vs f2q_mm_tiles_ref vs f2q_mm_tiles (HVX).
// Хост: cc -O2 -I.. kernel_test.c ../dsp/f2q_kernel.c ../common/f2q_pack.c -lm
// Hexagon (qemu-hexagon): clang --target=hexagon-unknown-linux-musl -mv66 -mhvx -mhvx-length=128b -O2 ... -static
#include "../common/f2q_format.h"
#include "../common/f2q_pack.h"
#include "../dsp/f2q_kernel.h"
#ifdef F2Q_TEST_CPU
#include "../ap/f2q_cpu.h"
#endif
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// aligned_alloc по C11 требует размер, кратный выравниванию
static void * al128(size_t n) { return aligned_alloc(128, (n + 127) & ~(size_t) 127); }

static uint32_t rng = 12345;
static float frand(void) { rng = rng * 1664525u + 1013904223u; return (float) ((rng >> 8) & 0xFFFF) / 32768.0f - 1.0f; }

static void q8_0_row(const float * x, int K, uint8_t * out) { // как quantize_row_q8_0_ref
    for (int b = 0; b < K / 32; b++) {
        float amax = 0;
        for (int j = 0; j < 32; j++) if (fabsf(x[b * 32 + j]) > amax) amax = fabsf(x[b * 32 + j]);
        const float d = amax / 127.0f, id = d ? 1.0f / d : 0.0f;
        const uint16_t dh = f2q_fp32_to_fp16(d);
        memcpy(out + b * 34, &dh, 2);
        for (int j = 0; j < 32; j++) out[b * 34 + 2 + j] = (uint8_t) (int8_t) roundf(x[b * 32 + j] * id);
    }
}
static void q4_0_row(const float * x, int K, uint8_t * out) { // как quantize_row_q4_0_ref
    for (int b = 0; b < K / 32; b++) {
        float amax = 0, max = 0;
        for (int j = 0; j < 32; j++) { const float v = x[b * 32 + j]; if (amax < fabsf(v)) { amax = fabsf(v); max = v; } }
        const float d = max / -8, id = d ? 1.0f / d : 0.0f;
        const uint16_t dh = f2q_fp32_to_fp16(d);
        memcpy(out + b * 18, &dh, 2);
        for (int j = 0; j < 16; j++) {
            int a = (int8_t) (x[b * 32 + j] * id + 8.5f), c = (int8_t) (x[b * 32 + 16 + j] * id + 8.5f);
            if (a > 15) a = 15;
            if (c > 15) c = 15;
            out[b * 18 + 2 + j] = (uint8_t) (a | (c << 4));
        }
    }
}
// ggml vec_dot (q4_0/q8_0 x q8_0): sum_b d_w*d_x*sum(q_w*q_x)
static float ggml_dot(const uint8_t * w, int wtype, const uint8_t * xq8, int K) {
    float s = 0;
    for (int b = 0; b < K / 32; b++) {
        uint16_t dh, xh;
        memcpy(&xh, xq8 + b * 34, 2);
        int acc = 0;
        if (wtype == F2Q_W_Q8) {
            memcpy(&dh, w + b * 34, 2);
            for (int j = 0; j < 32; j++) acc += (int8_t) w[b * 34 + 2 + j] * (int8_t) xq8[b * 34 + 2 + j];
        } else {
            memcpy(&dh, w + b * 18, 2);
            for (int j = 0; j < 16; j++) {
                acc += ((w[b * 18 + 2 + j] & 15) - 8) * (int8_t) xq8[b * 34 + 2 + j];
                acc += ((w[b * 18 + 2 + j] >> 4) - 8) * (int8_t) xq8[b * 34 + 2 + 16 + j];
            }
        }
        s += f2q_fp16_to_fp32(dh) * f2q_fp16_to_fp32(xh) * (float) acc;
    }
    return s;
}

// big != 0: «массивная активация» - канал K/3 каждой строки равен ±|big| (у LLM бывает в 1000+ раз больше остальных).
// Ошибка считается от выхода без этого канала, чтобы потеря точности на остальных каналах не пряталась за ним.
//   big < 0: веса этого канала - нули: выход - только остальные каналы, порог как обычно (1e-6; формат v1 - ~1e-5);
//   big > 0: остаётся ошибка самого массивного вклада (масштабы 15 бит - в 16 раз точнее fp16 в ggml), порог 1e-5.
// tiny: блоки b % 5 == 1 в 1e-12 раз меньше (экспонента и сдвиги на пределе), последняя строка - нули.
static int run(int wtype, int M, int K, int n, float big, int tiny) {
    const int nb = K / 32, bsz = wtype == F2Q_W_Q4 ? 18 : 34, tiles = (M + 31) / 32;
    float * W = malloc(sizeof(float) * M * K), * X = malloc(sizeof(float) * n * K);
    for (int r = 0; r < M; r++) { const float sc = 0.01f + 0.5f * (r % 7); for (int i = 0; i < K; i++) W[r * K + i] = frand() * sc * (i % 61 == 0 ? 8 : 1); }
    if (big < 0) for (int r = 0; r < M; r++) W[r * K + K / 3] = 0.0f; // массивный канал умножается на 0
    const double lim = big > 0 ? 1e-5 : 1e-6;
    big = big < 0 ? -big : big;
    if (tiny) for (int i = 0; i < n * K; i++) if ((i % K) / 32 % 5 == 1) X[i] *= 1e-12f;
    if (tiny) for (int i = 0; i < K; i++) X[(n - 1) * K + i] = 0.0f;
    for (int i = 0; i < n * K; i++) X[i] = frand() * (i % 37 == 0 ? 20 : 1);
    uint8_t * wq = malloc((size_t) M * nb * bsz), * xq8 = malloc((size_t) n * nb * 34), * xz8 = malloc((size_t) n * nb * 34);
    for (int r = 0; r < M; r++) (wtype == F2Q_W_Q4 ? q4_0_row : q8_0_row)(W + r * K, K, wq + (size_t) r * nb * bsz);
    for (int t = 0; t < n; t++) { // xz8 - строки без массивного канала (для нормировки ошибки)
        if (big != 0.0f) X[t * K + K / 3] = 0.0f;
        q8_0_row(X + t * K, K, xz8 + (size_t) t * nb * 34);
        if (big != 0.0f) X[t * K + K / 3] = t % 2 ? -big : big;
        q8_0_row(X + t * K, K, xq8 + (size_t) t * nb * 34);
    }
    const uint32_t tb = f2q_tile_bytes(wtype, K), xs = f2q_x_stride(K);
    const int ys = tiles * 32;
    uint8_t * wp = al128((size_t) tiles * tb), * xp = al128((size_t) n * xs);
    float * y0 = al128(sizeof(float) * n * ys), * y1 = al128(sizeof(float) * n * ys);
    f2q_pack_weights(wq, wtype, M, K, wp, 0, tiles);
    for (int t = 0; t < n; t++) f2q_quant_x(X + t * K, K, xp + (size_t) t * xs);
    // проверка обратной распаковки (q точно, d - до округления fp16)
    uint8_t * wu = malloc((size_t) M * nb * bsz);
    f2q_unpack_weights(wp, wtype, M, K, wu);
    int bad_q = 0;
    for (int r = 0; r < M; r++) for (int b = 0; b < nb; b++)
        if (memcmp(wu + ((size_t) r * nb + b) * bsz + 2, wq + ((size_t) r * nb + b) * bsz + 2, bsz - 2)) bad_q++;
    f2q_mm_tiles_ref(wp, wtype, K, 0, tiles, xp, n, xs, y0, ys);
    clock_t c0 = clock();
    f2q_mm_tiles(wp, wtype, K, 0, tiles, xp, n, xs, y1, ys);
    const double ms = (double) (clock() - c0) * 1000.0 / CLOCKS_PER_SEC;
    double err = 0, ref2 = 0;
    int mism = 0;
    for (int t = 0; t < n; t++) for (int r = 0; r < M; r++) {
        const float g = ggml_dot(wq + (size_t) r * nb * bsz, wtype, xq8 + (size_t) t * nb * 34, K);
        const float g0 = ggml_dot(wq + (size_t) r * nb * bsz, wtype, xz8 + (size_t) t * nb * 34, K);
        const float a = y0[t * ys + r];
        err += (double) (a - g) * (a - g); ref2 += (double) g0 * g0;
        if (memcmp(&y0[t * ys + r], &y1[t * ys + r], 4)) mism++;
    }
#ifdef F2Q_TEST_CPU
    { // ARM-часть: только первые M строк, бит в бит как эталон
        float * y2 = al128(sizeof(float) * n * M);
        f2q_cpu_tiles(wp, wtype, K, 0, tiles, xp, n, xs, y2, M, M);
        int cm = 0;
        for (int t = 0; t < n; t++) for (int r = 0; r < M; r++) if (memcmp(&y0[t * ys + r], &y2[t * M + r], 4)) cm++;
        printf("  CPU-ядро != эталон: %d\n", cm);
        mism += cm;
        free(y2);
    }
#endif
    const double nmse = err / (ref2 ? ref2 : 1);
    const int ok = bad_q == 0 && mism == 0 && nmse < lim;
    printf("%s M=%d K=%d n=%d%s: NMSE(f2q vs ggml)=%.3g, HVX!=ref: %d, unpack q errors: %d, %.1f ms  %s\n",
           wtype == F2Q_W_Q4 ? "Q4_0" : "Q8_0", M, K, n, big != 0.0f ? (lim > 1e-6 ? " массивная активация" : " массивная активация x 0") : tiny ? " крошечные блоки" : "", nmse, mism, bad_q, ms,
           ok ? "OK" : "FAIL");
    free(W); free(X); free(wq); free(xq8); free(xz8); free(wp); free(xp); free(y0); free(y1); free(wu);
    return ok ? 0 : 1;
}

// худшие веса (|w - off| на границе, знак как у q, масштаб 32767) на строках активаций с масштабами блоков от 1e-22
// до 1e5 и всеми q = ±127: сдвиги из f2q_quant_x не должны переполнять int32 ни в произведении, ни в сумме
static int overflow_fuzz(void) {
    uint32_t rs = 7;
    int bad = 0, rows = 0;
    for (int it = 0; it < 600; it++) {
        rs = rs * 1664525u + 1013904223u;
        const int nb = 1 + (int) (rs >> 8) % (it < 500 ? 64 : 4096), K = nb * 32, mode = it % 4;
        float * x = malloc(sizeof(float) * K);
        uint8_t * xr = al128(f2q_x_stride(K));
        for (int b = 0; b < nb; b++) {
            rs = rs * 1664525u + 1013904223u;
            float sc = mode == 0 ? 1.0f : powf(10.0f, (float) ((int) ((rs >> 8) % 28) - 22));
            if (mode == 3 && (rs >> 4) % 3 == 0) sc = 0.0f;
            for (int j = 0; j < 32; j++) x[b * 32 + j] = (mode == 2 ? (j & 1 ? 1.0f : -1.0f) : frand()) * sc;
        }
        f2q_quant_x(x, K, xr);
        const int32_t * mx = (const int32_t *) (xr + f2q_x_mx(K));
        const int8_t * q = (const int8_t *) xr;
        for (int wt = 0; wt < 2; wt++, rows++) {
            const int64_t wmax = wt == F2Q_W_Q4 ? 8 : 128;
            int64_t tot = 0;
            int over = 0;
            for (int b = 0; b < nb; b++) {
                int64_t a = 0;
                for (int j = 0; j < 32; j++) a += wmax * (q[b * 32 + j] < 0 ? -q[b * 32 + j] : q[b * 32 + j]);
                a <<= f2q_mx_l(mx[b], wt);
                if (a > (1LL << 30)) over = 1;
                tot += f2q_rsh(f2q_mulhi(f2q_mulhi((int32_t) a, 32767), f2q_mx_m(mx[b])), f2q_mx_r(mx[b]));
                if (tot > INT32_MAX || tot < INT32_MIN) over = 1;
            }
            bad += over;
        }
        free(x); free(xr);
    }
    printf("переполнение int32 на худших весах: %d из %d строк  %s\n", bad, rows, bad ? "FAIL" : "OK");
    return bad != 0;
}

int main(void) {
#if defined(__HVX__)
    printf("HVX %d байт, Hexagon v%d\n", __HVX_LENGTH__, __HEXAGON_ARCH__);
#else
    printf("скалярная версия (без HVX)\n");
#endif
    int bad = 0;
    bad += run(F2Q_W_Q8, 64, 256, 1, 0, 0);
    bad += run(F2Q_W_Q4, 64, 256, 1, 0, 0);
    bad += run(F2Q_W_Q8, 70, 96, 7, 0, 0);   // неполная плитка, нечётное число блоков
    bad += run(F2Q_W_Q4, 70, 96, 7, 0, 0);
    bad += run(F2Q_W_Q4, 128, 2048, 9, 0, 0);
    bad += run(F2Q_W_Q8, 96, 1024, 5, 0, 0);
    bad += run(F2Q_W_Q4, 64, 2048, 5, -2000, 0); // формат v1: 7.8e-6
    bad += run(F2Q_W_Q8, 64, 4096, 3, -3000, 0); // v1: 3.3e-5
    bad += run(F2Q_W_Q4, 64, 2048, 5, 2000, 0);  // v1: 1.3e-5
    bad += run(F2Q_W_Q8, 64, 4096, 3, 3000, 0);  // v1: 2.6e-5
    bad += run(F2Q_W_Q4, 70, 1024, 6, 0, 1);
    bad += run(F2Q_W_Q8, 70, 1024, 6, 0, 1);
    bad += overflow_fuzz();
    printf(bad ? "ЕСТЬ ОШИБКИ\n" : "ВСЕ ТЕСТЫ ПРОШЛИ\n");
    return bad ? 1 : 0;
}
