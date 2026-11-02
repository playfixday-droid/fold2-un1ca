// ggml_test.cpp - проверка f2qdsp внутри ggml: MUL_MAT весов в буфере "F2QDSP" против обычного CPU-буфера.
// Q4_0 и Q8_0, M x K = 200x512, 96x4096, 1000x2048, 33x32; n = 1, 3, 7, 64; каждый граф 12 раз подряд.
// n = 1 и 7 ещё и с «массивной активацией»: канал K/3 = ±2000 при нулевых весах этого канала - выход определяют
// остальные каналы, и их точность не должна теряться (в формате v1 масштаб блока был от максимума строки: ~1e-5).
// Критерий: NMSE < 1e-6 на каждом прогоне и одинаковый бит в бит результат всех 12 прогонов
// (DSP, NEON и эталон считают одинаково, поэтому подстройка доли DSP не должна менять ответ).
// Запуск: F2QDSP=1 | F2QDSP=cpu | F2QDSP=1 F2QDSP_SPLIT=0 | F2QDSP=1 F2QDSP_SPLIT=1 ./ggml_test
// Без F2QDSP проверяется, что буфер F2QDSP НЕ зарегистрирован (llama.cpp работает как обычно).
// В mock-сборке (DSP в процессе) дополнительно проверяется число вызовов mm, дошедших до "DSP".
#include "ggml-alloc.h"
#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "ggml.h"

#include "../common/f2q_format.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <vector>

extern "C" __attribute__((weak)) long f2q_mock_mm_calls(void); // есть только в mock-сборке

static std::string g_log;
static void log_cb(ggml_log_level level, const char * text, void *) {
    if (strstr(text, "f2qdsp")) {
        g_log += text;
        fputs(text, stderr);
    } else if (level >= GGML_LOG_LEVEL_WARN) {
        fputs(text, stderr);
    }
}

static ggml_backend_buffer_type_t find_f2q(ggml_backend_dev_t dev) {
    auto * reg = ggml_backend_dev_backend_reg(dev);
    auto   fn  = (ggml_backend_dev_get_extra_bufts_t) ggml_backend_reg_get_proc_address(reg, "ggml_backend_dev_get_extra_bufts");
    if (!fn) {
        return nullptr;
    }
    for (ggml_backend_buffer_type_t * b = fn(dev); b && *b; b++) {
        printf("  extra buffer type: %s\n", ggml_backend_buft_name(*b));
        if (strcmp(ggml_backend_buft_name(*b), "F2QDSP") == 0) {
            return *b;
        }
    }
    return nullptr;
}

struct mm_case {
    ggml_context *        ctx = nullptr;
    ggml_backend_buffer_t bw = nullptr, bg = nullptr;
    ggml_tensor *         w = nullptr, *x = nullptr, *y = nullptr;
    ggml_cgraph *         gf = nullptr;

    mm_case(ggml_backend_buffer_type_t wbuft, ggml_type type, int M, int K, int n) {
        // веса - в отдельном контексте (свой буфер), x/y - в обычном CPU-буфере
        ggml_init_params pw = { ggml_tensor_overhead() * 2, nullptr, true };
        ctx_w               = ggml_init(pw);
        w                   = ggml_new_tensor_2d(ctx_w, type, K, M);
        ggml_set_name(w, "w");
        bw = ggml_backend_alloc_ctx_tensors_from_buft(ctx_w, wbuft);

        ggml_init_params pg = { ggml_tensor_overhead() * 8 + ggml_graph_overhead(), nullptr, true };
        ctx                 = ggml_init(pg);
        x                   = ggml_new_tensor_2d(ctx, GGML_TYPE_F32, K, n);
        y                   = ggml_mul_mat(ctx, w, x);
        gf                  = ggml_new_graph(ctx);
        ggml_build_forward_expand(gf, y);
        bg = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_cpu_buffer_type());
    }
    ~mm_case() {
        ggml_backend_buffer_free(bg);
        ggml_backend_buffer_free(bw);
        ggml_free(ctx);
        ggml_free(ctx_w);
    }
    ggml_context * ctx_w = nullptr;
};

static double nmse(const std::vector<float> & a, const std::vector<float> & ref) {
    double e = 0, s = 0;
    for (size_t i = 0; i < a.size(); i++) {
        const double d = (double) a[i] - ref[i];
        e += d * d;
        s += (double) ref[i] * ref[i];
    }
    return s > 0 ? e / s : e;
}

int main() {
    ggml_log_set(log_cb, nullptr);
    const char * mode  = getenv("F2QDSP");
    const char * split = getenv("F2QDSP_SPLIT");
    printf("ggml_test: F2QDSP=%s F2QDSP_SPLIT=%s, mock=%s\n", mode ? mode : "(нет)", split ? split : "(нет)",
           f2q_mock_mm_calls ? "да" : "нет");

    ggml_backend_t     be  = ggml_backend_cpu_init();
    ggml_backend_dev_t dev = ggml_backend_get_device(be);
    const int          nth = getenv("THREADS") ? atoi(getenv("THREADS")) : 4;
    ggml_backend_cpu_set_n_threads(be, nth);
    ggml_backend_buffer_type_t f2q = find_f2q(dev);

    const bool on = mode && *mode && strcmp(mode, "0") != 0;
    if (!on) {
        printf(f2q ? "ОШИБКА: F2QDSP выключен, но буфер F2QDSP зарегистрирован\nИТОГ: FAIL\n"
                   : "буфер F2QDSP не зарегистрирован (так и должно быть без F2QDSP)\nИТОГ: OK\n");
        ggml_backend_free(be);
        return f2q ? 1 : 0;
    }
    if (!f2q) {
        printf("ОШИБКА: буфер F2QDSP не найден среди extra buffer types\nИТОГ: FAIL\n");
        return 1;
    }
    const bool dsp_mode = strcmp(mode, "cpu") != 0;
    if (dsp_mode && f2q_mock_mm_calls && g_log.find("selftest q4: OK") == std::string::npos) {
        printf("ОШИБКА: нет 'selftest q4: OK' в логе f2qdsp - DSP (mock) не поднялся\nИТОГ: FAIL\n");
        return 1;
    }

    const ggml_type types[2]    = { GGML_TYPE_Q4_0, GGML_TYPE_Q8_0 };
    const int       shapes[][2] = { { 200, 512 }, { 96, 4096 }, { 1000, 2048 }, { 33, 32 } };
    const int       ns[]        = { 1, 3, 7, 64 };
    const int       RUNS        = 12;
    std::mt19937    rng(1234);
    std::normal_distribution<float> nd(0.0f, 1.0f);
    int    fails = 0, cases = 0, computes = 0;
    double worst = 0;
    const long calls0 = f2q_mock_mm_calls ? f2q_mock_mm_calls() : 0;

    for (ggml_type type : types) {
        for (auto & sh : shapes) {
            const int M = sh[0], K = sh[1];
            std::vector<float> wf((size_t) M * K);
            for (auto & v : wf) v = nd(rng) * 0.05f;
            std::vector<uint8_t> wq0(ggml_row_size(type, K) * M), wqz(wq0.size());
            ggml_quantize_chunk(type, wf.data(), wq0.data(), 0, M, K, nullptr);
            for (int r = 0; r < M; r++) wf[(size_t) r * K + K / 3] = 0.0f;
            ggml_quantize_chunk(type, wf.data(), wqz.data(), 0, M, K, nullptr);
            for (int n : ns) for (int big = 0; big < 2; big++) {
                if (big && n != 1 && n != 7) continue;
                const std::vector<uint8_t> & wq = big ? wqz : wq0;
                std::vector<float> xf((size_t) K * n);
                for (auto & v : xf) v = nd(rng);
                for (int t = 0; big && t < n; t++) xf[(size_t) t * K + K / 3] = t % 2 ? -2000.0f : 2000.0f;
                mm_case ref(ggml_backend_cpu_buffer_type(), type, M, K, n);
                mm_case tst(f2q, type, M, K, n);
                if (!ref.bw || !tst.bw || !ref.bg || !tst.bg) {
                    printf("ОШИБКА: не удалось выделить буферы\n");
                    return 1;
                }
                // веса должны лечь плитками f2q (иначе буфер F2QDSP их не взял)
                const size_t want = (size_t) ((M + F2Q_TILE - 1) / F2Q_TILE) *
                                    f2q_tile_bytes(type == GGML_TYPE_Q4_0 ? F2Q_W_Q4 : F2Q_W_Q8, K);
                if (ggml_backend_buft_get_alloc_size(f2q, tst.w) != want) {
                    printf("ОШИБКА: размер весов в F2QDSP %zu, ожидалось %zu (%s %dx%d)\n",
                           ggml_backend_buft_get_alloc_size(f2q, tst.w), want, ggml_type_name(type), M, K);
                    return 1;
                }
                ggml_backend_tensor_set(ref.w, wq.data(), 0, wq.size());
                ggml_backend_tensor_set(tst.w, wq.data(), 0, wq.size());
                ggml_backend_tensor_set(ref.x, xf.data(), 0, xf.size() * sizeof(float));
                ggml_backend_tensor_set(tst.x, xf.data(), 0, xf.size() * sizeof(float));
                // get_tensor должен вернуть исходные блоки ggml (обратная перепаковка)
                std::vector<uint8_t> back(wq.size());
                ggml_backend_tensor_get(tst.w, back.data(), 0, back.size());
                const bool back_ok = memcmp(back.data(), wq.data(), wq.size()) == 0;

                if (ggml_backend_graph_compute(be, ref.gf) != GGML_STATUS_SUCCESS) {
                    printf("ОШИБКА: compute ref\n");
                    return 1;
                }
                std::vector<float> yr((size_t) M * n), y((size_t) M * n), y0;
                ggml_backend_tensor_get(ref.y, yr.data(), 0, yr.size() * sizeof(float));
                double e_max = 0;
                bool   same  = true, finite = true;
                for (int r = 0; r < RUNS; r++) {
                    std::fill(y.begin(), y.end(), NAN);
                    ggml_backend_tensor_set(tst.y, y.data(), 0, y.size() * sizeof(float));
                    if (ggml_backend_graph_compute(be, tst.gf) != GGML_STATUS_SUCCESS) {
                        printf("ОШИБКА: compute f2q\n");
                        return 1;
                    }
                    computes++;
                    ggml_backend_tensor_get(tst.y, y.data(), 0, y.size() * sizeof(float));
                    for (float v : y) finite = finite && std::isfinite(v);
                    const double e = nmse(y, yr);
                    if (!(e <= e_max)) e_max = e; // NaN тоже сюда
                    if (r == 0) y0 = y;
                    else if (memcmp(y.data(), y0.data(), y.size() * sizeof(float)) != 0) same = false;
                }
                const bool ok = finite && e_max < 1e-6 && same && back_ok;
                if (e_max > worst || std::isnan(e_max)) worst = e_max;
                cases++;
                fails += !ok;
                printf("%s %s M=%-4d K=%-4d n=%-2d%s NMSE=%.2e %s%s%s\n", ok ? "OK  " : "FAIL", ggml_type_name(type), M, K, n,
                       big ? " массивная активация" : "", e_max,
                       same ? "" : " [прогоны различаются]", back_ok ? "" : " [get_tensor != исходным блокам]",
                       finite ? "" : " [NaN/Inf]");
            }
        }
    }

    if (f2q_mock_mm_calls) {
        const long d = f2q_mock_mm_calls() - calls0;
        printf("вызовов mm на DSP (mock): %ld из %d вычислений графа\n", d, computes);
        if (!dsp_mode && d != 0) { printf("ОШИБКА: при F2QDSP=cpu DSP вызываться не должен\n"); fails++; }
        if (dsp_mode && split && atof(split) == 0.0 && d != 0) { printf("ОШИБКА: при F2QDSP_SPLIT=0 DSP вызываться не должен\n"); fails++; }
        if (dsp_mode && split && atof(split) >= 1.0 && d != computes) { printf("ОШИБКА: при F2QDSP_SPLIT=1 каждый MUL_MAT должен идти на DSP\n"); fails++; }
        if (dsp_mode && !split && d == 0) { printf("ОШИБКА: DSP ни разу не вызывался\n"); fails++; }
    }
    printf("случаев: %d, ошибок: %d, худший NMSE: %.2e\nИТОГ: %s\n", cases, fails, worst, fails ? "FAIL" : "OK");
    ggml_backend_free(be);
    return fails ? 1 : 0;
}
