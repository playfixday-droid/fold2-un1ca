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
// семафоры QuRT (постоянные потоки mm2)
typedef struct { pthread_mutex_t m; pthread_cond_t c; unsigned v; } qurt_sem_t;
static inline void qurt_sem_init_val(qurt_sem_t * s, unsigned short v) {
    pthread_mutex_init(&s->m, NULL); pthread_cond_init(&s->c, NULL); s->v = v;
}
static inline int qurt_sem_add(qurt_sem_t * s, unsigned int n) {
    pthread_mutex_lock(&s->m); s->v += n; pthread_cond_broadcast(&s->c); pthread_mutex_unlock(&s->m); return 0;
}
static inline int qurt_sem_down(qurt_sem_t * s) {
    pthread_mutex_lock(&s->m); while (!s->v) pthread_cond_wait(&s->c, &s->m); s->v--; pthread_mutex_unlock(&s->m); return 0;
}
static inline void qurt_sem_destroy(qurt_sem_t * s) { pthread_mutex_destroy(&s->m); pthread_cond_destroy(&s->c); }
// кэш (почтовый ящик): на ПК память когерентна - только барьер
typedef unsigned int qurt_addr_t;
typedef unsigned int qurt_size_t;
#define QURT_MEM_CACHE_FLUSH            0
#define QURT_MEM_CACHE_INVALIDATE       1
#define QURT_MEM_CACHE_FLUSH_INVALIDATE 2
#define QURT_MEM_DCACHE                 1
static inline int qurt_mem_cache_clean(qurt_addr_t a, qurt_size_t n, int op, int type) {
    (void) a; (void) n; (void) op; (void) type;
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    return 0;
}
