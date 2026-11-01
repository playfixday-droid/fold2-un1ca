// qurt.h - имитация QuRT на ПК (pthreads) для mock-сборки f2qdsp_imp.c. Только то, что использует f2qdsp.
#pragma once
#include <pthread.h>
#include <stdlib.h>
#include <stddef.h>
#define QURT_EOK 0
#define QURT_HVX_MODE_128B 1
typedef pthread_t qurt_thread_t;
typedef struct { void * stack; size_t size; unsigned short prio; } qurt_thread_attr_t;
static inline void qurt_thread_attr_init(qurt_thread_attr_t * a) { a->stack = NULL; a->size = 0; a->prio = 100; }
static inline void qurt_thread_attr_set_name(qurt_thread_attr_t * a, const char * n) { (void) a; (void) n; }
static inline void qurt_thread_attr_set_stack_addr(qurt_thread_attr_t * a, void * s) { a->stack = s; }
static inline void qurt_thread_attr_set_stack_size(qurt_thread_attr_t * a, unsigned s) { a->size = s; }
static inline void qurt_thread_attr_set_priority(qurt_thread_attr_t * a, unsigned short p) { a->prio = p; }
static inline qurt_thread_t qurt_thread_get_id(void) { return pthread_self(); }
static inline int qurt_thread_get_priority(qurt_thread_t t) { (void) t; return 100; }
typedef struct { void (*fn)(void *); void * arg; } qurt_mock_start;
static void * qurt_mock_entry(void * p) {
    qurt_mock_start s = *(qurt_mock_start *) p;
    free(p);
    s.fn(s.arg);
    return NULL;
}
static inline int qurt_thread_create(qurt_thread_t * t, qurt_thread_attr_t * a, void (*fn)(void *), void * arg) {
    (void) a;
    qurt_mock_start * s = (qurt_mock_start *) malloc(sizeof(*s));
    if (!s) return -1;
    s->fn = fn; s->arg = arg;
    if (pthread_create(t, NULL, qurt_mock_entry, s)) { free(s); return -1; }
    return QURT_EOK;
}
static inline int qurt_thread_join(qurt_thread_t t, int * st) { *st = 0; return pthread_join(t, NULL); }
static inline void qurt_thread_exit(int st) { (void) st; pthread_exit(NULL); }
// HVX на ПК нет: lock "не удаётся" -> f2qdsp_imp.c считает эталонным ядром
static inline int qurt_hvx_lock(int mode) { (void) mode; return -1; }
static inline int qurt_hvx_unlock(void) { return 0; }
