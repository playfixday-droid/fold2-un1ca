// f2q_mbox.h - почтовый ящик ARM <-> cDSP в общей памяти (f2qdsp_serve): DSP сидит в одном долгом вызове FastRPC и
// берёт задания из памяти - без FastRPC на каждое умножение. Замер Fold2 (llama, F2QDSP_STATS): вызов FastRPC
// длится на 0,3-0,45 мс дольше работы DSP (Q4: 650 мкс при 325 внутри DSP, ~150 вызовов на токен), QoS / опрос
// этого не меняют.
// Ящик - отдельная страница rpcmem (аргумент io вызова serve). Веса, x и y - по адресам на DSP (remote_mmap64):
// эти буферы не аргументы вызова, и драйвер не чистит/не сбрасывает их кэш, пока ARM и DSP работают.
// Строка A (64 байта) пишет только ARM, строка B - только DSP. Порядок: ARM пишет x, сбрасывает в память (dc cvac),
// пишет поля и seq, сбрасывает строку; DSP видит новый seq (сбросив свою копию строки), сбрасывает свою копию x,
// считает, сбрасывает y в память, пишет rc/dsp_us/done.
#pragma once
#include <stdint.h>

#define F2Q_MB_MM   1 // умножение: плитки по адресу wa, x по xa, y по ya (адреса на DSP)
#define F2Q_MB_EXIT 2 // выйти из f2qdsp_serve
#define F2Q_MB_SIZE 256

typedef struct {
    // строка A (ARM), 64 байта
    volatile uint32_t seq; // номер задания (растёт)
    uint32_t          cmd;
    uint64_t          wa, xa, ya;
    int32_t           wtype, tiles, k, n, xstride, ystride, nthreads, flags;
    uint32_t          pad_a[32 - 16];
    // строка B (DSP), со 128-го байта
    volatile uint32_t done;   // номер последнего выполненного задания
    int32_t           rc;     // 0 - успех
    int32_t           dsp_us; // время задания на DSP, мкс
    volatile uint32_t alive;  // 1 - DSP в цикле f2qdsp_serve
    uint32_t          jobs;   // заданий за этот вызов f2qdsp_serve
    uint32_t          pad_b[32 - 5];
} f2q_mbox;

#ifdef __cplusplus
static_assert(sizeof(f2q_mbox) == F2Q_MB_SIZE, "f2q_mbox");
#else
_Static_assert(sizeof(f2q_mbox) == F2Q_MB_SIZE, "f2q_mbox");
#endif
