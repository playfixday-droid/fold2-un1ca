// f2q_dev.h - ARM-сторона драйвера f2qdsp: сессия FastRPC с cDSP, общая с DSP память (rpcmem), вызовы mm.
// libcdsprpc.so грузится через dlopen: без неё (или без F2QDSP=1) всё тихо работает на CPU.
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// 1 - DSP готов (сессия открыта, самопроверка пройдена), 0 - нет. Потокобезопасно, повторный вызов дешёвый.
int          f2q_dev_init(void);
const char * f2q_dev_status(void);           // текст: версия DSP, задержка вызова, причина отказа
int          f2q_dev_env_mode(void);         // F2QDSP: 0 - выкл, 1 - DSP (+CPU), 2 - "cpu": только формат f2q на CPU
// память для весов: rpcmem (видна DSP) если DSP готов, иначе обычная (выравнивание 4096)
void *       f2q_dev_alloc(size_t size);
void         f2q_dev_free(void * p);
int          f2q_dev_is_shared(const void * p, size_t size); // [p, p+size) целиком в памяти, видимой DSP
void         f2q_dev_weights_written(void * p, size_t size); // веса записаны: сброс кэша CPU в память
// вызов DSP: begin захватывает DSP (trylock) и выдаёт буферы x/y в общей памяти; 0 - DSP занят/ошибка
int          f2q_dev_begin(size_t xbytes, size_t ybytes, uint8_t ** x, float ** y);
// плитки [0, tiles) тензора w (wbytes - размер всего тензора); y[t * ystride + r]; 0 - успех
int          f2q_dev_mm(const uint8_t * w, size_t wbytes, int wtype, int k, int tiles,
                        const uint8_t * x, int n, int xstride, float * y, int ystride);
void         f2q_dev_end(void);
int64_t      f2q_dev_time_us(void);
#ifdef __cplusplus
}
#endif
