// f2prio: LD_PRELOAD-библиотека для GPU-задач Fold2 (dacgpu на TFLite GPU / OpenCL): к каждому контексту OpenCL добавляет
// подсказку приоритета Qualcomm (cl_qcom_priority_hint). По умолчанию LOW - композитор (экран, DeX) вытесняет наши
// вычисления, и экран не подвисает, пока GPU декодирует звук. Когда GPU свободен, скорость та же.
// TFLite берёт функции OpenCL через dlsym(handle, "clCreateContext"), поэтому перехватывается сам dlsym: для
// clCreateContext / clCreateContextFromType отдаются обёртки, всё остальное - как есть (настоящий dlsym через dlvsym).
// F2CL_PRIO=low|normal|high|off (читается при каждом создании контекста), F2CL_LOG=1 - строка в stderr на контекст.
// Если драйвер не знает подсказку (нет расширения или ошибка) - контекст создаётся как обычно.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t cl_int;
typedef uint32_t cl_uint;
typedef intptr_t cl_context_properties;
typedef uint64_t cl_bitfield;
typedef void * cl_device_id;
typedef void * cl_context;
typedef void (*notify_fn)(const char *, const void *, size_t, void *);
typedef cl_context (*create_fn)(const cl_context_properties *, cl_uint, const cl_device_id *, notify_fn, void *, cl_int *);
typedef cl_context (*create_type_fn)(const cl_context_properties *, cl_bitfield, notify_fn, void *, cl_int *);
typedef cl_int (*devinfo_fn)(cl_device_id, cl_uint, size_t, void *, size_t *);
typedef void * (*dlsym_fn)(void *, const char *);

// cl_qcom_priority_hint (значения - как в MACE / MNN)
#define CL_CONTEXT_PRIORITY_HINT_QCOM 0x40C9
#define CL_PRIORITY_HINT_HIGH_QCOM    0x40CA
#define CL_PRIORITY_HINT_NORMAL_QCOM  0x40CB
#define CL_PRIORITY_HINT_LOW_QCOM     0x40CC
#define CL_DEVICE_EXTENSIONS          0x1030

static dlsym_fn       real_dlsym;
static create_fn      real_create;
static create_type_fn real_create_type;
static devinfo_fn     real_devinfo;

static void init_real(void) {
    if (real_dlsym) return;
    // bionic: dlsym@LIBC; glibc (тест в CI): GLIBC_2.34 / 2.17 (arm64) / 2.2.5 (x86_64)
    static const char * vers[] = { "LIBC", "GLIBC_2.34", "GLIBC_2.17", "GLIBC_2.2.5", NULL };
    for (int i = 0; vers[i] && !real_dlsym; i++) real_dlsym = (dlsym_fn) dlvsym(RTLD_NEXT, "dlsym", vers[i]);
}

static const char * prio_name(void) {
    const char * e = getenv("F2CL_PRIO");
    return e && *e ? e : "low";
}

static cl_context_properties prio_val(const char * n) {
    if (!strcmp(n, "low")) return CL_PRIORITY_HINT_LOW_QCOM;
    if (!strcmp(n, "normal")) return CL_PRIORITY_HINT_NORMAL_QCOM;
    if (!strcmp(n, "high")) return CL_PRIORITY_HINT_HIGH_QCOM;
    return 0;  // off
}

static int has_ext(const cl_device_id * devs, cl_uint n) {
    if (!real_devinfo || !devs || !n) return 1;  // не узнать - пробуем, при ошибке повтор без подсказки
    static char buf[16384];
    size_t      sz = 0;
    if (real_devinfo(devs[0], CL_DEVICE_EXTENSIONS, sizeof(buf) - 1, buf, &sz) != 0) return 1;
    buf[sz < sizeof(buf) ? sz : sizeof(buf) - 1] = 0;
    return strstr(buf, "cl_qcom_priority_hint") != NULL;
}

// свойства вызывающего без его подсказки приоритета + наша; список пар, в конце 0
static void build_props(const cl_context_properties * in, cl_context_properties * out, int max, cl_context_properties v) {
    int k = 0;
    for (int i = 0; in && in[i] && k < max - 3; i += 2) {
        if (in[i] == CL_CONTEXT_PRIORITY_HINT_QCOM) continue;
        out[k++] = in[i];
        out[k++] = in[i + 1];
    }
    out[k++] = CL_CONTEXT_PRIORITY_HINT_QCOM;
    out[k++] = v;
    out[k]   = 0;
}

static void logp(const char * p, const char * how, cl_int e) {
    if (getenv("F2CL_LOG")) fprintf(stderr, "f2prio: context priority=%s %s (%d)\n", p, how, (int) e);
}

static cl_context my_create(const cl_context_properties * props, cl_uint n, const cl_device_id * devs, notify_fn cb, void * ud,
                            cl_int * err) {
    const char *          p = prio_name();
    cl_context_properties v = prio_val(p);
    if (v && has_ext(devs, n)) {
        cl_context_properties np[64];
        build_props(props, np, 64, v);
        cl_int     e = 0;
        cl_context c = real_create(np, n, devs, cb, ud, &e);
        if (c) {
            logp(p, "ok", 0);
            if (err) *err = 0;
            return c;
        }
        logp(p, "rejected, plain context", e);
    } else if (v) {
        logp(p, "no cl_qcom_priority_hint, plain context", 0);
    }
    return real_create(props, n, devs, cb, ud, err);
}

static cl_context my_create_type(const cl_context_properties * props, cl_bitfield type, notify_fn cb, void * ud, cl_int * err) {
    const char *          p = prio_name();
    cl_context_properties v = prio_val(p);
    if (v) {
        cl_context_properties np[64];
        build_props(props, np, 64, v);
        cl_int     e = 0;
        cl_context c = real_create_type(np, type, cb, ud, &e);
        if (c) {
            logp(p, "ok (from type)", 0);
            if (err) *err = 0;
            return c;
        }
        logp(p, "rejected (from type), plain context", e);
    }
    return real_create_type(props, type, cb, ud, err);
}

__attribute__((visibility("default"))) void * dlsym(void * h, const char * name) {
    init_real();
    if (!real_dlsym) return NULL;
    void * r = real_dlsym(h, name);
    if (!r) return r;
    if (!strcmp(name, "clCreateContext")) {
        real_create = (create_fn) r;
        if (!real_devinfo) real_devinfo = (devinfo_fn) real_dlsym(h, "clGetDeviceInfo");
        return (void *) my_create;
    }
    if (!strcmp(name, "clCreateContextFromType")) {
        real_create_type = (create_type_fn) r;
        return (void *) my_create_type;
    }
    return r;
}
