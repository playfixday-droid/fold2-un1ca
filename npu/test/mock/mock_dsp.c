// mock_dsp.c - mock-сборка DSP-стороны на ПК: настоящие f2qdsp_skel.c (маршалинг qaic) и f2qdsp_imp.c,
// методы переименованы в impl_* (чтобы не конфликтовать с заглушкой в f2q_dev.c), HAP_power - пустышка.
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
#define f2qdsp_mm    impl_f2qdsp_mm
#ifndef __HEXAGON_ARCH__
#define __HEXAGON_ARCH__ 66
#endif
#include "../../dsp/f2qdsp_imp.c"
