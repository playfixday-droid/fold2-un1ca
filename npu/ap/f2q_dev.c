// f2q_dev.c - ARM-сторона f2qdsp: FastRPC-сессия с cDSP (unsigned PD), rpcmem, вызовы mm, самопроверка.
// Заглушка (stub) от qaic компилируется прямо сюда; её вызовы remote_* идут через таблицу R,
// заполненную dlopen(libcdsprpc.so) - так сборка не зависит от библиотек вендора.
// F2QDSP_MOCK: вместо DSP - skel + f2qdsp_imp.c в том же процессе (проверка маршалинга на ПК).
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define __QAIC_REMOTE(ff) f2q_##ff
#include "f2qdsp.h"
#include "../common/f2q_format.h"
#include "../common/f2q_mbox.h"
#include "../common/f2q_pack.h"
#include "../dsp/f2q_kernel.h"
#include "f2q_dev.h"

typedef int    (*t_open)(const char *, remote_handle64 *);
typedef int    (*t_invoke)(remote_handle64, uint32_t, remote_arg *);
typedef int    (*t_close)(remote_handle64);
typedef int    (*t_sc)(uint32_t, void *, uint32_t);
typedef void * (*t_alloc)(int, uint32_t, int);
typedef void   (*t_free)(void *);
typedef int    (*t_tofd)(void *);
typedef void   (*t_reg)(void *, int, int);
typedef void   (*t_rega)(void *, int, int, int);
typedef void   (*t_void)(void);
typedef int    (*t_hctl)(uint32_t, void *, uint32_t);
typedef int    (*t_hctl64)(remote_handle64, uint32_t, void *, uint32_t);
typedef int    (*t_mmap64)(int, uint32_t, uint64_t, int64_t, uint64_t *);
typedef int    (*t_munmap64)(uint64_t, int64_t);

static struct {
    void *   lib;
    t_open   open;
    t_invoke invoke;
    t_close  close;
    t_sc     sc;
    t_alloc  alloc;
    t_free   free;
    t_tofd   tofd;
    t_reg    reg;
    t_rega   rega;
    t_void   init;
    t_hctl   hctl;   // remote_handle_control: DSPRPC_GET_DSP_INFO (возможности DSP)
    t_hctl64 hctl64; // remote_handle64_control: DSPRPC_CONTROL_LATENCY (PM QoS)
    t_mmap64   mmap64;   // remote_mmap64: постоянное отображение весов в PD на DSP (F2QDSP_WMODE=3)
    t_munmap64 munmap64;
} R;

// переходники для заглушки qaic (она вызывает __QAIC_REMOTE(remote_handle64_*))
int f2q_remote_handle64_open(const char * name, remote_handle64 * ph) { return R.open ? R.open(name, ph) : AEE_EUNSUPPORTED; }
int f2q_remote_handle64_invoke(remote_handle64 h, uint32_t sc, remote_arg * pra) { return R.invoke ? R.invoke(h, sc, pra) : AEE_EUNSUPPORTED; }
int f2q_remote_handle64_close(remote_handle64 h) { return R.close ? R.close(h) : AEE_EUNSUPPORTED; }

#include "f2qdsp_stub.c"

#define F2Q_HEAP_SYSTEM 25
#define F2Q_RPC_CACHED  1
#ifndef FASTRPC_ATTR_KEEP_MAP
#define FASTRPC_ATTR_KEEP_MAP 8
#endif
#ifndef FASTRPC_ATTR_FORCE_NOFLUSH
#define FASTRPC_ATTR_FORCE_NOFLUSH 32
#endif

#ifdef F2QDSP_MOCK
// ---- имитация FastRPC на ПК: skel и реализация DSP в этом же процессе ----
int impl_f2qdsp_open(const char * uri, remote_handle64 * h);
int impl_f2qdsp_close(remote_handle64 h);
int f2qdsp_skel_handle_invoke(remote_handle64 h, uint32_t sc, remote_arg * pra);
static int    mock_open(const char * uri, remote_handle64 * h) { return impl_f2qdsp_open(uri, h); }
static int    mock_invoke(remote_handle64 h, uint32_t sc, remote_arg * pra) { return f2qdsp_skel_handle_invoke(h, sc, pra); }
static int    mock_close(remote_handle64 h) { return impl_f2qdsp_close(h); }
static int    mock_sc(uint32_t req, void * d, uint32_t l) { (void) req; (void) d; (void) l; return 0; }
// регистрация буферов как в libcdsprpc (quic/fastrpc, fastrpc_mem.c): счётчик ссылок, повторная регистрация
// того же (buf, size, fd) меняет атрибуты, снятие с другим размером - abort()
typedef struct { void * buf; int size, fd, attr, refs; } mock_reg_t;
static mock_reg_t      mock_regs[8192];
static int             mock_nregs;
static pthread_mutex_t mock_mu = PTHREAD_MUTEX_INITIALIZER;
static void mock_rega(void * buf, int size, int fd, int attr) {
    pthread_mutex_lock(&mock_mu);
    int i, addr = -1;
    if (fd != -1) {
        for (i = 0; i < mock_nregs; i++) if (mock_regs[i].buf == buf && mock_regs[i].size == size && mock_regs[i].fd == fd) break;
        if (i < mock_nregs) { if (attr) mock_regs[i].attr = attr; mock_regs[i].refs++; }
        else if (mock_nregs < (int) (sizeof(mock_regs) / sizeof(mock_regs[0]))) mock_regs[mock_nregs++] = (mock_reg_t) { buf, size, fd, attr, 1 };
    } else {
        for (i = 0; i < mock_nregs; i++) {
            if (mock_regs[i].buf != buf) continue;
            if (mock_regs[i].size == size) break;
            addr = i;
        }
        if (i < mock_nregs) {
            if (--mock_regs[i].refs <= 0) mock_regs[i] = mock_regs[--mock_nregs];
        } else if (addr >= 0) {
            fprintf(stderr, "MOCK libcdsprpc: FATAL size mismatch (%p: снимаем %d, зарегистрирован %d)\n", buf, size, mock_regs[addr].size);
            abort();
        }
    }
    pthread_mutex_unlock(&mock_mu);
}
static void mock_reg(void * buf, int size, int fd) { mock_rega(buf, size, fd, 0); }
// rpcmem_alloc: худший вариант - регистрирует размер, округлённый до страницы
#define MOCK_PG(n) (((size_t) (n) + 4095) & ~(size_t) 4095)
static void * mock_alloc(int heap, uint32_t fl, int size) {
    (void) heap; (void) fl;
    void * b = NULL;
    if (size <= 0 || posix_memalign(&b, 4096, 4096 + MOCK_PG(size))) return NULL;
    *(int *) b = (int) MOCK_PG(size);
    void * p = (uint8_t *) b + 4096;
    mock_reg(p, (int) MOCK_PG(size), 77);
    return p;
}
static void mock_free(void * p) {
    if (!p) return;
    void * b = (uint8_t *) p - 4096;
    mock_reg(p, *(int *) b, -1);
    free(b);
}
static int mock_tofd(void * p) { (void) p; return 77; }
static int mock_hctl(uint32_t req, void * d, uint32_t l) {
    struct remote_dsp_capability * c = (struct remote_dsp_capability *) d;
    if (req != DSPRPC_GET_DSP_INFO || l < sizeof(*c)) return AEE_EUNSUPPORTED;
    static const uint32_t v[] = { 1, 1, 0, 4, 256 * 1024, 1, 0x66 }; // как у cDSP SM8250: 4 HVX 128B, VTCM 256 КБ
    if (c->attribute_ID >= sizeof(v) / sizeof(v[0])) return AEE_EUNSUPPORTED;
    c->capability = c->attribute_ID == HVX_SUPPORT_128B && getenv("F2QDSP_MOCK_HVX") ? (uint32_t) atoi(getenv("F2QDSP_MOCK_HVX"))
                                                                                     : v[c->attribute_ID];
    return 0;
}
static int mock_hctl64(remote_handle64 h, uint32_t req, void * d, uint32_t l) {
    (void) h;
    return req == DSPRPC_CONTROL_LATENCY && l >= sizeof(struct remote_rpc_control_latency) ? 0 : AEE_EUNSUPPORTED;
}
#endif

static pthread_mutex_t g_init_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_mu      = PTHREAD_MUTEX_INITIALIZER; // один вызов DSP за раз (scratch общий)
static pthread_mutex_t g_al_mu   = PTHREAD_MUTEX_INITIALIZER;
static int             g_state   = -1;                         // -1 не пробовали, 0 нет DSP, 1 готов (атомарно)
static char            g_status[2048];
static remote_handle64 g_h;
static int             g_threads = 4;
static int             g_threads_explicit; // пользователь задал F2QDSP_THREADS - не меняем его выбор
static int             g_attr_w  = FASTRPC_ATTR_KEEP_MAP | FASTRPC_ATTR_FORCE_NOFLUSH;
static int             g_errors;
static uint8_t *       g_x;
static size_t          g_xcap;
static float *         g_y;
static size_t          g_ycap;
// Как передавать веса (F2QDSP_WMODE): 0 - mm, кусок буфера под каждый тензор (как в v2);
// 1 - mm2 так же; 2 - mm2, весь буфер весов + смещение (одна и та же область во всех вызовах);
// 3 - mm2, буфер весов отображён в PD на DSP один раз (remote_mmap64), в вызове только адрес и смещение.
// Замер Fold2: в llama вызов DSP вдвое-втрое дольше, чем в f2q-bench на тех же размерах (там один буфер на матрицу).
static int             g_mm2;      // skel умеет mm2 (info: "mm2=1") и самопроверка через него прошла
static int             g_wmode;
static int             g_pool = 1; // F2QDSP_POOL: постоянные потоки на DSP (mm2)
static int             g_stats;    // F2QDSP_STATS=N: каждые N вызовов - сводка времени в stderr
static int64_t         g_st_n, g_st_wall, g_st_dsp, g_st_tiles;

typedef struct { uint8_t * p; size_t size; int rpc; uint32_t wa; } f2q_region; // wa - адрес на DSP (remote_mmap64)
static f2q_region g_al[4096];
static int        g_nal;

// g_state читают потоки ggml без блокировки: acquire/release, чтобы после 1 были видны g_h, g_threads и т.д.
static int  state_get(void) { return __atomic_load_n(&g_state, __ATOMIC_ACQUIRE); }
static void state_set(int v) { __atomic_store_n(&g_state, v, __ATOMIC_RELEASE); }

int64_t f2q_dev_time_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t) ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

static void st(const char * fmt, ...) {
    const size_t n = strlen(g_status);
    if (n + 2 >= sizeof(g_status)) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(g_status + n, sizeof(g_status) - n, fmt, ap);
    va_end(ap);
    if (getenv("F2QDSP_DEBUG")) fprintf(stderr, "f2qdsp: %s\n", g_status + n);
}

int f2q_dev_env_mode(void) {
    const char * e = getenv("F2QDSP");
    if (!e || !*e || !strcmp(e, "0")) return 0;
    if (!strcmp(e, "cpu")) return 2;
    return 1;
}

const char * f2q_dev_status(void) { return g_status; }

static int env_int(const char * n, int def) {
    const char * e = getenv(n);
    return e && *e ? atoi(e) : def;
}

#ifndef F2QDSP_MOCK
static int load_lib(void) {
    static const char * names[] = { "libcdsprpc.so", "/vendor/lib64/libcdsprpc.so", "/system/vendor/lib64/libcdsprpc.so" };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]) && !R.lib; i++) R.lib = dlopen(names[i], RTLD_NOW | RTLD_LOCAL);
    if (!R.lib) { st("нет libcdsprpc.so (%s); ", dlerror()); return 0; }
    R.open   = (t_open) dlsym(R.lib, "remote_handle64_open");
    R.invoke = (t_invoke) dlsym(R.lib, "remote_handle64_invoke");
    R.close  = (t_close) dlsym(R.lib, "remote_handle64_close");
    R.sc     = (t_sc) dlsym(R.lib, "remote_session_control");
    R.alloc  = (t_alloc) dlsym(R.lib, "rpcmem_alloc");
    R.free   = (t_free) dlsym(R.lib, "rpcmem_free");
    R.tofd   = (t_tofd) dlsym(R.lib, "rpcmem_to_fd");
    R.reg    = (t_reg) dlsym(R.lib, "remote_register_buf");
    R.rega   = (t_rega) dlsym(R.lib, "remote_register_buf_attr");
    R.init   = (t_void) dlsym(R.lib, "rpcmem_init");
    R.hctl   = (t_hctl) dlsym(R.lib, "remote_handle_control");
    R.hctl64 = (t_hctl64) dlsym(R.lib, "remote_handle64_control");
    R.mmap64 = (t_mmap64) dlsym(R.lib, "remote_mmap64");
    R.munmap64 = (t_munmap64) dlsym(R.lib, "remote_munmap64");
    if (!R.open || !R.invoke || !R.close) { st("в libcdsprpc нет remote_handle64_*; "); return 0; }
    if (!R.alloc || !R.free) { st("в libcdsprpc нет rpcmem_alloc (нужна общая память); "); return 0; }
    if (R.init) R.init();
    return 1;
}

static void set_lib_path(void) {
    char p[1400];
    const char * a = getenv("ADSP_LIBRARY_PATH");
    if (a) {
        snprintf(p, sizeof(p), "%s", a);
    } else {
        char dir[512] = ".";
        Dl_info di;
        if (dladdr((void *) &f2q_dev_init, &di) && di.dli_fname) {
            snprintf(dir, sizeof(dir), "%s", di.dli_fname);
            char * s = strrchr(dir, '/');
            if (s) *s = 0; else snprintf(dir, sizeof(dir), ".");
        }
        snprintf(p, sizeof(p), "%s/../dsp;%s;/vendor/dsp/cdsp;/vendor/dsp;/vendor/lib/rfsa/adsp;/system/lib/rfsa/adsp;/dsp", dir, dir);
        setenv("ADSP_LIBRARY_PATH", p, 0);
    }
    // libcdsprpc ищет файлы DSP по DSP_LIBRARY_PATH, если она задана, и тогда ADSP_LIBRARY_PATH не смотрит
    const char * d = getenv("DSP_LIBRARY_PATH");
    if (d && strcmp(d, p) != 0) {
        char q[2900];
        snprintf(q, sizeof(q), "%s;%s", p, d);
        setenv("DSP_LIBRARY_PATH", q, 1);
        st("DSP_LIBRARY_PATH=%s; ", q);
    } else {
        st("ADSP_LIBRARY_PATH=%s; ", p);
    }
}
#endif

// Размеры буферов rpcmem кратны странице: rpcmem регистрирует буфер со своим размером, а новые libcdsprpc
// при снятии регистрации с другим размером делают abort() ("Size mismatch between deregister buf ...").
#define F2Q_PAGE ((size_t) 4096)
static size_t page_up(size_t n) { return (n + F2Q_PAGE - 1) & ~(F2Q_PAGE - 1); }

static void * rpc_alloc(size_t size) {
    if (!R.alloc || size == 0 || size > (size_t) INT_MAX - F2Q_PAGE) return NULL;
    return R.alloc(F2Q_HEAP_SYSTEM, F2Q_RPC_CACHED, (int) page_up(size));
}

// перерегистрация буфера весов с атрибутами g_attr_w: постоянное отображение, без flush на каждый вызов
static void reg_attr(void * p, size_t size) {
    const int fd = R.tofd ? R.tofd(p) : -1;
    if (g_attr_w >= 0 && R.rega && fd >= 0) {
        if (R.reg) R.reg(p, (int) page_up(size), -1);
        R.rega(p, (int) page_up(size), fd, g_attr_w);
    }
}

static int grow(void ** p, size_t * cap, size_t need) {
    if (need <= *cap) return 1;
    size_t c = *cap ? *cap : 65536;
    while (c < need) c *= 2;
    if (*p) R.free(*p);
    *p = rpc_alloc(c);
    *cap = *p ? c : 0;
    return *p != NULL;
}

static int call_mm(const uint8_t * w, size_t wbytes, int wtype, int k, int tiles,
                   const uint8_t * x, int n, int xstride, float * y, int ystride) {
    const size_t xl = (size_t) n * (size_t) xstride, yl = (size_t) n * (size_t) ystride * 4;
    if (wbytes > (size_t) INT_MAX || xl > (size_t) INT_MAX || yl > (size_t) INT_MAX) return AEE_EBADPARM;
    return f2qdsp_mm(g_h, w, (int) wbytes, x, (int) xl, (unsigned char *) y, (int) yl,
                     wtype, tiles, k, n, xstride, ystride, g_threads);
}

// mm2: веса - base (bsize байт; wa != 0 - base уже отображён на DSP по адресу wa), плитки с байта woff
static int call_mm2(const uint8_t * base, size_t bsize, uint32_t wa, size_t woff, int wtype, int k, int tiles,
                    const uint8_t * x, int n, int xstride, float * y, int ystride, int * dsp_us) {
    const size_t xl = (size_t) n * (size_t) xstride, yl = (size_t) n * (size_t) ystride * 4;
    if (bsize > (size_t) INT_MAX || woff > bsize || xl > (size_t) INT_MAX || yl > (size_t) INT_MAX) return AEE_EBADPARM;
    return f2qdsp_mm2(g_h, wa ? NULL : base, wa ? 0 : (int) bsize, (int) wa, (int) bsize, (int) woff, x, (int) xl,
                      (unsigned char *) y, (int) yl, wtype, tiles, k, n, xstride, ystride, g_threads, g_pool ? 1 : 0, dsp_us);
}

// отображение буфера весов в PD на DSP (F2QDSP_WMODE=3); 0 - не вышло
static uint32_t map_dsp(void * p, size_t size) {
    if (!R.mmap64 || !R.tofd) return 0;
    const int fd = R.tofd(p);
    uint64_t  ra = 0;
    if (fd < 0) return 0;
    const int rc = R.mmap64(fd, 0, (uint64_t) (uintptr_t) p, (int64_t) page_up(size), &ra);
    if (rc || !ra || ra > 0xFFFFFFFFull || (ra & 127)) {
        if (!rc && ra && R.munmap64) R.munmap64(ra, (int64_t) page_up(size));
        static int warned;
        if (!warned++) fprintf(stderr, "f2qdsp: remote_mmap64 rc=0x%x addr=0x%llx - веса по-старому\n", (unsigned) rc, (unsigned long long) ra);
        return 0;
    }
    return (uint32_t) ra;
}
static void unmap_dsp(uint32_t wa, size_t size) {
    if (wa && R.munmap64) R.munmap64(wa, (int64_t) page_up(size));
}

// ---- почтовый ящик (f2q_mbox.h): DSP сидит в одном долгом вызове serve и берёт задания из памяти ----
// Ящик - страница rpcmem (аргумент serve), x и y - буфер g_xy, отображённый на DSP (remote_mmap64): драйвер не
// трогает их кэш, пока идёт serve, - кэш чистим сами (cache_op). Поток mb_thread держит вызов serve: DSP выходит
// из него через F2QDSP_IDLE_MS мс без заданий, следующее задание будит поток снова.
static int             g_mbox;          // 1 - ящик работает (меняется под g_mu)
static f2q_mbox *      g_mb;            // страница rpcmem
static f2q_mbox        g_mb_a;          // теневая копия строки A (если драйвер выбросил кэш ящика - публикуем снова)
static uint8_t *       g_xy;            // x и y заданий
static size_t          g_xy_size;
static uint64_t        g_xy_da;         // адрес g_xy на DSP
static int             g_mb_idle = 100; // мс
static uint32_t        g_mb_seq;        // последнее отправленное задание (атомарно: читает mb_thread)
static int             g_mb_busy;       // задание отправлено, ждём (под g_mu)
static const float *   g_mb_y;
static size_t          g_mb_yl;
static int             g_mb_tiles;
static int             g_mb_fail;       // serve вернул ошибку или DSP не ответил - ящик выключен (атомарно)
static int64_t         g_mb_n, g_mb_dsp, g_mb_wt, g_mb_t, g_mb_wall, g_mb_tl; // F2QDSP_STATS
static pthread_mutex_t g_mb_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_mb_cv = PTHREAD_COND_INITIALIZER;
static int             g_mb_want, g_mb_serving, g_mb_serves;

// кэш CPU <-> память: inval=0 - dc cvac (сбросить в память), 1 - dc civac (сбросить и выбросить свою копию: перед
// чтением того, что записал DSP). dc по адресу действует на кэши всех ядер (inner shareable) - x, записанный
// другими потоками ggml до барьера, тоже уходит в память
static void cache_op(const volatile void * p, size_t size, int inval) {
#if defined(__aarch64__)
    uint64_t ctr;
    __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
    const uintptr_t line = (uintptr_t) 4 << ((ctr >> 16) & 15);
    uintptr_t       a    = (uintptr_t) p & ~(line - 1);
    const uintptr_t e    = (uintptr_t) p + size;
    __asm__ volatile("dsb sy" : : : "memory");
    if (inval) for (; a < e; a += line) __asm__ volatile("dc civac, %0" : : "r"(a) : "memory");
    else       for (; a < e; a += line) __asm__ volatile("dc cvac, %0" : : "r"(a) : "memory");
    __asm__ volatile("dsb sy" : : : "memory");
#else
    (void) p; (void) size; (void) inval;
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
#endif
}

// строка A из теневой копии: сначала поля, потом seq (DSP не увидит новый seq со старыми полями)
static void mb_publish(void) {
    memcpy((uint8_t *) g_mb + 4, (const uint8_t *) &g_mb_a + 4, 60);
    cache_op(g_mb, 64, 0);
    g_mb->seq = g_mb_a.seq;
    cache_op(g_mb, 64, 0);
}

static int mb_pending(void) {
    cache_op(&g_mb->done, 64, 1);
    return __atomic_load_n(&g_mb->done, __ATOMIC_ACQUIRE) != __atomic_load_n(&g_mb_seq, __ATOMIC_ACQUIRE);
}

static void * mb_thread(void * arg) {
    (void) arg;
    pthread_mutex_lock(&g_mb_mu);
    for (;;) {
        while (!g_mb_want) pthread_cond_wait(&g_mb_cv, &g_mb_mu);
        g_mb_want    = 0;
        g_mb_serving = 1;
        pthread_mutex_unlock(&g_mb_mu);
        const int rc = f2qdsp_serve(g_h, (unsigned char *) g_mb, (int) F2Q_PAGE, g_mb_idle);
        pthread_mutex_lock(&g_mb_mu);
        g_mb_serving = 0;
        g_mb_serves++;
        if (rc) {
            if (!__atomic_exchange_n(&g_mb_fail, 1, __ATOMIC_ACQ_REL)) {
                fprintf(stderr, "f2qdsp: serve rc=0x%x - почтовый ящик выключен\n", (unsigned) rc);
            }
        } else if (mb_pending()) { // DSP вышел по простою, а задание пришло - снова (строку A - заново, на всякий случай)
            mb_publish();
            g_mb_want = 1;
        }
    }
    return NULL;
}

// задание в ящик: x и y внутри g_xy, wa - адрес плиток на DSP; 1 - отправлено
static int mb_send(uint64_t wa, int wtype, int k, int tiles, const uint8_t * x, int n, int xstride, float * y, int ystride) {
    if (g_mb_busy || !g_mb || __atomic_load_n(&g_mb_fail, __ATOMIC_ACQUIRE)) return 0;
    const size_t xl = (size_t) n * (size_t) xstride, yl = (size_t) n * (size_t) ystride * 4;
    const uint8_t * yb = (const uint8_t *) y;
    if (n < 1 || n > 64 || !wa || (wa & 127) || x < g_xy || yb < g_xy || x + xl > g_xy + g_xy_size || yb + yl > g_xy + g_xy_size ||
        ((x - g_xy) & 127) || ((yb - g_xy) & 127)) {
        return 0;
    }
    cache_op(x, xl, 0);
    g_mb_a.cmd      = F2Q_MB_MM;
    g_mb_a.wa       = wa;
    g_mb_a.xa       = g_xy_da + (uint64_t) (x - g_xy);
    g_mb_a.ya       = g_xy_da + (uint64_t) (yb - g_xy);
    g_mb_a.wtype    = wtype;
    g_mb_a.tiles    = tiles;
    g_mb_a.k        = k;
    g_mb_a.n        = n;
    g_mb_a.xstride  = xstride;
    g_mb_a.ystride  = ystride;
    // Fold2, llama-bench tg64: Q8 генерация в режиме NPU - 8.81–8.84 т/с на двух потоках DSP
    // против 7.11 на четырёх. Q4 и обработку промпта не меняем; явный F2QDSP_THREADS важнее.
    g_mb_a.nthreads = !g_threads_explicit && wtype == F2Q_W_Q8 && n <= 4 && g_threads > 2 ? 2 : g_threads;
    g_mb_a.flags    = 0;
    g_mb_a.seq      = g_mb_seq + 1;
    mb_publish();
    __atomic_store_n(&g_mb_seq, g_mb_a.seq, __ATOMIC_RELEASE);
    pthread_mutex_lock(&g_mb_mu);
    if (!g_mb_serving && !g_mb_want) {
        g_mb_want = 1;
        pthread_cond_signal(&g_mb_cv);
    }
    pthread_mutex_unlock(&g_mb_mu);
    g_mb_busy  = 1;
    g_mb_y     = y;
    g_mb_yl    = yl;
    g_mb_tiles = tiles;
    return 1;
}

// ждать задание mb_send: 0 - y готов; иначе ошибка (DSP не ответил за F2QDSP_MBOX_TIMEOUT_MS - ящик выключается)
static int mb_wait(int * dsp_us, int64_t * wait_us) {
    if (!g_mb_busy) return AEE_EBADPARM;
    g_mb_busy = 0;
    const uint32_t s  = g_mb_seq;
    const int64_t  t0 = f2q_dev_time_us();
    static int     tmo_ms;
    if (!tmo_ms) tmo_ms = env_int("F2QDSP_MBOX_TIMEOUT_MS", 3000);
    int rc = 0;
    for (unsigned i = 1;; i++) {
        cache_op(&g_mb->done, 64, 1);
        if (__atomic_load_n(&g_mb->done, __ATOMIC_ACQUIRE) == s) break;
        if (__atomic_load_n(&g_mb_fail, __ATOMIC_ACQUIRE)) { rc = AEE_EFAILED; break; }
        if ((i & 255) == 0 && f2q_dev_time_us() - t0 > (int64_t) tmo_ms * 1000) {
            __atomic_store_n(&g_mb_fail, 1, __ATOMIC_RELEASE);
            fprintf(stderr, "f2qdsp: DSP не ответил в почтовый ящик за %d мс (задание %u, ответ %u, serve %d) - ящик выключен\n",
                    tmo_ms, (unsigned) s, (unsigned) g_mb->done, g_mb_serves);
            rc = AEE_EFAILED;
            break;
        }
#if defined(__aarch64__)
        __asm__ volatile("yield");
#endif
    }
    if (wait_us) *wait_us = f2q_dev_time_us() - t0;
    if (rc) {
        g_mbox = 0;
        return rc;
    }
    if (dsp_us) *dsp_us = g_mb->dsp_us;
    rc = g_mb->rc;
    cache_op(g_mb_y, g_mb_yl, 1);
    return rc;
}

static uint32_t rs = 0x9E3779B9u;
static int selftest_via(int wtype, int via);
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }

// DSP против эталона на CPU: случайные веса ggml -> f2q, 3 плитки (последняя неполная), K = 320, n = 5
static int selftest(int wtype) { return selftest_via(wtype, 0); }
// via: 0 - mm; 1 - mm2 (текущий g_wmode): веса со смещения 4096 внутри буфера, при g_wmode=3 - через remote_mmap64
static int selftest_via(int wtype, int via) {
    const int M = 80, K = 320, n = 5, nb = K / 32, tiles = (M + 31) / 32;
    const int bsz = wtype == F2Q_W_Q4 ? 18 : 34;
    const size_t tb = f2q_tile_bytes(wtype, K), xs = f2q_x_stride(K), wb = (size_t) tiles * tb;
    uint8_t * src = (uint8_t *) malloc((size_t) M * nb * bsz);
    float *   xf  = (float *) malloc(sizeof(float) * K * n);
    float *   yr  = (float *) calloc((size_t) n * tiles * 32, sizeof(float));
    const size_t wo = via ? 4096 : 0;
    uint8_t * w0  = (uint8_t *) rpc_alloc(wb + wo);
    uint8_t * w   = w0 ? w0 + wo : NULL;
    // via 2 (почтовый ящик): x и y - в g_xy, веса - только по адресу на DSP
    uint8_t * x   = via == 2 ? g_xy : (uint8_t *) rpc_alloc((size_t) n * xs);
    float *   y   = via == 2 ? (float *) (g_xy + (((size_t) n * xs + 127) & ~(size_t) 127)) : (float *) rpc_alloc((size_t) n * tiles * 32 * 4);
    uint32_t  wa  = 0;
    int ok = 0;
    if (w0) reg_attr(w0, wb + wo); // веса - так же, как настоящие (f2q_dev_alloc): проверяем и атрибуты
    if (w0 && via == 2) {
#ifndef F2QDSP_MOCK
        wa = map_dsp(w0, wb + wo);
#endif
    } else if (w0 && via && g_wmode == 3 && !(wa = map_dsp(w0, wb + wo))) {
        g_wmode = 2; // remote_mmap64 нет или не отобразил - весь буфер весов + смещение
        st("remote_mmap64 не вышел - режим 2; ");
    }
    if (src && xf && yr && w && x && y) {
        for (int i = 0; i < M * nb; i++) {
            uint8_t * b = src + (size_t) i * bsz;
            const uint16_t d = f2q_fp32_to_fp16(0.001f + (float) (rnd() % 1000) * 1e-5f);
            memcpy(b, &d, 2);
            for (int j = 2; j < bsz; j++) b[j] = (uint8_t) (wtype == F2Q_W_Q4 ? rnd() : (rnd() % 255) + 129);
        }
        for (int i = 0; i < K * n; i++) xf[i] = (float) ((int) (rnd() % 2001) - 1000) / 1000.0f;
        f2q_pack_weights(src, wtype, M, K, w, 0, tiles);
        f2q_dev_weights_written(w, wb);
        for (int t = 0; t < n; t++) f2q_quant_x(xf + (size_t) t * K, K, x + (size_t) t * xs);
        f2q_mm_tiles_ref(w, wtype, K, 0, tiles, x, n, (int) xs, yr, tiles * 32);
        memset(y, 0xFF, (size_t) n * tiles * 32 * 4);
        int dus = 0, rc;
        if (via == 2) {
            cache_op(y, (size_t) n * tiles * 32 * 4, 0); // 0xFF - в память, иначе грязные строки кэша затрут ответ DSP
#ifdef F2QDSP_MOCK
            const uint64_t da = (uintptr_t) w;
#else
            const uint64_t da = wa ? (uint64_t) wa + wo : 0;
#endif
            rc = mb_send(da, wtype, K, tiles, x, n, (int) xs, y, tiles * 32) ? mb_wait(&dus, NULL) : AEE_EFAILED;
        } else {
            rc = via ? call_mm2(w0, wb + wo, wa, wo, wtype, K, tiles, x, n, (int) xs, y, tiles * 32, &dus)
                     : call_mm(w, wb, wtype, K, tiles, x, n, (int) xs, y, tiles * 32);
        }
        if (rc) {
            st("selftest %s%s: rc=0x%x; ", via == 2 ? "ящик " : via ? "mm2 " : "", wtype == F2Q_W_Q4 ? "q4" : "q8", (unsigned) rc);
        } else {
            int bad = 0;
            double maxd = 0, maxv = 0;
            for (int i = 0; i < n * tiles * 32; i++) {
                const double dd = y[i] > yr[i] ? (double) y[i] - yr[i] : (double) yr[i] - y[i];
                if (memcmp(&y[i], &yr[i], 4)) bad++;
                if (!(dd <= maxd)) maxd = dd; // NaN тоже попадёт сюда
                const double av = yr[i] < 0 ? -yr[i] : yr[i];
                if (av > maxv) maxv = av;
            }
            ok = bad == 0 || maxd <= 1e-5 * (maxv + 1e-30);
            st("selftest %s%s: %s (%d/%d не бит-в-бит, max|d|=%g); ", via == 2 ? "ящик " : via ? (wa ? "mm2 mmap " : "mm2 ") : "",
               wtype == F2Q_W_Q4 ? "q4" : "q8", ok ? "OK" : "FAIL", bad, n * tiles * 32, maxd);
        }
    } else {
        st("selftest: нет памяти rpcmem; ");
    }
    free(src); free(xf); free(yr);
    unmap_dsp(wa, wb + wo);
    if (w0) R.free(w0);
    if (via != 2) {
        if (x) R.free(x);
        if (y) R.free(y);
    }
    return ok;
}

// возможность cDSP через DSPRPC_GET_DSP_INFO (ядро + DSP); 0 - успех
static int dsp_cap(uint32_t attr, uint32_t * v) {
    if (!R.hctl) return AEE_EUNSUPPORTED;
    struct remote_dsp_capability c = { CDSP_DOMAIN_ID, attr, 0 };
    const int rc = R.hctl(DSPRPC_GET_DSP_INFO, &c, sizeof(c));
    if (rc == 0) *v = c.capability;
    return rc;
}

// медиана времени маленького вызова (накладные FastRPC), мкс; -1 - ошибка
static int64_t call_lat(const uint8_t * w, size_t tb, int K, const uint8_t * x, size_t xs, float * y) {
    int64_t t[21];
    const int nt = (int) (sizeof(t) / sizeof(t[0]));
    if (call_mm(w, tb, F2Q_W_Q8, K, 1, x, 1, (int) xs, y, 32)) return -1;
    for (int i = 0; i < nt; i++) {
        const int64_t t0 = f2q_dev_time_us();
        if (call_mm(w, tb, F2Q_W_Q8, K, 1, x, 1, (int) xs, y, 32)) return -1;
        t[i] = f2q_dev_time_us() - t0;
    }
    for (int i = 1; i < nt; i++) {
        for (int j = i; j > 0 && t[j - 1] > t[j]; j--) { const int64_t s = t[j]; t[j] = t[j - 1]; t[j - 1] = s; }
    }
    return t[nt / 2];
}

// накладные долгого вызова (~0,5 мс на DSP, как умножения в llama): медиана (время вызова - время внутри DSP), мкс
static int64_t call_ovh(const uint8_t * w, size_t wb, int K, int tiles, const uint8_t * x, size_t xs, float * y) {
    int64_t t[9];
    const int nt = (int) (sizeof(t) / sizeof(t[0]));
    int dus = 0;
    if (call_mm2(w, wb, 0, 0, F2Q_W_Q8, K, tiles, x, 1, (int) xs, y, tiles * 32, &dus)) return -1;
    for (int i = 0; i < nt; i++) {
        const int64_t t0 = f2q_dev_time_us();
        if (call_mm2(w, wb, 0, 0, F2Q_W_Q8, K, tiles, x, 1, (int) xs, y, tiles * 32, &dus)) return -1;
        t[i] = f2q_dev_time_us() - t0 - dus;
    }
    for (int i = 1; i < nt; i++) {
        for (int j = i; j > 0 && t[j - 1] > t[j]; j--) { const int64_t s = t[j]; t[j] = t[j - 1]; t[j - 1] = s; }
    }
    return t[nt / 2];
}

static const char * qos_name(int e) {
    return e == RPC_PM_QOS ? "PM QoS" : e == RPC_ADAPTIVE_QOS ? "adaptive QoS" : e == RPC_POLL_QOS ? "опрос (poll)" : "без QoS";
}
static int qos_set(int e) {
    if (!R.hctl64) return AEE_EUNSUPPORTED;
    struct remote_rpc_control_latency l = { (uint32_t) e, 100 };
    if (e == RPC_POLL_QOS) l.latency = (uint32_t) env_int("F2QDSP_POLL_US", 3000); // сколько CPU ждёт ответа в опросе
    return R.hctl64(g_h, DSPRPC_CONTROL_LATENCY, &l, sizeof(l));
}

// Задержка вызова и QoS (DSPRPC_CONTROL_LATENCY). Замер Fold2 (llama, F2QDSP_STATS): вызов на 0,3-0,9 мс работы DSP
// длится на 0,3-0,4 мс дольше - поток CPU засыпает глубоко и долго просыпается; маленький вызов этого не видит (~93 мкс).
// F2QDSP_QOS: 1 - сам: с mm2 мерит накладные долгого вызова без QoS / PM QoS / опрос и берёт лучший (выигрыш > 10%),
// без mm2 - как раньше (PM QoS, если маленький вызов быстрее); 0 - не включать; 2 - PM QoS; 3 - adaptive; 4 - опрос.
static void tune_latency(void) {
    const int K = 256;
    const size_t tb = f2q_tile_bytes(F2Q_W_Q8, K), xs = f2q_x_stride(K);
    uint8_t * w = (uint8_t *) rpc_alloc(tb);
    uint8_t * x = (uint8_t *) rpc_alloc(xs);
    float *   y = (float *) rpc_alloc(32 * 4);
    const int mode = env_int("F2QDSP_QOS", 1);
    if (w && x && y) {
        memset(w, 0, tb);
        memset(x, 0, xs);
        const int64_t base = call_lat(w, tb, K, x, xs, y);
        st("вызов DSP ~%lld мкс; ", (long long) base);
        if (mode >= 2 && mode <= 4) {
            const int e = mode == 2 ? RPC_PM_QOS : mode == 3 ? RPC_ADAPTIVE_QOS : RPC_POLL_QOS;
            st("%s: rc=0x%x; ", qos_name(e), (unsigned) qos_set(e));
        } else if (mode == 1 && g_mm2) {
            const int LK = 2048, LT = 64; // 64 плитки Q8 K=2048 (4,5 МБ) - ~0,5 мс на DSP
            const size_t lb = (size_t) LT * f2q_tile_bytes(F2Q_W_Q8, LK), lxs = f2q_x_stride(LK);
            uint8_t * lw = (uint8_t *) rpc_alloc(lb);
            uint8_t * lx = (uint8_t *) rpc_alloc(lxs);
            float *   ly = (float *) rpc_alloc((size_t) LT * 32 * 4);
            if (lw && lx && ly) {
                memset(lw, 0, lb);
                memset(lx, 0, lxs);
                reg_attr(lw, lb);
                f2q_dev_weights_written(lw, lb);
                const int cand[3] = { RPC_DISABLE_QOS, RPC_PM_QOS, RPC_POLL_QOS };
                int64_t   ov[3];
                int       best = 0;
                for (int i = 0; i < 3; i++) {
                    const int rc = qos_set(cand[i]);
                    ov[i] = rc && i ? -1 : call_ovh(lw, lb, LK, LT, lx, lxs, ly);
                    st("%s: накладные ~%lld мкс%s; ", qos_name(cand[i]), (long long) ov[i], rc && i ? " (не поддерживается)" : "");
                    if (ov[i] >= 0 && (ov[best] < 0 || ov[i] * 10 < ov[best] * 9)) best = i;
                }
                st("выбран %s; ", qos_name(cand[best]));
                qos_set(cand[best]);
            }
            if (lw) R.free(lw);
            if (lx) R.free(lx);
            if (ly) R.free(ly);
        } else if (mode == 1 && base > 0 && R.hctl64) {
            if (qos_set(RPC_PM_QOS) == 0) {
                const int64_t q = call_lat(w, tb, K, x, xs, y);
                if (q > 0 && q * 10 < base * 9) {
                    st("PM QoS: ~%lld мкс, включён; ", (long long) q);
                } else {
                    st("PM QoS: ~%lld мкс, не быстрее - выключен (rc=0x%x); ", (long long) q, (unsigned) qos_set(RPC_DISABLE_QOS));
                }
            }
        }
    }
    if (w) R.free(w);
    if (x) R.free(x);
    if (y) R.free(y);
}

// накладные задания через ящик: медиана (время задания - время внутри DSP), мкс; 64 плитки Q8 K=2048, как call_ovh
static int64_t mb_ovh(void) {
    const int LK = 2048, LT = 64;
    const size_t lb = (size_t) LT * f2q_tile_bytes(F2Q_W_Q8, LK), xs = f2q_x_stride(LK);
    uint8_t * lw = (uint8_t *) rpc_alloc(lb);
    int64_t   t[9], r = -1;
    const int nt = (int) (sizeof(t) / sizeof(t[0]));
    float *   y  = (float *) (g_xy + ((xs + 127) & ~(size_t) 127));
    if (!lw || ((xs + 127) & ~(size_t) 127) + (size_t) LT * 32 * 4 > g_xy_size) goto out;
    memset(lw, 0, lb);
    reg_attr(lw, lb);
    f2q_dev_weights_written(lw, lb);
    memset(g_xy, 0, xs);
    {
#ifdef F2QDSP_MOCK
        const uint64_t da = (uintptr_t) lw;
        const uint32_t wa = 0;
#else
        const uint32_t wa = map_dsp(lw, lb);
        const uint64_t da = wa;
#endif
        int i = 0;
        for (; i <= nt && da; i++) {
            int dus = 0;
            const int64_t t0 = f2q_dev_time_us();
            if (!mb_send(da, F2Q_W_Q8, LK, LT, g_xy, 1, (int) xs, y, LT * 32) || mb_wait(&dus, NULL)) break;
            if (i) t[i - 1] = f2q_dev_time_us() - t0 - dus; // первое - с запуском serve
        }
        unmap_dsp(wa, lb);
        if (i <= nt) goto out;
    }
    for (int i = 1; i < nt; i++) {
        for (int j = i; j > 0 && t[j - 1] > t[j]; j--) { const int64_t s = t[j]; t[j] = t[j - 1]; t[j - 1] = s; }
    }
    r = t[nt / 2];
out:
    if (lw) R.free(lw);
    return r;
}

// F2QDSP_MBOX: 1 (по умолчанию) - почтовый ящик для генерации (n <= 64), если skel умеет serve и самопроверка прошла
static void mb_init(void) {
    if (!env_int("F2QDSP_MBOX", 1)) { st("ящик: выключен (F2QDSP_MBOX=0); "); return; }
    {
        unsigned char info[256] = { 0 };
        if (f2qdsp_info(g_h, info, (int) sizeof(info) - 1) || !strstr((const char *) info, " mb=1")) {
            st("ящик: старый libf2qdsp_skel.so; ");
            return;
        }
    }
#ifndef F2QDSP_MOCK
    if (g_wmode != 3) { st("ящик: нужен режим весов 3 (remote_mmap64); "); return; }
#endif
    g_mb_idle = env_int("F2QDSP_IDLE_MS", 100);
    g_xy_size = page_up((size_t) env_int("F2QDSP_MBOX_KB", 4096) * 1024);
    g_mb      = (f2q_mbox *) rpc_alloc(F2Q_PAGE);
    g_xy      = (uint8_t *) rpc_alloc(g_xy_size);
    if (!g_mb || !g_xy) { st("ящик: нет памяти rpcmem; "); goto fail; }
    memset((void *) g_mb, 0, F2Q_PAGE);
    memset(g_xy, 0, g_xy_size);
    {   // ящик - аргумент serve: драйверу не сбрасывать и не выбрасывать его кэш (это делаем сами)
        const int fd = R.tofd ? R.tofd(g_mb) : -1;
        if (g_attr_w >= 0 && R.rega && fd >= 0) {
            if (R.reg) R.reg(g_mb, (int) F2Q_PAGE, -1);
            R.rega(g_mb, (int) F2Q_PAGE, fd, FASTRPC_ATTR_KEEP_MAP | FASTRPC_ATTR_FORCE_NOFLUSH | FASTRPC_ATTR_FORCE_NOINVALIDATE);
        }
    }
    cache_op(g_mb, F2Q_PAGE, 1);
    cache_op(g_xy, g_xy_size, 1);
#ifdef F2QDSP_MOCK
    g_xy_da = (uintptr_t) g_xy;
#else
    g_xy_da = map_dsp(g_xy, g_xy_size);
    if (!g_xy_da) { st("ящик: remote_mmap64 для x/y не вышел; "); goto fail; }
#endif
    {
        pthread_attr_t a;
        pthread_t      t;
        pthread_attr_init(&a);
        pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
        const int e = pthread_create(&t, &a, mb_thread, NULL);
        pthread_attr_destroy(&a);
        if (e) { st("ящик: поток не создан; "); goto fail; }
    }
    // дальше буферы не освобождаем: DSP мог остаться в serve
    if (!selftest_via(F2Q_W_Q4, 2) || !selftest_via(F2Q_W_Q8, 2)) {
        __atomic_store_n(&g_mb_fail, 1, __ATOMIC_RELEASE);
        st("ящик: самопроверка не пройдена - выключен; ");
        return;
    }
    st("ящик: накладные ~%lld мкс на задание; ", (long long) mb_ovh());
    g_mbox = !__atomic_load_n(&g_mb_fail, __ATOMIC_ACQUIRE);
    return;
fail:
#ifndef F2QDSP_MOCK
    unmap_dsp((uint32_t) g_xy_da, g_xy_size);
#endif
    if (g_mb) R.free(g_mb);
    if (g_xy) R.free(g_xy);
    g_mb = NULL;
    g_xy = NULL;
    g_xy_da = 0;
}

int f2q_dev_init(void) {
    int s0 = state_get();
    if (s0 >= 0) return s0;
    pthread_mutex_lock(&g_init_mu);
    if ((s0 = state_get()) >= 0) { pthread_mutex_unlock(&g_init_mu); return s0; }
    int ok = 0;
    g_status[0] = 0;
    const int mode = f2q_dev_env_mode();
    g_threads_explicit = getenv("F2QDSP_THREADS") != NULL;
    g_threads = env_int("F2QDSP_THREADS", 4);
    g_wmode   = env_int("F2QDSP_WMODE", 3); // не вышло - сам откатится на 2, затем на 0
    g_pool    = env_int("F2QDSP_POOL", 1);
    g_stats   = env_int("F2QDSP_STATS", 0);
    if (env_int("F2QDSP_SAFE", 0)) g_attr_w = -1;
    if (mode != 1) {
        st(mode == 2 ? "F2QDSP=cpu: формат f2q, только CPU; " : "F2QDSP не включён; ");
        goto done;
    }
#ifdef F2QDSP_MOCK
    R.open = mock_open; R.invoke = mock_invoke; R.close = mock_close; R.sc = mock_sc;
    R.alloc = mock_alloc; R.free = mock_free; R.tofd = mock_tofd; R.reg = mock_reg; R.rega = mock_rega;
    R.hctl = mock_hctl; R.hctl64 = mock_hctl64;
    st("MOCK (DSP в процессе); ");
#else
    if (!load_lib()) goto done;
    set_lib_path();
#endif
    if (R.sc && !env_int("F2QDSP_SIGNED", 0)) {
        struct remote_rpc_control_unsigned_module u = { CDSP_DOMAIN_ID, 1 };
        const int rc = R.sc(DSPRPC_CONTROL_UNSIGNED_MODULE, &u, sizeof(u));
        st("unsigned PD: rc=0x%x; ", (unsigned) rc);
    }
    {
        const int64_t t0 = f2q_dev_time_us();
        const int rc = f2qdsp_open(f2qdsp_URI CDSP_DOMAIN, &g_h);
        if (rc) {
            st("открыть f2qdsp на cDSP не удалось: rc=0x%x (нет unsigned PD или не найден libf2qdsp_skel.so); ", (unsigned) rc);
            uint32_t dom = 0, upd = 0;
            const int r1 = dsp_cap(DOMAIN_SUPPORT, &dom), r2 = dsp_cap(UNSIGNED_PD_SUPPORT, &upd);
            if (r1 == 0 || r2 == 0) st("DSP_INFO: cDSP=%d unsigned PD=%d; ", r1 ? -1 : (int) dom, r2 ? -1 : (int) upd);
            else st("DSP_INFO: rc=0x%x; ", (unsigned) r1);
            goto done;
        }
        st("сессия за %lld мс; ", (long long) ((f2q_dev_time_us() - t0) / 1000));
    }
    {   // возможности cDSP (после открытия сессии: ядро спрашивает DSP при первом запуске процесса на нём)
        uint32_t hvx = 0, vp = 0, vc = 0, arch = 0;
        const int rc = dsp_cap(HVX_SUPPORT_128B, &hvx);
        if (rc == 0) {
            const int rp = dsp_cap(VTCM_PAGE, &vp), rv = dsp_cap(VTCM_COUNT, &vc), ra = dsp_cap(ARCH_VER, &arch);
            st("DSP_INFO: HVX128 x%u, VTCM %u КБ x %u, arch 0x%x; ", hvx, rp ? 0 : vp / 1024, rv ? 0 : vc, ra ? 0 : arch);
            // HVX-контекстов меньше, чем потоков: лишние потоки ждали бы qurt_hvx_lock
            if (hvx >= 1 && hvx < (uint32_t) g_threads && !getenv("F2QDSP_THREADS")) g_threads = (int) hvx;
        } else {
            st("DSP_INFO: rc=0x%x; ", (unsigned) rc);
        }
    }
    {
        unsigned char info[256] = { 0 };
        if (f2qdsp_info(g_h, info, (int) sizeof(info) - 1) == 0) {
            st("%s; ", (const char *) info);
            // формат данных меняется вместе с версией: libf2qdsp_skel.so от другой сборки считал бы мусор
            char want[32];
            snprintf(want, sizeof(want), "f2qdsp v%d ", F2Q_VERSION);
            if (strncmp((const char *) info, want, strlen(want)) != 0) {
                st("нужна f2qdsp v%d (libf2qdsp_skel.so и libggml-cpu.so из одного архива) - DSP отключён; ", F2Q_VERSION);
                f2qdsp_close(g_h);
                goto done;
            }
        }
    }
    if (!selftest(F2Q_W_Q4) || !selftest(F2Q_W_Q8)) {
        int again = 0;
        if (g_attr_w >= 0) { // возможно, драйвер не понял атрибуты буферов - повтор без них (как F2QDSP_SAFE=1)
            g_attr_w = -1;
            st("повтор без атрибутов буферов; ");
            again = selftest(F2Q_W_Q4) && selftest(F2Q_W_Q8);
        }
        if (!again) {
            st("самопроверка не пройдена - DSP отключён; ");
            f2qdsp_close(g_h);
            goto done;
        }
    }
    if (g_wmode > 0) {
        unsigned char info[256] = { 0 };
        if (f2qdsp_info(g_h, info, (int) sizeof(info) - 1) == 0 && strstr((const char *) info, " mm2=1")) {
            g_mm2 = selftest_via(F2Q_W_Q4, 1) && selftest_via(F2Q_W_Q8, 1);
            if (!g_mm2 && g_wmode == 3) { // remote_mmap64 мог не заработать - mm2 со смещением
                g_wmode = 2;
                st("повтор mm2 без remote_mmap64; ");
                g_mm2 = selftest_via(F2Q_W_Q4, 1) && selftest_via(F2Q_W_Q8, 1);
            }
        } else {
            st("mm2: старый libf2qdsp_skel.so - вызов mm; ");
        }
        if (!g_mm2) g_wmode = 0;
    }
    tune_latency();
    mb_init();
    st("потоков DSP=%d, атрибуты весов=%d, веса: режим %d%s%s", g_threads, g_attr_w, g_wmode,
       g_wmode ? (g_pool ? ", постоянные потоки" : ", потоки на вызов") : "", g_mbox ? ", почтовый ящик" : "");
    ok = 1;
done:
    state_set(ok);
    pthread_mutex_unlock(&g_init_mu);
    return ok;
}

void * f2q_dev_alloc(size_t size) {
    uint8_t * p   = NULL;
    int       rpc = 0;
    uint32_t wa  = 0;
    if (f2q_dev_init() == 1 && (p = (uint8_t *) rpc_alloc(size)) != NULL) {
        rpc = 1;
        reg_attr(p, size);
        if (g_wmode == 3) wa = map_dsp(p, size);
    }
    if (!p) {
        void * q = NULL;
        if (posix_memalign(&q, 4096, size ? size : 1)) return NULL;
        p = (uint8_t *) q;
    }
    pthread_mutex_lock(&g_al_mu);
    if (g_nal < (int) (sizeof(g_al) / sizeof(g_al[0]))) g_al[g_nal++] = (f2q_region) { p, size, rpc, wa };
    else if (rpc) { // таблица полна - отдаём обычную память
        pthread_mutex_unlock(&g_al_mu);
        unmap_dsp(wa, size);
        R.free(p);
        void * q = NULL;
        return posix_memalign(&q, 4096, size ? size : 1) ? NULL : q;
    }
    pthread_mutex_unlock(&g_al_mu);
    return p;
}

void f2q_dev_free(void * p) {
    if (!p) return;
    int rpc = 0;
    uint32_t wa = 0;
    size_t sz = 0;
    pthread_mutex_lock(&g_al_mu);
    for (int i = 0; i < g_nal; i++) {
        if (g_al[i].p == p) { rpc = g_al[i].rpc; wa = g_al[i].wa; sz = g_al[i].size; g_al[i] = g_al[--g_nal]; break; }
    }
    pthread_mutex_unlock(&g_al_mu);
    unmap_dsp(wa, sz);
    if (rpc) R.free(p); else free(p);
}

int f2q_dev_is_shared(const void * p, size_t size) {
    const uint8_t * a = (const uint8_t *) p;
    int r = 0;
    pthread_mutex_lock(&g_al_mu);
    for (int i = 0; i < g_nal; i++) {
        if (a >= g_al[i].p && a + size <= g_al[i].p + g_al[i].size) { r = g_al[i].rpc; break; }
    }
    pthread_mutex_unlock(&g_al_mu);
    return r && state_get() == 1;
}

void f2q_dev_weights_written(void * p, size_t size) {
#if defined(__aarch64__)
    // при FORCE_NOFLUSH драйвер не чистит кэш весов на каждом вызове - чистим один раз сами (dc cvac до PoC)
    uint64_t ctr;
    __asm__ volatile("mrs %0, ctr_el0" : "=r"(ctr));
    const uintptr_t line = (uintptr_t) 4 << ((ctr >> 16) & 15);
    uintptr_t       a    = (uintptr_t) p & ~(line - 1);
    const uintptr_t e    = (uintptr_t) p + size;
    for (; a < e; a += line) __asm__ volatile("dc cvac, %0" : : "r"(a) : "memory");
    __asm__ volatile("dsb sy" : : : "memory");
#else
    (void) p; (void) size;
#endif
}

int f2q_dev_begin(size_t xbytes, size_t ybytes, uint8_t ** x, float ** y) {
    if (state_get() != 1) return 0;
    if (pthread_mutex_trylock(&g_mu)) return 0;
    if (g_mbox) { // x и y - в буфере ящика (f2q_dev_submit), если влезают
        const size_t yo = (xbytes + 127) & ~(size_t) 127;
        if (yo + ybytes <= g_xy_size) {
            *x = g_xy;
            *y = (float *) (g_xy + yo);
            return 1;
        }
    }
    if (!grow((void **) &g_x, &g_xcap, xbytes) || !grow((void **) &g_y, &g_ycap, ybytes)) {
        pthread_mutex_unlock(&g_mu);
        return 0;
    }
    *x = g_x;
    *y = g_y;
    return 1;
}

int f2q_dev_mm(const uint8_t * w, size_t wbytes, int wtype, int k, int tiles,
               const uint8_t * x, int n, int xstride, float * y, int ystride) {
    const int64_t t0  = g_stats > 0 ? f2q_dev_time_us() : 0;
    int           dus = -1, rc;
    if (g_wmode == 0) {
        rc = call_mm(w, wbytes, wtype, k, tiles, x, n, xstride, y, ystride);
    } else {
        f2q_region r = { NULL, 0, 0, 0 };
        if (g_wmode >= 2) {
            pthread_mutex_lock(&g_al_mu);
            for (int i = 0; i < g_nal; i++) {
                if (g_al[i].rpc && w >= g_al[i].p && w + wbytes <= g_al[i].p + g_al[i].size) { r = g_al[i]; break; }
            }
            pthread_mutex_unlock(&g_al_mu);
        }
        if (r.p) rc = call_mm2(r.p, r.size, g_wmode == 3 ? r.wa : 0, (size_t) (w - r.p), wtype, k, tiles, x, n, xstride, y, ystride, &dus);
        else rc = call_mm2(w, wbytes, 0, 0, wtype, k, tiles, x, n, xstride, y, ystride, &dus);
    }
    if (g_stats > 0 && rc == 0) { // под g_mu (f2q_dev_begin) - один вызов за раз
        g_st_n++;
        g_st_wall += f2q_dev_time_us() - t0;
        g_st_dsp += dus > 0 ? dus : 0;
        g_st_tiles += tiles;
        if (g_st_n % g_stats == 0) {
            fprintf(stderr, "f2qdsp: %lld вызовов: в среднем %lld мкс на вызов, из них внутри DSP %lld мкс, %lld плиток (режим %d)\n",
                    (long long) g_st_n, (long long) (g_st_wall / g_st_n), (long long) (g_st_dsp / g_st_n),
                    (long long) (g_st_tiles / g_st_n), g_wmode);
            g_st_n = g_st_wall = g_st_dsp = g_st_tiles = 0;
        }
    }
    if (rc) {
        g_errors++;
        if (g_errors <= 3) fprintf(stderr, "f2qdsp: mm rc=0x%x (tiles=%d k=%d n=%d)\n", (unsigned) rc, tiles, k, n);
        if (g_errors >= 8) { state_set(0); fprintf(stderr, "f2qdsp: много ошибок - дальше только CPU\n"); }
    }
    return rc;
}

void f2q_dev_end(void) { pthread_mutex_unlock(&g_mu); }

static void wregion(const uint8_t * w, size_t wbytes, f2q_region * r) {
    pthread_mutex_lock(&g_al_mu);
    for (int i = 0; i < g_nal; i++) {
        if (g_al[i].rpc && w >= g_al[i].p && w + wbytes <= g_al[i].p + g_al[i].size) { *r = g_al[i]; break; }
    }
    pthread_mutex_unlock(&g_al_mu);
}

int f2q_dev_submit(const uint8_t * w, size_t wbytes, int wtype, int k, int tiles,
                   const uint8_t * x, int n, int xstride, float * y, int ystride) {
    if (!g_mbox) return 0;
    f2q_region r = { NULL, 0, 0, 0 };
    wregion(w, wbytes, &r);
    if (!r.p) return 0;
#ifdef F2QDSP_MOCK
    const uint64_t da = (uintptr_t) w;
#else
    const uint64_t da = r.wa ? (uint64_t) r.wa + (uint64_t) (w - r.p) : 0;
#endif
    if (!mb_send(da, wtype, k, tiles, x, n, xstride, y, ystride)) return 0;
    if (g_stats > 0) g_mb_t = f2q_dev_time_us();
    return 1;
}

int f2q_dev_wait(int * dsp_us) {
    int     dus = 0;
    int64_t wt  = 0;
    const int rc = mb_wait(&dus, &wt);
    if (dsp_us) *dsp_us = dus;
    if (g_stats > 0 && rc == 0) {
        g_mb_n++;
        g_mb_dsp += dus;
        g_mb_wt += wt;
        g_mb_tl += g_mb_tiles;
        g_mb_wall += f2q_dev_time_us() - g_mb_t;
        if (g_mb_n % g_stats == 0) {
            fprintf(stderr, "f2qdsp: ящик, %lld заданий: в среднем %lld мкс от отправки до ответа, внутри DSP %lld, CPU ждал DSP %lld мкс, %lld плиток\n",
                    (long long) g_mb_n, (long long) (g_mb_wall / g_mb_n), (long long) (g_mb_dsp / g_mb_n), (long long) (g_mb_wt / g_mb_n),
                    (long long) (g_mb_tl / g_mb_n));
            g_mb_n = g_mb_dsp = g_mb_wt = g_mb_tl = g_mb_wall = 0;
        }
    }
    if (rc) {
        g_errors++;
        if (g_errors <= 3) fprintf(stderr, "f2qdsp: ящик rc=0x%x\n", (unsigned) rc);
        if (g_errors >= 8) { state_set(0); fprintf(stderr, "f2qdsp: много ошибок - дальше только CPU\n"); }
    }
    return rc;
}
