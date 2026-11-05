#!/bin/sh
# Проверка f2prio на Linux (glibc): поддельная libOpenCL.so печатает свойства контекста; программа берёт функции так же,
# как TFLite (dlopen("libOpenCL.so") + dlsym(handle, ...)). С LD_PRELOAD=libf2prio.so должна появиться пара 0x40c9=0x40cc.
set -eu
T=$(mktemp -d); D=$(cd "$(dirname "$0")" && pwd)
cat > $T/fakecl.c <<'C'
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
static int reject = 0;
void * clCreateContext(const intptr_t * p, unsigned n, void * const * d, void * cb, void * ud, int * err) {
    printf("props:"); int hint = 0; for (int i = 0; p && p[i]; i += 2) { printf(" 0x%lx=0x%lx", (long) p[i], (long) p[i + 1]); if (p[i] == 0x40C9) hint = 1; }
    printf("\n"); if (hint && reject) { if (err) *err = -64; return NULL; } if (err) *err = 0; return (void *) 0x1234;
}
int clGetDeviceInfo(void * d, unsigned what, size_t sz, void * v, size_t * ret) {
    const char * e = getenv("FAKE_EXT") ? getenv("FAKE_EXT") : "cl_khr_fp16 cl_qcom_priority_hint cl_qcom_perf_hint";
    if (what != 0x1030) return -30; size_t l = strlen(e) + 1; if (v && sz >= l) memcpy(v, e, l); if (ret) *ret = l; return 0;
}
void fake_reject(int r) { reject = r; }
C
cat > $T/prog.c <<'C'
#include <dlfcn.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
typedef void * (*cc)(const intptr_t *, unsigned, void * const *, void *, void *, int *);
int main(int argc, char ** argv) {
    void * h = dlopen("libOpenCL.so", RTLD_NOW | RTLD_LOCAL); if (!h) { printf("dlopen: %s\n", dlerror()); return 1; }
    cc f = (cc) dlsym(h, "clCreateContext"); void (*rej)(int) = (void (*)(int)) dlsym(h, "fake_reject");
    if (argc > 1) rej(1);
    intptr_t props[] = { 0x1084, 0x77, 0 }; void * dev = (void *) 1; int err = 5;
    void * c = f(props, 1, &dev, NULL, NULL, &err); printf("ctx=%p err=%d\n", c, err); return c ? 0 : 1;
}
C
cc -shared -fPIC -o $T/libOpenCL.so $T/fakecl.c
cc -o $T/prog $T/prog.c -ldl
cc -shared -fPIC -O2 -Wall -o $T/libf2prio.so $D/f2prio.c -ldl
ok() { echo "ok: $1"; } ; bad() { echo "FAIL: $1"; cat $T/out; exit 1; }
LD_LIBRARY_PATH=$T $T/prog > $T/out; grep -q "0x40c9" $T/out && bad "без LD_PRELOAD подсказки быть не должно"; ok "без прослойки - как было"
LD_LIBRARY_PATH=$T LD_PRELOAD=$T/libf2prio.so F2CL_LOG=1 $T/prog > $T/out 2>&1; grep -q "0x1084=0x77 0x40c9=0x40cc" $T/out || bad "low"; ok "low по умолчанию, свои свойства сохранены"
LD_LIBRARY_PATH=$T LD_PRELOAD=$T/libf2prio.so F2CL_PRIO=normal $T/prog > $T/out; grep -q "0x40c9=0x40cb" $T/out || bad "normal"; ok "normal"
LD_LIBRARY_PATH=$T LD_PRELOAD=$T/libf2prio.so F2CL_PRIO=off $T/prog > $T/out; grep -q "0x40c9" $T/out && bad "off"; ok "off"
LD_LIBRARY_PATH=$T LD_PRELOAD=$T/libf2prio.so FAKE_EXT=cl_khr_fp16 $T/prog > $T/out; grep -q "0x40c9" $T/out && bad "без расширения"; ok "нет расширения - обычный контекст"
LD_LIBRARY_PATH=$T LD_PRELOAD=$T/libf2prio.so F2CL_LOG=1 $T/prog reject > $T/out 2>&1; grep -q "ctx=0x1234 err=0" $T/out || bad "повтор без подсказки"; grep -c "props:" $T/out | grep -q 2 || bad "две попытки"; ok "драйвер отверг подсказку - повтор без неё"
rm -rf $T; echo "f2prio: все проверки прошли"
