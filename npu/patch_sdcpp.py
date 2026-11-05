#!/usr/bin/env python3
# patch_sdcpp.py - веса MUL_MAT в stable-diffusion.cpp кладутся в "extra buffer types" CPU-бэкенда ggml
# (как в llama.cpp): CPU_REPACK (Q4_0 -> Q4_0_4x4, NEON dotprod) и F2QDSP (cDSP через FastRPC, см. patch_llama.py).
# Без патча sd.cpp берёт только обычный CPU-буфер (или mmap) - repack и DSP не работают.
# Переменные среды: SD_CPU_EXTRA=0 - выключить; SD_F2QDSP_FILTER=подстрока - на DSP только тензоры с ней в имени.
import sys
from pathlib import Path


def patch(path: Path, anchor: str, text: str, after: bool = True, replace: bool = False) -> None:
    s = path.read_text()
    n = s.count(anchor)
    if n != 1:
        sys.exit(f"{path}: якорь найден {n} раз(а), ожидался 1: {anchor!r}")
    s = s.replace(anchor, text if replace else (anchor + text if after else text + anchor))
    path.write_text(s)


HELPER = r'''
// fold2: extra buffer types CPU (CPU_REPACK, F2QDSP) для весов MUL_MAT
static ggml_backend_buffer_type_t sd_cpu_extra_buft_for(ggml_backend_t compute_backend,
                                                        ggml_backend_t params_backend,
                                                        ggml_tensor* weight,
                                                        enum ggml_op usage_op,
                                                        const std::string& name) {
    static const bool enabled = [] {
        const char* e = getenv("SD_CPU_EXTRA");
        return !(e != nullptr && e[0] == '0');
    }();
    if (!enabled || weight == nullptr || usage_op != GGML_OP_NONE || compute_backend == nullptr ||
        params_backend == nullptr || !sd_backend_is_cpu(compute_backend) || !sd_backend_is_cpu(params_backend)) {
        return nullptr;
    }
    if (!ggml_is_quantized(weight->type) || weight->ne[1] < 2 || weight->ne[2] != 1 || weight->ne[3] != 1 ||
        weight->view_src != nullptr) {
        return nullptr;
    }
    ggml_backend_dev_t cpu_dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_CPU);
    if (cpu_dev == nullptr) {
        return nullptr;
    }
    auto get_extra = (ggml_backend_dev_get_extra_bufts_t)ggml_backend_reg_get_proc_address(
        ggml_backend_dev_backend_reg(cpu_dev), "ggml_backend_dev_get_extra_bufts");
    if (get_extra == nullptr) {
        return nullptr;
    }
    static const char* filter = getenv("SD_F2QDSP_FILTER");
    for (ggml_backend_buffer_type_t* p = get_extra(cpu_dev); p != nullptr && *p != nullptr; ++p) {
        if (weight->buffer != nullptr) {
            if (ggml_backend_buffer_get_type(weight->buffer) == *p) {
                return *p;
            }
            continue;
        }
        if (filter != nullptr && filter[0] != '\0' && strcmp(ggml_backend_buft_name(*p), "F2QDSP") == 0 &&
            name.find(filter) == std::string::npos) {
            continue;
        }
        if (device_supports_param_op(cpu_dev, weight, GGML_OP_MUL_MAT, *p)) {
            static std::mutex mu;
            static std::map<std::string, int> seen;
            std::lock_guard<std::mutex> lk(mu);
            if (seen[ggml_backend_buft_name(*p)]++ == 0) {
                LOG_INFO("fold2: weights for MUL_MAT -> %s (first: %s)", ggml_backend_buft_name(*p), name.c_str());
            }
            return *p;
        }
    }
    return nullptr;
}

'''


def main() -> None:
    root = Path(sys.argv[1])
    mm = root / "src" / "model_manager.cpp"
    if "sd_cpu_extra_buft_for" in mm.read_text():
        print("patch_sdcpp: уже применён")
        return
    patch(mm, '#include <algorithm>\n', '#include <cstdlib>\n#include <cstring>\n#include <map>\n#include <string>\n', after=False)
    patch(mm, '    params.mem_size   = ggml_tensor_overhead() * 2;\n',
          '    params.mem_size   = ggml_tensor_overhead() * 4;\n', replace=True)
    patch(mm, '''    } else if (op == GGML_OP_CUSTOM) {
        op_tensor         = ggml_new_tensor_1d(ctx, GGML_TYPE_F32, 1);''',
          '''    } else if (op == GGML_OP_MUL_MAT && weight->ne[2] == 1 && weight->ne[3] == 1) {
        ggml_tensor* x = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, weight->ne[0], 64);
        op_tensor      = ggml_mul_mat(ctx, weight, x);
''', after=False)
    patch(mm, 'ModelManager::~ModelManager() {\n', HELPER, after=False)
    patch(mm, '''bool ModelManager::can_mmap_storage(const TensorState& state) const {
''', '''    if (sd_cpu_extra_buft_for(state.compute_backend, state.params_backend, state.tensor, state.usage_op, state.name) != nullptr) {
        return false;  // fold2: веса для extra buffer (repack/DSP) грузятся через set_tensor, не mmap
    }
''')
    patch(mm, '''ggml_backend_buffer_type_t ModelManager::params_buffer_type_for(const TensorState& state) const {
    if (state.params_backend == nullptr) {
        LOG_ERROR("model manager params backend is null for tensor '%s'", state.name.c_str());
        return nullptr;
    }
''', '''    if (ggml_backend_buffer_type_t extra =
            sd_cpu_extra_buft_for(state.compute_backend, state.params_backend, state.tensor, state.usage_op, state.name)) {
        return extra;
    }
''')
    print("patch_sdcpp: OK")


if __name__ == "__main__":
    main()
