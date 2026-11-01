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
static void * mock_alloc(int heap, uint32_t fl, int size) {
    (void) heap; (void) fl;
    void * p = NULL;
    return posix_memalign(&p, 4096, (size_t) size) ? NULL : p;
}
static void   mock_free(void * p) { free(p); }
static int    mock_tofd(void * p) { (void) p; return 77; }
#endif

static pthread_mutex_t g_init_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_mu      = PTHREAD_MUTEX_INITIALIZER; // один вызов DSP за раз (scratch общий)
static pthread_mutex_t g_al_mu   = PTHREAD_MUTEX_INITIALIZER;
static volatile int    g_state   = -1;                         // -1 не пробовали, 0 нет DSP, 1 готов
static char            g_status[768];
static remote_handle64 g_h;
static int             g_threads = 4;
static int             g_attr_w  = FASTRPC_ATTR_KEEP_MAP | FASTRPC_ATTR_FORCE_NOFLUSH;
static int             g_errors;
static uint8_t *       g_x;
static size_t          g_xcap;
static float *         g_y;
static size_t          g_ycap;

typedef struct { uint8_t * p; size_t size; int rpc; } f2q_region;
static f2q_region g_al[4096];
static int        g_nal;

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
    if (!R.open || !R.invoke || !R.close) { st("в libcdsprpc нет remote_handle64_*; "); return 0; }
    if (!R.alloc || !R.free) { st("в libcdsprpc нет rpcmem_alloc (нужна общая память); "); return 0; }
    if (R.init) R.init();
    return 1;
}

static void set_lib_path(void) {
    if (getenv("ADSP_LIBRARY_PATH")) { st("ADSP_LIBRARY_PATH=%s; ", getenv("ADSP_LIBRARY_PATH")); return; }
    char dir[512] = ".";
    Dl_info di;
    if (dladdr((void *) &f2q_dev_init, &di) && di.dli_fname) {
        snprintf(dir, sizeof(dir), "%s", di.dli_fname);
        char * s = strrchr(dir, '/');
        if (s) *s = 0; else snprintf(dir, sizeof(dir), ".");
    }
    char p[1400];
    snprintf(p, sizeof(p), "%s/../dsp;%s;/vendor/dsp/cdsp;/vendor/lib/rfsa/adsp;/system/lib/rfsa/adsp;/dsp", dir, dir);
    setenv("ADSP_LIBRARY_PATH", p, 0);
    st("ADSP_LIBRARY_PATH=%s; ", p);
}
#endif

static void * rpc_alloc(size_t size) {
    if (!R.alloc || size == 0 || size > (size_t) INT_MAX) return NULL;
    return R.alloc(F2Q_HEAP_SYSTEM, F2Q_RPC_CACHED, (int) size);
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

static uint32_t rs = 0x9E3779B9u;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 17; rs ^= rs << 5; return rs; }

// DSP против эталона на CPU: случайные веса ggml -> f2q, 3 плитки (последняя неполная), K = 320, n = 5
static int selftest(int wtype) {
    const int M = 80, K = 320, n = 5, nb = K / 32, tiles = (M + 31) / 32;
    const int bsz = wtype == F2Q_W_Q4 ? 18 : 34;
    const size_t tb = f2q_tile_bytes(wtype, K), xs = f2q_x_stride(K), wb = (size_t) tiles * tb;
    uint8_t * src = (uint8_t *) malloc((size_t) M * nb * bsz);
    float *   xf  = (float *) malloc(sizeof(float) * K * n);
    float *   yr  = (float *) calloc((size_t) n * tiles * 32, sizeof(float));
    uint8_t * w   = (uint8_t *) rpc_alloc(wb);
    uint8_t * x   = (uint8_t *) rpc_alloc((size_t) n * xs);
    float *   y   = (float *) rpc_alloc((size_t) n * tiles * 32 * 4);
    int ok = 0;
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
        const int rc = call_mm(w, wb, wtype, K, tiles, x, n, (int) xs, y, tiles * 32);
        if (rc) {
            st("selftest %s: mm rc=0x%x; ", wtype == F2Q_W_Q4 ? "q4" : "q8", (unsigned) rc);
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
            st("selftest %s: %s (%d/%d не бит-в-бит, max|d|=%g); ", wtype == F2Q_W_Q4 ? "q4" : "q8",
               ok ? "OK" : "FAIL", bad, n * tiles * 32, maxd);
        }
    } else {
        st("selftest: нет памяти rpcmem; ");
    }
    free(src); free(xf); free(yr);
    if (w) R.free(w);
    if (x) R.free(x);
    if (y) R.free(y);
    return ok;
}

int f2q_dev_init(void) {
    if (g_state >= 0) return g_state;
    pthread_mutex_lock(&g_init_mu);
    if (g_state >= 0) { pthread_mutex_unlock(&g_init_mu); return g_state; }
    int ok = 0;
    g_status[0] = 0;
    const int mode = f2q_dev_env_mode();
    g_threads = env_int("F2QDSP_THREADS", 4);
    if (env_int("F2QDSP_SAFE", 0)) g_attr_w = -1;
    if (mode != 1) {
        st(mode == 2 ? "F2QDSP=cpu: формат f2q, только CPU; " : "F2QDSP не включён; ");
        goto done;
    }
#ifdef F2QDSP_MOCK
    R.open = mock_open; R.invoke = mock_invoke; R.close = mock_close; R.sc = mock_sc;
    R.alloc = mock_alloc; R.free = mock_free; R.tofd = mock_tofd;
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
            goto done;
        }
        st("сессия за %lld мс; ", (long long) ((f2q_dev_time_us() - t0) / 1000));
    }
    {
        unsigned char info[256] = { 0 };
        if (f2qdsp_info(g_h, info, (int) sizeof(info) - 1) == 0) st("%s; ", (const char *) info);
    }
    if (!selftest(F2Q_W_Q4) || !selftest(F2Q_W_Q8)) {
        st("самопроверка не пройдена - DSP отключён; ");
        f2qdsp_close(g_h);
        goto done;
    }
    {   // задержка одного маленького вызова (накладные FastRPC)
        const int K = 256;
        const size_t tb = f2q_tile_bytes(F2Q_W_Q8, K), xs = f2q_x_stride(K);
        uint8_t * w = (uint8_t *) rpc_alloc(tb);
        uint8_t * x = (uint8_t *) rpc_alloc(xs);
        float *   y = (float *) rpc_alloc(32 * 4);
        if (w && x && y) {
            memset(w, 0, tb);
            memset(x, 0, xs);
            call_mm(w, tb, F2Q_W_Q8, K, 1, x, 1, (int) xs, y, 32);
            const int64_t t0 = f2q_dev_time_us();
            for (int i = 0; i < 20; i++) call_mm(w, tb, F2Q_W_Q8, K, 1, x, 1, (int) xs, y, 32);
            st("вызов DSP ~%lld мкс; ", (long long) ((f2q_dev_time_us() - t0) / 20));
        }
        if (w) R.free(w);
        if (x) R.free(x);
        if (y) R.free(y);
    }
    st("потоков DSP=%d, атрибуты весов=%d", g_threads, g_attr_w);
    ok = 1;
done:
    g_state = ok;
    pthread_mutex_unlock(&g_init_mu);
    return ok;
}

void * f2q_dev_alloc(size_t size) {
    uint8_t * p   = NULL;
    int       rpc = 0;
    if (f2q_dev_init() == 1 && (p = (uint8_t *) rpc_alloc(size)) != NULL) {
        rpc = 1;
        const int fd = R.tofd ? R.tofd(p) : -1;
        if (g_attr_w >= 0 && R.rega && fd >= 0) { // перерегистрация с атрибутами: постоянное отображение, без flush на вызов
            if (R.reg) R.reg(p, (int) size, -1);
            R.rega(p, (int) size, fd, g_attr_w);
        }
    }
    if (!p) {
        void * q = NULL;
        if (posix_memalign(&q, 4096, size ? size : 1)) return NULL;
        p = (uint8_t *) q;
    }
    pthread_mutex_lock(&g_al_mu);
    if (g_nal < (int) (sizeof(g_al) / sizeof(g_al[0]))) g_al[g_nal++] = (f2q_region) { p, size, rpc };
    else if (rpc) { // таблица полна - отдаём обычную память
        pthread_mutex_unlock(&g_al_mu);
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
    pthread_mutex_lock(&g_al_mu);
    for (int i = 0; i < g_nal; i++) {
        if (g_al[i].p == p) { rpc = g_al[i].rpc; g_al[i] = g_al[--g_nal]; break; }
    }
    pthread_mutex_unlock(&g_al_mu);
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
    return r && g_state == 1;
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
    if (g_state != 1) return 0;
    if (pthread_mutex_trylock(&g_mu)) return 0;
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
    const int rc = call_mm(w, wbytes, wtype, k, tiles, x, n, xstride, y, ystride);
    if (rc) {
        g_errors++;
        if (g_errors <= 3) fprintf(stderr, "f2qdsp: mm rc=0x%x (tiles=%d k=%d n=%d)\n", (unsigned) rc, tiles, k, n);
        if (g_errors >= 8) { g_state = 0; fprintf(stderr, "f2qdsp: много ошибок - дальше только CPU\n"); }
    }
    return rc;
}

void f2q_dev_end(void) { pthread_mutex_unlock(&g_mu); }
