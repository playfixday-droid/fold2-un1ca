// f2qdsp_imp.c - DSP-часть (skel) драйвера f2qdsp: cDSP Hexagon 698 (v66, HVX 128B) в unsigned PD.
// Методы интерфейса из idl/f2qdsp.idl; маршалинг - f2qdsp_skel.c (генерирует qaic).
#include <stdlib.h>
#include <string.h>
#include "AEEStdErr.h"
#include "HAP_power.h"
#include "qurt.h"
#include "f2qdsp.h"
#include "../common/f2q_format.h"
#include "f2q_kernel.h"

#define F2Q_MAXT  4
#define F2Q_STACK 16384

typedef struct {
    const uint8_t * w; int wtype, k, tile0, tile1;
    const uint8_t * x; int n, xstride;
    float * y; int ystride;
    int hvx; // 1 - HVX захвачен
} f2q_job;

static uint8_t f2q_stacks[F2Q_MAXT][F2Q_STACK] __attribute__((aligned(128)));
static int f2q_stacks_busy; // стеки общие: второй одновременный вызов f2qdsp_mm считает в своём потоке
static void * f2q_power_ctx;
static int f2q_power_ok = -1;

static void f2q_run(f2q_job * j) {
    j->hvx = qurt_hvx_lock(QURT_HVX_MODE_128B) == 0;
    if (j->hvx) {
        f2q_mm_tiles(j->w, j->wtype, j->k, j->tile0, j->tile1, j->x, j->n, j->xstride, j->y, j->ystride);
        qurt_hvx_unlock();
    } else { // без HVX - медленная скалярная версия, зато результат верный
        f2q_mm_tiles_ref(j->w, j->wtype, j->k, j->tile0, j->tile1, j->x, j->n, j->xstride, j->y, j->ystride);
    }
}

static void f2q_worker(void * arg) {
    f2q_run((f2q_job *) arg);
    qurt_thread_exit(0);
}

// частота ядра DSP и шины при работе: F2Q_CORNER (сборка), по умолчанию TURBO_PLUS (как у llama.cpp Hexagon / замеры
// HVX GEMV других проектов); если прошивка его не берёт - TURBO, как раньше
#ifndef F2Q_CORNER
#define F2Q_CORNER HAP_DCVS_VCORNER_TURBO_PLUS
#endif
static int f2q_corner = -1;

static int f2q_vote_c(int level, int corner);
static int f2q_vote(int level) {
    int e = f2q_vote_c(level, F2Q_CORNER);
    if (level && (e & 2) && F2Q_CORNER != HAP_DCVS_VCORNER_TURBO) e = f2q_vote_c(level, HAP_DCVS_VCORNER_TURBO);
    return e;
}

static int f2q_vote_c(int level, int corner) {
    if (!f2q_power_ctx) f2q_power_ctx = malloc(1);
    HAP_power_request_t r;
    memset(&r, 0, sizeof(r));
    r.type = HAP_power_set_HVX;
    r.hvx.power_up = level ? TRUE : FALSE;
    int e1 = HAP_power_set(f2q_power_ctx, &r);
    memset(&r, 0, sizeof(r));
    r.type = HAP_power_set_DCVS_v3;
    r.dcvs_v3.set_dcvs_enable = TRUE;
    r.dcvs_v3.dcvs_enable = level ? FALSE : TRUE;
    r.dcvs_v3.dcvs_option = HAP_DCVS_V2_PERFORMANCE_MODE;
    r.dcvs_v3.set_latency = TRUE;
    r.dcvs_v3.latency = level ? 100 : 65535;
    r.dcvs_v3.set_core_params = TRUE;
    r.dcvs_v3.core_params.min_corner = level ? (HAP_dcvs_voltage_corner_t) corner : HAP_DCVS_VCORNER_DISABLE;
    r.dcvs_v3.core_params.max_corner = level ? (HAP_dcvs_voltage_corner_t) corner : HAP_DCVS_VCORNER_DISABLE;
    r.dcvs_v3.core_params.target_corner = level ? (HAP_dcvs_voltage_corner_t) corner : HAP_DCVS_VCORNER_DISABLE;
    r.dcvs_v3.set_bus_params = TRUE;
    r.dcvs_v3.bus_params.min_corner = level ? (HAP_dcvs_voltage_corner_t) corner : HAP_DCVS_VCORNER_DISABLE;
    r.dcvs_v3.bus_params.max_corner = level ? (HAP_dcvs_voltage_corner_t) corner : HAP_DCVS_VCORNER_DISABLE;
    r.dcvs_v3.bus_params.target_corner = level ? (HAP_dcvs_voltage_corner_t) corner : HAP_DCVS_VCORNER_DISABLE;
    r.dcvs_v3.set_sleep_disable = TRUE;
    r.dcvs_v3.sleep_disable = level ? HAP_DCVS_LPM_LEVEL1 : HAP_DCVS_LPM_ENABLE_ALL;
    int e2 = HAP_power_set(f2q_power_ctx, &r);
    f2q_power_ok = (e1 == 0 ? 0 : 1) | (e2 == 0 ? 0 : 2);
    if (level && e2 == 0) f2q_corner = corner;
    return f2q_power_ok;
}

int f2qdsp_open(const char * uri, remote_handle64 * h) {
    (void) uri;
    void * c = malloc(16);
    if (!c) return AEE_ENOMEMORY;
    f2q_vote(1);
    *h = (remote_handle64) (uintptr_t) c;
    return AEE_SUCCESS;
}

int f2qdsp_close(remote_handle64 h) {
    f2q_vote(0);
    free((void *) (uintptr_t) h);
    return AEE_SUCCESS;
}

// деление без __hexagon_udivsi3 (на DSP нет гарантии, что рантайм его экспортирует)
static unsigned f2q_udiv(unsigned a, unsigned b) {
    unsigned q = 0, r = 0;
    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((a >> i) & 1);
        if (r >= b) { r -= b; q |= 1u << i; }
    }
    return q;
}

static char * f2q_puts(char * p, char * end, const char * s) { while (*s && p < end) *p++ = *s++; return p; }
static char * f2q_putu(char * p, char * end, unsigned v) {
    char b[12]; int n = 0;
    do { const unsigned q = f2q_udiv(v, 10); b[n++] = (char) ('0' + (v - q * 10)); v = q; } while (v);
    while (n && p < end) *p++ = b[--n];
    return p;
}

int f2qdsp_info(remote_handle64 h, unsigned char * text, int textLen) {
    (void) h;
    if (textLen < 2) return AEE_EBADPARM;
    char * p = (char *) text, * end = (char *) text + textLen - 1;
    p = f2q_puts(p, end, "f2qdsp v");
    p = f2q_putu(p, end, F2Q_VERSION);
    p = f2q_puts(p, end, " hexagon v");
    p = f2q_putu(p, end, (unsigned) __HEXAGON_ARCH__);
    p = f2q_puts(p, end, " hvx128 threads=");
    p = f2q_putu(p, end, F2Q_MAXT);
    const int lk = qurt_hvx_lock(QURT_HVX_MODE_128B) == 0;
    if (lk) qurt_hvx_unlock();
    p = f2q_puts(p, end, lk ? " hvx_lock=ok" : " hvx_lock=FAIL");
    p = f2q_puts(p, end, " power=");
    p = f2q_putu(p, end, (unsigned) (f2q_power_ok < 0 ? 9 : f2q_power_ok));
    p = f2q_puts(p, end, " corner=");
    p = f2q_putu(p, end, (unsigned) (f2q_corner < 0 ? 0 : f2q_corner));
    p = f2q_puts(p, end, " l2fetch=");
    p = f2q_putu(p, end, (unsigned) F2Q_PF_W);
    if (F2Q_PF_ALL) p = f2q_puts(p, end, "+all");
    *p = 0;
    return AEE_SUCCESS;
}

int f2qdsp_power(remote_handle64 h, int level) {
    (void) h;
    return f2q_vote(level);
}

int f2qdsp_mm(remote_handle64 h, const unsigned char * w, int wLen, const unsigned char * x, int xLen,
              unsigned char * y, int yLen, int wtype, int tiles, int k, int n, int xstride, int ystride, int nthreads) {
    (void) h;
    if ((wtype != F2Q_W_Q8 && wtype != F2Q_W_Q4) || k <= 0 || k % F2Q_QK || tiles <= 0 || n <= 0) return AEE_EBADPARM;
    if (xstride < (int) f2q_x_stride(k) || xstride % 4 || ystride < tiles * F2Q_TILE) return AEE_EBADPARM;
    if ((unsigned long long) tiles * f2q_tile_bytes(wtype, k) > (unsigned) wLen) return AEE_EBADPARM;
    if ((unsigned long long) n * (unsigned) xstride > (unsigned) xLen) return AEE_EBADPARM;
    if ((unsigned long long) n * (unsigned) ystride * 4 > (unsigned) yLen) return AEE_EBADPARM;
    if (((uintptr_t) w & 127) || ((uintptr_t) x & 3) || ((uintptr_t) y & 3)) return AEE_EBADPARM;
    int nt = nthreads < 1 ? 1 : (nthreads > F2Q_MAXT ? F2Q_MAXT : nthreads);
    if (nt > tiles) nt = tiles;
    const int own = nt > 1 && __atomic_exchange_n(&f2q_stacks_busy, 1, __ATOMIC_ACQUIRE) == 0;
    if (!own) nt = 1;
    f2q_job job[F2Q_MAXT];
    qurt_thread_t tid[F2Q_MAXT];
    int started[F2Q_MAXT] = { 0 };
    for (int i = 0; i < nt; i++) {
        job[i] = (f2q_job) { w, wtype, k, (int) f2q_udiv((unsigned) (tiles * i), (unsigned) nt),
                             (int) f2q_udiv((unsigned) (tiles * (i + 1)), (unsigned) nt), x, n, xstride, (float *) y, ystride, 0 };
    }
    // приоритет как у вызывающего потока FastRPC, но в unsigned PD не выше 64 (меньше число - выше приоритет),
    // иначе qurt_thread_create откажет и всё посчитается в одном потоке
    int prio = qurt_thread_get_priority(qurt_thread_get_id());
    if (prio < 64 || prio > 254) prio = 64;
    for (int i = 1; i < nt; i++) {
        qurt_thread_attr_t a;
        qurt_thread_attr_init(&a);
        qurt_thread_attr_set_name(&a, "f2qdsp");
        qurt_thread_attr_set_stack_addr(&a, f2q_stacks[i]);
        qurt_thread_attr_set_stack_size(&a, F2Q_STACK);
        qurt_thread_attr_set_priority(&a, (unsigned short) prio);
        started[i] = qurt_thread_create(&tid[i], &a, f2q_worker, &job[i]) == QURT_EOK;
    }
    f2q_run(&job[0]);
    for (int i = 1; i < nt; i++) {
        if (started[i]) { int st; qurt_thread_join(tid[i], &st); }
        else f2q_run(&job[i]); // поток не создался - считаем сами
    }
    if (own) __atomic_store_n(&f2q_stacks_busy, 0, __ATOMIC_RELEASE);
    return AEE_SUCCESS;
}
