// ggml-f2qdsp.cpp - интеграция f2qdsp в CPU-бэкенд llama.cpp (как repack/AMX: "extra buffer type").
//  * веса MUL_MAT (Q4_0/Q8_0, 2D) при загрузке перепаковываются в плитки f2q и кладутся в rpcmem (видна DSP);
//  * при умножении активации квантуются в Q8 (все потоки), затем первые td плиток считает DSP (поток 0
//    делает один вызов FastRPC), остальные - потоки CPU (NEON dotprod), результат бит в бит одинаковый;
//  * доля DSP подбирается сама по замерам (отдельно для n <= 4 - генерация и n > 4 - промпт).
// Переменные: F2QDSP=1|cpu, F2QDSP_SPLIT=0..1 (фиксированная доля DSP), F2QDSP_MAX_MB (лимит весов на DSP),
//             F2QDSP_THREADS (потоки на DSP), F2QDSP_SAFE=1, F2QDSP_DEBUG=1.
#include "ggml-f2qdsp.h"

#include "ggml-backend-impl.h"
#include "ggml-cpu-impl.h"
#include "ggml-cpu.h"
#include "ggml-impl.h"
#include "traits.h"

#include "../ap/f2q_cpu.h"
#include "../ap/f2q_dev.h"
#include "../common/f2q_format.h"
#include "../common/f2q_pack.h"

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace {

bool f2q_eligible(const ggml_tensor * t) {
    return (t->type == GGML_TYPE_Q4_0 || t->type == GGML_TYPE_Q8_0) && t->ne[0] > 0 && t->ne[0] % 32 == 0 &&
           t->ne[1] > 0 && t->ne[2] == 1 && t->ne[3] == 1 && t->ne[0] <= F2Q_K_MAX && t->ne[1] <= (int64_t) F2Q_TILES_MAX * F2Q_TILE;
}
int    f2q_wtype(const ggml_tensor * t) { return t->type == GGML_TYPE_Q4_0 ? F2Q_W_Q4 : F2Q_W_Q8; }
int    f2q_tiles(const ggml_tensor * t) { return (int) ((t->ne[1] + F2Q_TILE - 1) / F2Q_TILE); }
size_t f2q_bytes(const ggml_tensor * t) { return (size_t) f2q_tiles(t) * f2q_tile_bytes(f2q_wtype(t), (int) t->ne[0]); }

float env_f(const char * n, float def) {
    const char * e = getenv(n);
    return e && *e ? (float) atof(e) : def;
}

struct f2q_hdr { // в начале wdata, общий для потоков одной операции
    std::atomic<int>     next;
    std::atomic<int64_t> cpu_done;
    uint8_t *            x;
    float *              y;
    int                  td;
};
constexpr size_t F2Q_HDR = 256;

class f2q_traits : public ggml::cpu::tensor_traits {
  public:
    explicit f2q_traits(int wt) : wtype(wt) {
        const float s = env_f("F2QDSP_SPLIT", -1.0f);
        fixed         = s >= 0.0f;
        for (int c = 0; c < 2; c++) {
            split[c] = fixed ? std::min(s, 1.0f) : 0.3f;
            calls[c] = 0;
        }
    }
    int                wtype;
    int                shared = 0; // веса в памяти, видимой DSP
    bool               fixed  = false;
    std::atomic<float> split[2];
    std::atomic<int>   calls[2];

    bool work_size(int n_threads, const ggml_tensor * op, size_t & size) override {
        const ggml_tensor * s1 = op->src[1];
        const size_t        n  = (size_t) (s1->ne[1] * s1->ne[2] * s1->ne[3]);
        size                   = F2Q_HDR + 128 + n * f2q_x_stride((int) op->src[0]->ne[0]);
        GGML_UNUSED(n_threads);
        return true;
    }

    bool compute_forward(ggml_compute_params * params, ggml_tensor * op) override;
};

bool f2q_traits::compute_forward(ggml_compute_params * params, ggml_tensor * op) {
    if (op->op != GGML_OP_MUL_MAT) {
        return false;
    }
    const ggml_tensor * src0 = op->src[0];
    const ggml_tensor * src1 = op->src[1];
    const int           K = (int) src0->ne[0], M = (int) src0->ne[1], tiles = f2q_tiles(src0);
    const int64_t       ne11 = src1->ne[1], ne12 = src1->ne[2], ne13 = src1->ne[3];
    const int           N  = (int) (ne11 * ne12 * ne13);
    const int           xs = (int) f2q_x_stride(K);
    const int           ith = params->ith, nth = params->nth;
    const uint8_t *     w   = (const uint8_t *) src0->data;
    const size_t        wb  = f2q_bytes(src0);
    float *             dst = (float *) op->data;
    const int           ys  = M;
    GGML_ASSERT(src1->type == GGML_TYPE_F32 && src1->ne[0] == K);
    GGML_ASSERT(op->nb[1] == (size_t) M * sizeof(float) && op->nb[2] == op->nb[1] * op->ne[1] && op->nb[3] == op->nb[2] * op->ne[2]);

    f2q_hdr * h   = (f2q_hdr *) GGML_PAD((uintptr_t) params->wdata, 64);
    uint8_t * xw  = (uint8_t *) h + F2Q_HDR;
    const int cls = N <= 4 ? 0 : 1;

    if (ith == 0) {
        new (h) f2q_hdr();
        h->next     = 0;
        h->cpu_done = 0;
        h->x        = xw;
        h->y        = nullptr;
        h->td       = 0;
        if (shared) {
            float     s = split[cls].load();
            const int c = calls[cls].fetch_add(1);
            if (!fixed && s < 0.05f) {
                s = (c % 64 == 0) ? 0.15f : 0.0f; // DSP проигрывает - иногда перепроверяем
            }
            const int td = std::min(tiles, (int) (tiles * s + 0.5f));
            uint8_t * dx;
            float *   dy;
            if (td > 0 && f2q_dev_begin((size_t) N * xs, (size_t) N * td * F2Q_TILE * sizeof(float), &dx, &dy)) {
                h->x  = dx;
                h->y  = dy;
                h->td = td;
            }
        }
    }
    ggml_barrier(params->threadpool);

    uint8_t * x = h->x;
    for (int t = ith; t < N; t += nth) { // квантование активаций (q8_0 как в ggml + масштабы f2q)
        const int64_t i1 = t % ne11, i2 = (t / ne11) % ne12, i3 = t / (ne11 * ne12);
        const float * row = (const float *) ((const char *) src1->data + i1 * src1->nb[1] + i2 * src1->nb[2] + i3 * src1->nb[3]);
        f2q_quant_x(row, K, x + (size_t) t * xs);
    }
    ggml_barrier(params->threadpool);

    const int td    = h->td;
    const int rest  = tiles - td;
    const int chunk = std::max(1, std::min(16, rest / std::max(1, nth * 4)));
    auto      cpu   = [&]() {
        for (;;) {
            const int a = td + h->next.fetch_add(1) * chunk;
            if (a >= tiles) {
                int64_t z = 0;
                h->cpu_done.compare_exchange_strong(z, f2q_dev_time_us());
                break;
            }
            f2q_cpu_tiles(w, wtype, K, a, std::min(a + chunk, tiles), x, N, xs, dst, ys, M);
        }
    };

    if (ith == 0 && td > 0) {
        const int64_t t0 = f2q_dev_time_us();
        const int     rc = f2q_dev_mm(w, wb, wtype, K, td, x, N, xs, h->y, td * F2Q_TILE);
        const int64_t t1 = f2q_dev_time_us();
        if (rc == 0) {
            const int mr = std::min(M, td * F2Q_TILE);
            for (int t = 0; t < N; t++) {
                memcpy(dst + (size_t) t * ys, h->y + (size_t) t * td * F2Q_TILE, (size_t) mr * sizeof(float));
            }
            const int64_t cd = h->cpu_done.load();
            // подстройка доли DSP: скорость DSP и CPU (плиток/мкс) за этот вызов. cd <= t0 - потоки CPU
            // закончили раньше, чем поток 0 засёк начало (его вытеснили после барьера): замер негоден, иначе
            // время CPU выходит отрицательным и доля DSP прыгает к 0.95
            if (!fixed && (cd == 0 || cd > t0)) {
                const double  r_dsp = td / (double) (t1 - t0 + 1);
                double        r_cpu;
                if (cd) {
                    r_cpu = rest / (double) (cd - t0 + 1);
                } else {
                    r_cpu = std::max(1, std::min(rest, h->next.load() * chunk)) / (double) (t1 - t0 + 1);
                }
                const float ideal = (float) (r_dsp / (r_dsp + r_cpu + 1e-12));
                const float s     = std::min(0.95f, 0.75f * split[cls].load() + 0.25f * ideal);
                split[cls]        = s;
                if (getenv("F2QDSP_DEBUG") && calls[cls].load() % 50 == 1) {
                    GGML_LOG_INFO("f2qdsp: %s M=%d K=%d n=%d dsp %d/%d плиток за %lld мкс, доля -> %.2f\n", src0->name, M, K,
                                  N, td, tiles, (long long) (t1 - t0), s);
                }
            }
        } else {
            f2q_cpu_tiles(w, wtype, K, 0, td, x, N, xs, dst, ys, M);
        }
    }
    cpu();
    if (td > 0) { // x/y лежат в общем буфере DSP - отпускаем его, когда все потоки закончили
        ggml_barrier(params->threadpool);
        if (ith == 0) {
            f2q_dev_end();
        }
    }
    return true;
}

// ---------------- буфер ----------------

struct f2q_buf_ctx {
    uint8_t *                                data = nullptr;
    size_t                                   size = 0;
    std::vector<std::unique_ptr<f2q_traits>> traits;
};

void f2q_buf_free(ggml_backend_buffer_t b) {
    auto * c = (f2q_buf_ctx *) b->context;
    f2q_dev_free(c->data);
    delete c;
}
void * f2q_buf_base(ggml_backend_buffer_t b) { return ((f2q_buf_ctx *) b->context)->data; }

ggml_status f2q_buf_init_tensor(ggml_backend_buffer_t b, ggml_tensor * t) {
    auto * c = (f2q_buf_ctx *) b->context;
    if (t->view_src == nullptr && f2q_eligible(t)) {
        auto tr    = std::make_unique<f2q_traits>(f2q_wtype(t));
        tr->shared = f2q_dev_is_shared(t->data, f2q_bytes(t));
        t->extra   = tr.get();
        c->traits.push_back(std::move(tr));
    }
    return GGML_STATUS_SUCCESS;
}

void f2q_buf_set_tensor(ggml_backend_buffer_t b, ggml_tensor * t, const void * data, size_t offset, size_t size) {
    if (!t->extra) {
        memcpy((char *) t->data + offset, data, size);
        return;
    }
    GGML_ASSERT(offset == 0 && size == ggml_nbytes(t));
    const int tiles = f2q_tiles(t), M = (int) t->ne[1], K = (int) t->ne[0], wt = f2q_wtype(t);
    uint8_t * dst   = (uint8_t *) t->data;
    const int nt    = tiles >= 64 ? (int) std::min(4u, std::max(1u, std::thread::hardware_concurrency())) : 1;
    std::vector<std::thread> th;
    for (int i = 1; i < nt; i++) {
        th.emplace_back(f2q_pack_weights, data, wt, M, K, dst, tiles * i / nt, tiles * (i + 1) / nt);
    }
    f2q_pack_weights(data, wt, M, K, dst, 0, tiles / nt);
    for (auto & x : th) {
        x.join();
    }
    if (((f2q_traits *) t->extra)->shared) {
        f2q_dev_weights_written(dst, f2q_bytes(t));
    }
    GGML_UNUSED(b);
}

void f2q_buf_get_tensor(ggml_backend_buffer_t b, const ggml_tensor * t, void * data, size_t offset, size_t size) {
    if (!t->extra) {
        memcpy(data, (const char *) t->data + offset, size);
        return;
    }
    std::vector<uint8_t> tmp(ggml_nbytes(t));
    f2q_unpack_weights((const uint8_t *) t->data, f2q_wtype(t), (int) t->ne[1], (int) t->ne[0], tmp.data());
    memcpy(data, tmp.data() + offset, size);
    GGML_UNUSED(b);
}

void f2q_buf_clear(ggml_backend_buffer_t b, uint8_t v) {
    auto * c = (f2q_buf_ctx *) b->context;
    memset(c->data, v, c->size);
}

void f2q_buf_reset(ggml_backend_buffer_t b) { ((f2q_buf_ctx *) b->context)->traits.clear(); }

const char * f2q_buft_name(ggml_backend_buffer_type_t) { return "F2QDSP"; }

ggml_backend_buffer_t f2q_buft_alloc(ggml_backend_buffer_type_t buft, size_t size) {
    auto * c = new f2q_buf_ctx();
    c->size  = size;
    c->data  = (uint8_t *) f2q_dev_alloc(size);
    if (!c->data) {
        GGML_LOG_ERROR("f2qdsp: не удалось выделить %zu байт\n", size);
        delete c;
        return nullptr;
    }
    ggml_backend_buffer_i i = {};
    i.free_buffer           = f2q_buf_free;
    i.get_base              = f2q_buf_base;
    i.init_tensor           = f2q_buf_init_tensor;
    i.set_tensor            = f2q_buf_set_tensor;
    i.get_tensor            = f2q_buf_get_tensor;
    i.clear                 = f2q_buf_clear;
    i.reset                 = f2q_buf_reset;
    return ggml_backend_buffer_init(buft, i, c, size);
}

size_t f2q_buft_align(ggml_backend_buffer_type_t) { return 128; }
size_t f2q_buft_max(ggml_backend_buffer_type_t) { return (size_t) 512 << 20; }

size_t f2q_buft_alloc_size(ggml_backend_buffer_type_t, const ggml_tensor * t) {
    return f2q_eligible(t) ? f2q_bytes(t) : ggml_nbytes(t);
}

ggml_backend_buffer_type_t f2q_buft();

class f2q_extra : public ggml::cpu::extra_buffer_type {
  public:
    f2q_extra() {
        const bool cpu = f2q_dev_env_mode() == 2;
        float      mb  = env_f("F2QDSP_MAX_MB", cpu ? 1e9f : 1024.0f);
        // окно адресов (IOVA) одной сессии FastRPC cDSP на SM8250 - 0x78000000 = 1920 МиБ (kona.dtsi,
        // qcom,iommu-dma-addr-pool); там же буферы активаций и библиотеки - больше 1536 МиБ весов не отобразить
        if (!cpu && mb > 1536.0f) {
            GGML_LOG_WARN("f2qdsp: F2QDSP_MAX_MB=%.0f больше окна адресов cDSP - беру 1536\n", mb);
            mb = 1536.0f;
        }
        budget = (size_t) (mb * 1048576.0);
    }

    bool supports_op(ggml_backend_dev_t, const ggml_tensor * op) override {
        if (op->op != GGML_OP_MUL_MAT) {
            return false;
        }
        const ggml_tensor * s0 = op->src[0];
        const ggml_tensor * s1 = op->src[1];
        if (!s0->buffer || s0->buffer->buft != f2q_buft() || !f2q_eligible(s0) || s1->type != GGML_TYPE_F32 ||
            s1->ne[0] != s0->ne[0]) {
            return false;
        }
        if (s1->buffer && !ggml_backend_buft_is_host(s1->buffer->buft)) {
            return false;
        }
        if (s0->buffer->size == 0) { // проба при загрузке модели: считаем лимит памяти DSP
            std::lock_guard<std::mutex> lk(mu);
            const std::string           key = std::string(s0->name) + "/" + std::to_string(s0->ne[0]) + "x" + std::to_string(s0->ne[1]);
            if (seen.count(key)) {
                return true;
            }
            const size_t sz = f2q_bytes(s0);
            if (used + sz > budget) {
                if (!warned) {
                    GGML_LOG_WARN("f2qdsp: лимит F2QDSP_MAX_MB исчерпан - остальные веса на обычном CPU\n");
                    warned = true;
                }
                return false;
            }
            used += sz;
            seen.insert(key);
        }
        return true;
    }

    ggml::cpu::tensor_traits * get_tensor_traits(const ggml_tensor * op) override {
        if (op->op == GGML_OP_MUL_MAT && op->src[0]->buffer && op->src[0]->buffer->buft == f2q_buft()) {
            return (ggml::cpu::tensor_traits *) op->src[0]->extra;
        }
        return nullptr;
    }

  private:
    std::mutex            mu;
    std::set<std::string> seen;
    size_t                used   = 0;
    size_t                budget = 0;
    bool                  warned = false;
};

ggml_backend_buffer_type_t f2q_buft() {
    static ggml_backend_buffer_type b = [] {
        ggml_backend_buffer_type t = {};
        t.iface.get_name           = f2q_buft_name;
        t.iface.alloc_buffer       = f2q_buft_alloc;
        t.iface.get_alignment      = f2q_buft_align;
        t.iface.get_max_size       = f2q_buft_max;
        t.iface.get_alloc_size     = f2q_buft_alloc_size;
        t.device                   = ggml_backend_reg_dev_get(ggml_backend_cpu_reg(), 0);
        t.context                  = new f2q_extra();
        return t;
    }();
    return &b;
}

} // namespace

ggml_backend_buffer_type_t ggml_backend_cpu_f2qdsp_buffer_type(void) {
    static ggml_backend_buffer_type_t r = []() -> ggml_backend_buffer_type_t {
        const int mode = f2q_dev_env_mode();
        if (mode == 0) {
            return nullptr;
        }
        if (mode == 1 && !f2q_dev_init()) {
            GGML_LOG_WARN("f2qdsp: DSP недоступен, работаем без него: %s\n", f2q_dev_status());
            return nullptr;
        }
        f2q_dev_init();
        GGML_LOG_INFO("f2qdsp: %s\n", f2q_dev_status());
        return f2q_buft();
    }();
    return r;
}
