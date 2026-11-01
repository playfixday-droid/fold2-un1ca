// mock_dsp.c - mock-сборка DSP-стороны на ПК: настоящие f2qdsp_skel.c (маршалинг qaic) и f2qdsp_imp.c,
// методы переименованы в impl_* (чтобы не конфликтовать с заглушкой в f2q_dev.c), HAP_power - пустышка.
// f2q_mock_mm_calls() - число вызовов mm, дошедших до "DSP" (для ggml_test: проверить, что DSP-путь работал).
#include <stdlib.h>
#include "HAP_power.h"
int HAP_power_set(void * ctx, HAP_power_request_t * r) { (void) ctx; (void) r; return 0; }

#define f2qdsp_slim f2qdsp_skel_slim // таблица методов есть и в stub, и в skel
#define __QAIC_HEADER(ff) impl_##ff
#define __QAIC_IMPL(ff)   impl_##ff
#include "f2qdsp_skel.c"

#define f2qdsp_open  impl_f2qdsp_open
#define f2qdsp_close impl_f2qdsp_close
#define f2qdsp_info  impl_f2qdsp_info
#define f2qdsp_power impl_f2qdsp_power
#define f2qdsp_mm    impl_f2qdsp_mm_real
#ifndef __HEXAGON_ARCH__
#define __HEXAGON_ARCH__ 66
#endif
#include "../../dsp/f2qdsp_imp.c"
#undef f2qdsp_mm

static volatile long g_mock_mm_calls;
long f2q_mock_mm_calls(void) { return g_mock_mm_calls; }

int impl_f2qdsp_mm(remote_handle64 h, const unsigned char * w, int wLen, const unsigned char * x, int xLen,
                   unsigned char * y, int yLen, int wtype, int tiles, int k, int n, int xstride, int ystride, int nthreads) {
    __atomic_add_fetch(&g_mock_mm_calls, 1, __ATOMIC_RELAXED);
    return impl_f2qdsp_mm_real(h, w, wLen, x, xLen, y, yLen, wtype, tiles, k, n, xstride, ystride, nthreads);
}
