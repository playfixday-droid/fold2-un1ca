// f2qdsp_imp.c - DSP-часть (skel) драйвера f2qdsp: cDSP Hexagon 698 (v66, HVX 128B) в unsigned PD.
// Методы интерфейса из idl/f2qdsp.idl; маршалинг - f2qdsp_skel.c (генерирует qaic).
#include <stdlib.h>
#include <string.h>
#include "AEEStdErr.h"
#include "HAP_power.h"
#include "qurt.h"
#include "f2qdsp.h"
#include "../common/f2q_format.h"
#include "../common/f2q_mbox.h"
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

// Постоянные потоки (mm2, flags & 1): создаются один раз и ждут работу на семафоре - без qurt_thread_create/join
// на каждый вызов (в llama ~150 умножений на токен). HVX берут на время задания, как и одноразовые потоки.
typedef struct {
    qurt_sem_t    go;
    f2q_job *     job;
    volatile int  quit;
    int           started;
    qurt_thread_t tid;
} f2q_wk;
static f2q_wk     f2q_pool[F2Q_MAXT];
static qurt_sem_t f2q_pool_done;
static int        f2q_pool_up;   // 1 - потоки созданы (те, у кого started)
static int        f2q_pool_busy; // пул занят вызовом (второй одновременный вызов считает в своём потоке)
static uint8_t    f2q_pstacks[F2Q_MAXT][F2Q_STACK] __attribute__((aligned(128)));

static void f2q_pworker(void * arg) {
    f2q_wk * k = (f2q_wk *) arg;
    for (;;) {
        qurt_sem_down(&k->go);
        if (k->quit) break;
        f2q_run(k->job);
        qurt_sem_add(&f2q_pool_done, 1);
    }
    qurt_thread_exit(0);
}

static int f2q_prio(void) {
    // приоритет как у вызывающего потока FastRPC, но в unsigned PD не выше 64 (меньше число - выше приоритет),
    // иначе qurt_thread_create откажет и всё посчитается в одном потоке
    int prio = qurt_thread_get_priority(qurt_thread_get_id());
    if (prio < 64 || prio > 254) prio = 64;
    return prio;
}

static void f2q_pool_start(void) { // под f2q_pool_busy
    if (f2q_pool_up) return;
    qurt_sem_init_val(&f2q_pool_done, 0);
    const int prio = f2q_prio();
    for (int i = 1; i < F2Q_MAXT; i++) {
        f2q_wk * k = &f2q_pool[i];
        qurt_sem_init_val(&k->go, 0);
        k->quit = 0;
        qurt_thread_attr_t a;
        qurt_thread_attr_init(&a);
        qurt_thread_attr_set_name(&a, "f2qpool");
        qurt_thread_attr_set_stack_addr(&a, f2q_pstacks[i]);
        qurt_thread_attr_set_stack_size(&a, F2Q_STACK);
        qurt_thread_attr_set_priority(&a, (unsigned short) prio);
        k->started = qurt_thread_create(&k->tid, &a, f2q_pworker, k) == QURT_EOK;
    }
    f2q_pool_up = 1;
}

static void f2q_pool_stop(void) {
    if (!f2q_pool_up) return;
    for (int i = 1; i < F2Q_MAXT; i++) {
        f2q_wk * k = &f2q_pool[i];
        if (!k->started) continue;
        k->quit = 1;
        qurt_sem_add(&k->go, 1);
        int st;
        qurt_thread_join(k->tid, &st);
        k->started = 0;
        qurt_sem_destroy(&k->go);
    }
    qurt_sem_destroy(&f2q_pool_done);
    f2q_pool_up = 0;
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
    if (__atomic_exchange_n(&f2q_pool_busy, 1, __ATOMIC_ACQUIRE) == 0) {
        f2q_pool_stop();
        __atomic_store_n(&f2q_pool_busy, 0, __ATOMIC_RELEASE);
    }
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
    p = f2q_puts(p, end, " mm2=1"); // есть mm2 (веса по смещению / по адресу remote_mmap, постоянные потоки)
    p = f2q_puts(p, end, " mb=1");  // есть serve (почтовый ящик f2q_mbox.h)
    *p = 0;
    return AEE_SUCCESS;
}

int f2qdsp_power(remote_handle64 h, int level) {
    (void) h;
    return f2q_vote(level);
}

// плитки [0, tiles) весов w: nt потоков HVX - одноразовые (pool = 0, как в v2) или постоянные (pool = 1)
// nt потоков; nt > 1 - вызывающий уже держит f2q_pool_busy (pool) или f2q_stacks_busy (!pool)
static void f2q_exec_nt(const uint8_t * w, int wtype, int tiles, int k, const uint8_t * x, int n, int xstride,
                        float * y, int ystride, int nt, int pool) {
    f2q_job job[F2Q_MAXT];
    qurt_thread_t tid[F2Q_MAXT];
    int started[F2Q_MAXT] = { 0 };
    for (int i = 0; i < nt; i++) {
        job[i] = (f2q_job) { w, wtype, k, (int) f2q_udiv((unsigned) (tiles * i), (unsigned) nt),
                             (int) f2q_udiv((unsigned) (tiles * (i + 1)), (unsigned) nt), x, n, xstride, y, ystride, 0 };
    }
    int sent = 0;
    if (pool) {
        for (int i = 1; i < nt; i++) {
            if (!f2q_pool[i].started) continue;
            f2q_pool[i].job = &job[i];
            started[i] = 1;
            sent++;
            qurt_sem_add(&f2q_pool[i].go, 1);
        }
    } else {
        const int prio = f2q_prio();
        for (int i = 1; i < nt; i++) {
            qurt_thread_attr_t a;
            qurt_thread_attr_init(&a);
            qurt_thread_attr_set_name(&a, "f2qdsp");
            qurt_thread_attr_set_stack_addr(&a, f2q_stacks[i]);
            qurt_thread_attr_set_stack_size(&a, F2Q_STACK);
            qurt_thread_attr_set_priority(&a, (unsigned short) prio);
            started[i] = qurt_thread_create(&tid[i], &a, f2q_worker, &job[i]) == QURT_EOK;
        }
    }
    f2q_run(&job[0]);
    for (int i = 1; i < nt; i++) {
        if (!started[i]) f2q_run(&job[i]); // поток не создался - считаем сами
        else if (!pool) { int st; qurt_thread_join(tid[i], &st); }
    }
    for (int i = 0; i < sent; i++) qurt_sem_down(&f2q_pool_done);
}

static int f2q_nt(int nthreads, int tiles) {
    int nt = nthreads < 1 ? 1 : (nthreads > F2Q_MAXT ? F2Q_MAXT : nthreads);
    return nt > tiles ? tiles : nt;
}

static void f2q_exec(const uint8_t * w, int wtype, int tiles, int k, const uint8_t * x, int n, int xstride,
                     float * y, int ystride, int nthreads, int pool) {
    int nt = f2q_nt(nthreads, tiles);
    int * busy = pool ? &f2q_pool_busy : &f2q_stacks_busy;
    const int own = nt > 1 && __atomic_exchange_n(busy, 1, __ATOMIC_ACQUIRE) == 0;
    if (!own) nt = 1;
    if (own && pool) f2q_pool_start();
    f2q_exec_nt(w, wtype, tiles, k, x, n, xstride, y, ystride, nt, pool);
    if (own) __atomic_store_n(busy, 0, __ATOMIC_RELEASE);
}

static int f2q_check(int wtype, int tiles, int k, int n, int xstride, int ystride, int xLen, int yLen,
                     const unsigned char * x, const unsigned char * y) {
    if ((wtype != F2Q_W_Q8 && wtype != F2Q_W_Q4) || k <= 0 || k % F2Q_QK || tiles <= 0 || n <= 0) return AEE_EBADPARM;
    if (xstride < (int) f2q_x_stride(k) || xstride % 4 || ystride < tiles * F2Q_TILE) return AEE_EBADPARM;
    if ((unsigned long long) n * (unsigned) xstride > (unsigned) xLen) return AEE_EBADPARM;
    if ((unsigned long long) n * (unsigned) ystride * 4 > (unsigned) yLen) return AEE_EBADPARM;
    if (((uintptr_t) x & 3) || ((uintptr_t) y & 3)) return AEE_EBADPARM;
    return AEE_SUCCESS;
}

int f2qdsp_mm(remote_handle64 h, const unsigned char * w, int wLen, const unsigned char * x, int xLen,
              unsigned char * y, int yLen, int wtype, int tiles, int k, int n, int xstride, int ystride, int nthreads) {
    (void) h;
    const int e = f2q_check(wtype, tiles, k, n, xstride, ystride, xLen, yLen, x, y);
    if (e) return e;
    if ((unsigned long long) tiles * f2q_tile_bytes(wtype, k) > (unsigned) wLen) return AEE_EBADPARM;
    if ((uintptr_t) w & 127) return AEE_EBADPARM;
    f2q_exec(w, wtype, tiles, k, x, n, xstride, (float *) y, ystride, nthreads, 0);
    return AEE_SUCCESS;
}

unsigned long long HAP_perf_get_time_us(void);

int f2qdsp_mm2(remote_handle64 h, const unsigned char * w, int wLen, int wa, int wsz, int woff, const unsigned char * x,
               int xLen, unsigned char * y, int yLen, int wtype, int tiles, int k, int n, int xstride, int ystride,
               int nthreads, int flags, int * dsp_us) {
    (void) h;
    const unsigned long long t0 = HAP_perf_get_time_us();
    if (dsp_us) *dsp_us = 0;
    const int e = f2q_check(wtype, tiles, k, n, xstride, ystride, xLen, yLen, x, y);
    if (e) return e;
    const uint8_t * base = wa ? (const uint8_t *) (uintptr_t) (unsigned) wa : w;
    const unsigned  size = wa ? (unsigned) wsz : (unsigned) wLen;
    if (!base || woff < 0 || (woff & 127) || ((uintptr_t) base & 127)) return AEE_EBADPARM;
    if ((unsigned long long) (unsigned) woff + (unsigned long long) tiles * f2q_tile_bytes(wtype, k) > size) return AEE_EBADPARM;
    f2q_exec(base + woff, wtype, tiles, k, x, n, xstride, (float *) y, ystride, nthreads, flags & 1);
    if (dsp_us) *dsp_us = (int) (HAP_perf_get_time_us() - t0);
    return AEE_SUCCESS;
}

// ---- почтовый ящик (f2q_mbox.h) ----
// кэш DSP: перед чтением того, что записал ARM, - сброс своей копии; после записи результата - в память
static void f2q_inval(const volatile void * p, unsigned n) {
    qurt_mem_cache_clean((qurt_addr_t) (uintptr_t) p, n, QURT_MEM_CACHE_FLUSH_INVALIDATE, QURT_MEM_DCACHE);
}
static void f2q_flush(const volatile void * p, unsigned n) {
    qurt_mem_cache_clean((qurt_addr_t) (uintptr_t) p, n, QURT_MEM_CACHE_FLUSH, QURT_MEM_DCACHE);
}

static int f2q_mb_job(f2q_mbox * mb) {
    const int wtype = mb->wtype, tiles = mb->tiles, k = mb->k, n = mb->n, xs = mb->xstride, ys = mb->ystride;
    const uint64_t wa = mb->wa, xa = mb->xa, ya = mb->ya;
    // адреса на DSP (remote_mmap64); на DSP указатель 32-битный - старшие биты должны быть нулями
    if ((uint64_t) (uintptr_t) wa != wa || (uint64_t) (uintptr_t) xa != xa || (uint64_t) (uintptr_t) ya != ya) return AEE_EBADPARM;
    if (!wa || !xa || !ya || (wa & 127) || (xa & 127) || (ya & 127)) return AEE_EBADPARM;
    const uint8_t * w = (const uint8_t *) (uintptr_t) wa;
    const uint8_t * x = (const uint8_t *) (uintptr_t) xa;
    float *         y = (float *) (uintptr_t) ya;
    if (n > 64) return AEE_EBADPARM;
    const int e = f2q_check(wtype, tiles, k, n, xs, ys, n * xs, n * ys * 4, x, (const unsigned char *) y);
    if (e) return e;
    f2q_inval(x, (unsigned) n * (unsigned) xs);
    int nt = f2q_nt(mb->nthreads, tiles);
    int own = 0;
    if (nt > 1) { // пул: единственный вызывающий - этот цикл, но mm/mm2 из другого потока ARM могли его занять
        for (int i = 0; i < 1000 && !(own = __atomic_exchange_n(&f2q_pool_busy, 1, __ATOMIC_ACQUIRE) == 0); i++) { }
        if (own) f2q_pool_start(); else nt = 1;
    }
    f2q_exec_nt(w, wtype, tiles, k, x, n, xs, y, ys, nt, 1);
    if (own) __atomic_store_n(&f2q_pool_busy, 0, __ATOMIC_RELEASE);
    f2q_flush(y, (unsigned) n * (unsigned) ys * 4u);
#ifdef F2Q_MOCK_COUNT
    F2Q_MOCK_COUNT();
#endif
    return AEE_SUCCESS;
}

int f2qdsp_serve(remote_handle64 h, unsigned char * io, int ioLen, int idle_ms) {
    (void) h;
    if (!io || ioLen < F2Q_MB_SIZE || ((uintptr_t) io & 127) || idle_ms < 1) return AEE_EBADPARM;
    f2q_mbox * mb = (f2q_mbox *) io;
    f2q_inval(mb, F2Q_MB_SIZE);
    uint32_t last = mb->done;
    mb->alive = 1;
    mb->jobs = 0;
    f2q_flush(&mb->done, 128);
    const unsigned long long idle = (unsigned long long) idle_ms * 1000ull;
    unsigned long long       t_last = HAP_perf_get_time_us();
    for (;;) {
        f2q_inval(mb, 128);
        const uint32_t s = __atomic_load_n(&mb->seq, __ATOMIC_ACQUIRE);
        if (s != last) {
            const unsigned long long t0 = HAP_perf_get_time_us();
            const int exit = mb->cmd == F2Q_MB_EXIT;
            const int rc = exit ? AEE_SUCCESS : (mb->cmd == F2Q_MB_MM ? f2q_mb_job(mb) : AEE_EBADPARM);
            const unsigned long long t1 = HAP_perf_get_time_us();
            mb->rc = rc;
            mb->dsp_us = (int) (t1 - t0);
            mb->jobs++;
            if (exit) mb->alive = 0;
            __atomic_store_n(&mb->done, s, __ATOMIC_RELEASE);
            f2q_flush(&mb->done, 128);
            last = s;
            t_last = t1;
            if (exit) return AEE_SUCCESS;
        } else if (HAP_perf_get_time_us() - t_last > idle) {
            break;
        }
    }
    mb->alive = 0;
    f2q_flush(&mb->done, 128);
    return AEE_SUCCESS;
}
