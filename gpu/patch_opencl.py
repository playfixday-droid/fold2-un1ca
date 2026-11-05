#!/usr/bin/env python3
# patch_opencl.py - OpenCL-кернелы ggml компилируются на Adreno 650 (драйвер OpenCL 2.0, без cl_khr_integer_dot_product).
# Часть кернелов *_dp4a.cl зовёт dot_acc_sat_4x8packed_ss_int() и собирается при старте без проверки расширения
# (gemm_noshuffle_q3_k_q8_1_dp4a): на Fold2 компиляция падала -> llama-server с -ngl > 0 завершался сразу.
# Здесь: если расширения нет - та же функция обычным кодом (результат тот же; на A6xx эти кернелы и не вызываются,
# их выбор проверяет has_integer_dot). Кернелы с записью в 3D-картинки - с расширением cl_khr_3d_image_writes.
# ggml-opencl.cpp: кернел, который драйвер всё равно не скомпилировал, пропускается (предупреждение в логе) вместо
# exit(1) при старте - остальные работают. Выравнивание буфера до создания бэкенда (whisper.cpp) больше не segfault.
# Повторный запуск ничего не меняет. Аргумент - корень проекта (там ggml/).
import re
import sys
from pathlib import Path

MARK = "// fold2: patch_opencl"
FALLBACK = MARK + r""" - no cl_khr_integer_dot_product (Adreno 6xx): plain-code replacement
#ifndef cl_khr_integer_dot_product
inline int f2_dot_acc_sat_4x8packed_ss_int(uint a, uint b, int c) {
    const char4 x = as_char4(a), y = as_char4(b);
    return add_sat(c, (int) x.s0 * y.s0 + (int) x.s1 * y.s1 + (int) x.s2 * y.s2 + (int) x.s3 * y.s3);
}
#define dot_acc_sat_4x8packed_ss_int f2_dot_acc_sat_4x8packed_ss_int
#endif
"""

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
kd = root / "ggml/src/ggml-opencl/kernels"
if not kd.is_dir():
    sys.exit(f"нет {kd}")
IMG3D = MARK + "\n#ifdef cl_khr_3d_image_writes\n#pragma OPENCL EXTENSION cl_khr_3d_image_writes : enable\n#endif\n"
n = m = 0
for f in sorted(kd.glob("*.cl")):
    s = f.read_text()
    if MARK in s:
        continue
    pre = ""
    if "dot_acc_sat_4x8packed_ss_int" in s:
        pre += FALLBACK
        n += 1
    if re.search(r"write_only\s+image3d_t", s):
        pre += IMG3D
        m += 1
    if pre:
        f.write_text(pre + s)
print(f"patch_opencl: {n} кернелов с заменой dot_acc_sat_4x8packed_ss_int, {m} - с cl_khr_3d_image_writes")

# ggml-opencl.cpp: неудачная компиляция кернела не роняет процесс
cp = root / "ggml/src/ggml-opencl/ggml-opencl.cpp"
c = cp.read_text()
if MARK not in c:
    helper = ("\n" + MARK + ": kernel that the driver failed to compile -> nullptr + warning instead of exit(1)\n"
              "static cl_kernel f2_cl_kernel(cl_program p, const char * name) {\n"
              "    if (!p) {\n"
              "        GGML_LOG_WARN(\"ggml_opencl: fold2: kernel %s skipped (its program did not compile)\\n\", name);\n"
              "        return nullptr;\n"
              "    }\n"
              "    cl_int e = CL_SUCCESS;\n"
              "    cl_kernel k = clCreateKernel(p, name, &e);\n"
              "    if (e != CL_SUCCESS) {\n"
              "        GGML_LOG_WARN(\"ggml_opencl: fold2: kernel %s unavailable (err %d)\\n\", name, e);\n"
              "        return nullptr;\n"
              "    }\n"
              "    return k;\n"
              "}\n")
    a = "inline std::string read_file(const std::string &path) {"
    if c.count(a) != 1:
        sys.exit(f"{cp}: нет read_file")
    c = c.replace(a, helper + "\n" + a)
    # сборка из исходника: не фатально (fatal=true -> false), кэш бинарников остаётся
    c, k1 = re.subn(r"(build_program_from_source_ex\(ctx, dev, program_buffer, compile_opts, /\*fatal=\*/)true\)", r"\1false)", c)
    if k1 == 0:  # старый ggml: exit(1) прямо в build_program_from_source
        c, k1 = re.subn(r'(GGML_LOG_ERROR\("ggml_opencl: kernel compile error:\\n\\n%s\\n", program_log\);\s*free\(program_log\);\s*)exit\(1\);',
                        r"\1clReleaseProgram(p);\n        return nullptr;", c)
    c, k2 = re.subn(r"CL_CHECK\(\(([^;=]+?)\s*=\s*clCreateKernel\(([\w\->.\[\]]+),\s*([^,;]+?),\s*&err\),\s*err\)\);",
                    r"\1 = f2_cl_kernel(\2, \3);", c)
    c, k3 = re.subn(r"CL_CHECK\(clReleaseProgram\(([\w\->.\[\]]+)\)\);", r"if (\1) clReleaseProgram(\1);", c)
    # Q4_0 при ne11 > 2 (разбор запроса) для весов, которым не подошли Adreno-кернелы (маленькие матрицы): ggml берёт
    # kernel_mul_mat_q4_0_f32_1d_8x_flat, а его на компиляторе Adreno старше 38.11 (у Fold2 - E031.37) не собирают ->
    # clSetKernelArg с пустым кернелом, GGML_ASSERT. Без этого кернела - тот же расчёт кернелом матрица x вектор (8x_flat).
    c, k4 = re.subn(r"(src1t == GGML_TYPE_F32 &&\s*ne00%32 == 0 &&\s*ne11 > 2)\) \{",
                    r"\1 &&\n        (src0t != GGML_TYPE_Q4_0 || (backend_ctx->gpu_family == INTEL ? backend_ctx->kernel_mul_mat_q4_0_f32_1d_16x_flat"
                    r" : backend_ctx->kernel_mul_mat_q4_0_f32_1d_8x_flat) != nullptr)) { // fold2", c)
    # выравнивание / предельный размер буфера берутся из backend_ctx, а его создаёт ggml_cl_init() - при создании бэкенда.
    # whisper.cpp размещает веса модели раньше, чем создаёт бэкенд -> backend_ctx == NULL -> segfault (код -11) при загрузке
    # (whisper.cpp#3935, тот же стек на Adreno 643). ggml_cl_init(dev) создаёт контекст, если его нет, и возвращает готовый.
    c, k5 = re.subn(r"(ggml_backend_opencl_device_context \* dev_ctx = \(ggml_backend_opencl_device_context \*\) ([\w\->]+)->context;"
                    r"\s*(?:return |return \(void \*\) \(uintptr_t\) |max_size = |size \+= 4 \* ))dev_ctx->backend_ctx->",
                    r"\1ggml_cl_init(\2)->", c)
    cp.write_text(c)
    print(f"patch_opencl: ggml-opencl.cpp - не фатальная сборка: {k1}, кернелов через f2_cl_kernel: {k2}, clReleaseProgram: {k3}, Q4_0 без 1d-кернела: {k4}, backend_ctx по требованию: {k5}")
    if k1 == 0 or k2 == 0:
        sys.exit("patch_opencl: якоря ggml-opencl.cpp не нашлись (другая версия ggml?)")
