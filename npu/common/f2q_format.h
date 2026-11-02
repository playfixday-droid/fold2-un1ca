// f2q_format.h - общий для ARM (llama.cpp) и cDSP формат данных f2qdsp.
//
// Веса: матрица M x K (K % 32 == 0) режется на плитки по 32 строки (последняя дополняется нулями).
// Плитка:
//   float   R[32]                          - масштаб строки = max|d| по блокам строки
//   для каждой пары блоков p (блок = 32 элемента по K):
//     int32 S[32]                          - слово строки i: (m[2p] << 16) | (uint16) m[2p+1],
//                                            m = round(d_блока / R * 32767), int16
//     веса блока 2p, затем блока 2p+1 (если есть):
//       Q8: 8 векторов по 128 байт, вектор s: байт 4*i+j = q[i][4s+j] + 128   (uint8)
//       Q4: 4 вектора по 128 байт, вектор v: байт 4*i+j = u[i][8v+j] | u[i][8v+4+j] << 4,
//           u = q + 8 (0..15) - младшие полубайты дают шаг 2v, старшие - шаг 2v+1
// Активации: n строк по xstride байт (кратно 128):
//   int8  q[K]           - как q8_0 в ggml (d = amax/127, q = round(x/d))
//   int32 mx[nb]         - (m << 16) | (L << 8) | r - блок с плавающей точкой (v2):
//                          m = 16384..32767 (0 - блок не нужен): d_блока / T = m * 2^-e / 32767, e = 0..30,
//                          L - сдвиг влево до умножений (для Q8, у Q4 +4): |acc << L| <= 2^30,
//                          r - сдвиг вправо после: L - r = P - e, P - общий сдвиг строки
//   float S              - T * F2Q_C * 2^-P для Q8 (у Q4 - S/16), T = max d по блокам строки
//   int16 sx[nb]         - сумма q по блоку
// P подбирается для каждой строки по сумме |q| блоков: sum_b |acc_b| * 2^(P - e_b) <= 2^29 (без переполнения int32).
// Так у каждого блока 15 бит масштаба и почти 30 бит произведения, даже если в строке есть «массивная активация» в
// 1000+ раз больше остальных (в v1 масштаб блока был от T с общим P на матрицу: 1-3% ошибки на остальных каналах).
// Результат: y[t][r] = R[r] * S * sum_b rsh(mulhi(mulhi((acc_b - off*sx_b) << L_b, m_b), m'_b), r'_b),
//   m_b - масштаб блока весов, m'_b, L_b, r'_b - из mx[b],
//   acc_b = sum_j w_b[j] * q_b[j] (w - uint8 как выше), off = 128 (Q8) или 8 (Q4),
//   mulhi(a, h) = sat32((2*a*h + 0x8000) >> 16) - это HVX vmpyo(Vw,Vh):<<1:rnd:sat и NEON vqrdmulh(a, h<<16),
//   rsh(v, r) = (v + (2^r >> 1)) >> r - HVX vadd + vasr, NEON vrshl(v, -r) (|v| < 2^30 - без переполнения).
#pragma once
#include <stdint.h>

#define F2Q_VERSION   2
#define F2Q_TILE      32
#define F2Q_QK        32
#define F2Q_VEC       128
#define F2Q_W_Q8      0
#define F2Q_W_Q4      1
#define F2Q_C         1.0000610370189520f /* 2^30 / 32767^2 */

static inline int f2q_nb(int k) { return k / F2Q_QK; }
static inline int f2q_wvecs(int wtype) { return wtype == F2Q_W_Q4 ? 4 : 8; }
static inline int f2q_off(int wtype) { return wtype == F2Q_W_Q4 ? 8 : 128; }
static inline uint32_t f2q_tile_bytes(int wtype, int k) {
    const int nb = f2q_nb(k);
    return (uint32_t) (F2Q_VEC + ((nb + 1) / 2) * F2Q_VEC + nb * f2q_wvecs(wtype) * F2Q_VEC);
}
static inline uint32_t f2q_x_stride(int k) {
    const int nb = f2q_nb(k);
    return (uint32_t) ((k + 6 * nb + 4 + F2Q_VEC - 1) / F2Q_VEC * F2Q_VEC);
}
// смещения внутри строки активаций
static inline int f2q_x_mx(int k) { return k; }
static inline int f2q_x_t(int k) { return k + 4 * f2q_nb(k); }
static inline int f2q_x_sx(int k) { return k + 4 * f2q_nb(k) + 4; }

// поля mx[b] и множитель строки (f2q_format.h, «Активации»)
static inline int16_t f2q_mx_m(int32_t mx) { return (int16_t) ((uint32_t) mx >> 16); }
static inline int f2q_mx_l(int32_t mx, int wtype) { return ((mx >> 8) & 31) + (wtype == F2Q_W_Q4 ? 4 : 0); }
static inline int f2q_mx_r(int32_t mx) { return mx & 31; }
static inline float f2q_row_scale(const uint8_t * xr, int k, int wtype) {
    const float s = *(const float *) (xr + f2q_x_t(k));
    return wtype == F2Q_W_Q4 ? s * 0.0625f : s;
}
static inline int32_t f2q_mulhi(int32_t a, int32_t h) {
    int64_t r = ((int64_t) a * h * 2 + 0x8000) >> 16;
    if (r > INT32_MAX) r = INT32_MAX;
    if (r < INT32_MIN) r = INT32_MIN;
    return (int32_t) r;
}
static inline int32_t f2q_rsh(int32_t v, int r) { return (int32_t) (((int64_t) v + ((int64_t) 1 << r >> 1)) >> r); }
