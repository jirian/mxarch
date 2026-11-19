// Software-scaled block-format GEMMs across LLM shapes, from decode (small M) to prefill.
// Same three variants as mxgemm.cu (INT8 / MXINT8 / MX9, see there), generalized:
//   * CTA tile = WM x WN warps, each MT x NT mma tiles (m16 x n8); 8 warps, 256 threads.
//     Large M: 128x128 (2x4 warps, 4x4 tiles). Small M: {16,32,64}x64 (1x8 warps, MTx1).
//   * split-K over gridDim.z (float atomics) so skinny GEMMs keep every SM streaming B.
// A (activations) is M x K, B (weights) is N x K, both K-contiguous; C is M x N float.
#include <cuda_runtime.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <cstring>
#include <random>
#include <vector>

#define CHECK(x) do { cudaError_t e = (x); if (e != cudaSuccess) { \
    fprintf(stderr, "CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); exit(1); } } while (0)

enum Mode { INT8 = 0, MXINT8 = 1, MX9 = 2 };
static const char* kModeName[] = {"INT8", "MXINT8", "MX9"};
constexpr int BK = 32, LDS = 48, THREADS = 256;

__device__ __forceinline__ void cp_async16(void* smem, const void* gmem) {
    unsigned s = static_cast<unsigned>(__cvta_generic_to_shared(smem));
    asm volatile("cp.async.cg.shared.global [%0], [%1], 16;" :: "r"(s), "l"(gmem));
}
__device__ __forceinline__ void cp_commit() { asm volatile("cp.async.commit_group;"); }
__device__ __forceinline__ void cp_wait_all() { asm volatile("cp.async.wait_group 0;"); }
__device__ __forceinline__ void mma_k32(int c[4], const uint32_t a[4], const uint32_t b[2]) {
    asm volatile("mma.sync.aligned.m16n8k32.row.col.s32.s8.s8.s32 "
                 "{%0,%1,%2,%3}, {%4,%5,%6,%7}, {%8,%9}, {%0,%1,%2,%3};"
                 : "+r"(c[0]), "+r"(c[1]), "+r"(c[2]), "+r"(c[3])
                 : "r"(a[0]), "r"(a[1]), "r"(a[2]), "r"(a[3]), "r"(b[0]), "r"(b[1]));
}
__device__ __forceinline__ void mma_k16(int c[4], uint32_t a0, uint32_t a1, uint32_t b0) {
    asm volatile("mma.sync.aligned.m16n8k16.row.col.s32.s8.s8.s32 "
                 "{%0,%1,%2,%3}, {%4,%5}, {%6}, {%0,%1,%2,%3};"
                 : "+r"(c[0]), "+r"(c[1]), "+r"(c[2]), "+r"(c[3])
                 : "r"(a0), "r"(a1), "r"(b0));
}
__device__ __forceinline__ float exp2i(int e) { return __int_as_float((e + 127) << 23); }
__device__ __forceinline__ uint32_t halve_masked(uint32_t x, uint32_t m) {
    uint32_t sh = ((x >> 1) & 0x7F7F7F7Fu) | (x & 0x80808080u);
    return (sh & m) | (x & ~m);
}
__device__ __forceinline__ void flatten16(int8_t* p, uint32_t u) {
    uint4 v = *reinterpret_cast<uint4*>(p);
    uint32_t r[4] = {v.x, v.y, v.z, v.w};
#pragma unroll
    for (int i = 0; i < 4; i++) {
        uint32_t m = ((u >> (2 * i)) & 1u ? 0x0000FFFFu : 0u) | ((u >> (2 * i + 1)) & 1u ? 0xFFFF0000u : 0u);
        r[i] = halve_masked(r[i], m);
    }
    *reinterpret_cast<uint4*>(p) = make_uint4(r[0], r[1], r[2], r[3]);
}

template <int MODE, int WM, int WN, int MT, int NT>
__global__ void __launch_bounds__(THREADS)
gemm(const int8_t* __restrict__ A, const int8_t* __restrict__ B,
     const int8_t* __restrict__ EA, const int8_t* __restrict__ EB,
     const uint8_t* __restrict__ UA, const uint8_t* __restrict__ UB,
     float* __restrict__ C, int M, int N, int K) {
    static_assert(WM * WN * 32 == THREADS, "8 warps");
    constexpr int BM = WM * MT * 16, BN = WN * NT * 8;
    constexpr int SUB = MODE == MX9 ? 2 : 1;
    constexpr int CHUNKS = (BM + BN) * 2;               // 16-byte chunks per stage (A then B)
    __shared__ __align__(16) int8_t sA[2][BM * LDS];
    __shared__ __align__(16) int8_t sB[2][BN * LDS];
    __shared__ float fA[2][BM][SUB];
    __shared__ float fB[2][BN][SUB];
    const int tid = threadIdx.x, warp = tid >> 5, lane = tid & 31, g = lane >> 2, t = lane & 3;
    const int wm = (warp / WN) * MT * 16, wn = (warp % WN) * NT * 8;
    const int bm = blockIdx.y * BM, bn = blockIdx.x * BN;
    const int ksplit = K / gridDim.z, k0 = blockIdx.z * ksplit;
    const int nk = ksplit / BK, eStride = K / (BK / SUB);

    int accI[MT][NT][4];
    float accF[MT][NT][4];
#pragma unroll
    for (int i = 0; i < MT; i++)
#pragma unroll
        for (int j = 0; j < NT; j++)
#pragma unroll
            for (int k = 0; k < 4; k++) { accI[i][j][k] = 0; accF[i][j][k] = 0.f; }

    auto chunk_ptrs = [&](int c, int stage, int kt, int8_t*& smem, const int8_t*& gmem, int& row, bool& isA) {
        isA = c < BM * 2;
        const int cc = isA ? c : c - BM * 2;
        row = cc >> 1;
        const int col = (cc & 1) * 16;
        smem = (isA ? sA[stage] : sB[stage]) + row * LDS + col;
        gmem = (isA ? A + static_cast<size_t>(bm + row) * K : B + static_cast<size_t>(bn + row) * K)
               + k0 + kt * BK + col;
    };
    auto load = [&](int stage, int kt) {
        for (int c = tid; c < CHUNKS; c += THREADS) {
            int8_t* s; const int8_t* gp; int row; bool isA;
            chunk_ptrs(c, stage, kt, s, gp, row, isA);
            cp_async16(s, gp);
        }
        cp_commit();
        if (MODE != INT8) {
            const int kb = (k0 / BK + kt) * SUB;
            for (int r = tid; r < BM + BN; r += THREADS) {
                const bool isA = r < BM;
                const int rr = isA ? r : r - BM;
                const int8_t* E = isA ? EA + static_cast<size_t>(bm + rr) * eStride
                                      : EB + static_cast<size_t>(bn + rr) * eStride;
                float* f = isA ? fA[stage][rr] : fB[stage][rr];
#pragma unroll
                for (int s = 0; s < SUB; s++) f[s] = exp2i(E[kb + s]);
            }
        }
    };

    load(0, 0);
    for (int kt = 0; kt < nk; kt++) {
        const int s = kt & 1;
        cp_wait_all();
        if (MODE == MX9) {  // flatten the chunks this thread copied (they are complete)
            for (int c = tid; c < CHUNKS; c += THREADS) {
                int8_t* sp; const int8_t* gp; int row; bool isA;
                chunk_ptrs(c, s, kt, sp, gp, row, isA);
                const int sub = (k0 / 16) + kt * 2 + ((c & 1));
                const uint8_t* U = isA ? UA + static_cast<size_t>(bm + row) * eStride
                                       : UB + static_cast<size_t>(bn + row) * eStride;
                flatten16(sp, U[sub]);
            }
        }
        __syncthreads();
        if (kt + 1 < nk) load(s ^ 1, kt + 1);
        const int8_t* a_s = sA[s];
        const int8_t* b_s = sB[s];
#pragma unroll
        for (int h = 0; h < (MODE == MX9 ? 2 : 1); h++) {
            uint32_t a[MT][4], b[NT][2];
#pragma unroll
            for (int mi = 0; mi < MT; mi++) {
                const int r0 = (wm + mi * 16 + g) * LDS, r1 = r0 + 8 * LDS;
                const int off = MODE == MX9 ? h * 16 : 0;
                a[mi][0] = *reinterpret_cast<const uint32_t*>(a_s + r0 + off + t * 4);
                a[mi][1] = *reinterpret_cast<const uint32_t*>(a_s + r1 + off + t * 4);
                if (MODE != MX9) {
                    a[mi][2] = *reinterpret_cast<const uint32_t*>(a_s + r0 + 16 + t * 4);
                    a[mi][3] = *reinterpret_cast<const uint32_t*>(a_s + r1 + 16 + t * 4);
                }
            }
#pragma unroll
            for (int ni = 0; ni < NT; ni++) {
                const int c0 = (wn + ni * 8 + g) * LDS;
                const int off = MODE == MX9 ? h * 16 : 0;
                b[ni][0] = *reinterpret_cast<const uint32_t*>(b_s + c0 + off + t * 4);
                if (MODE != MX9) b[ni][1] = *reinterpret_cast<const uint32_t*>(b_s + c0 + 16 + t * 4);
            }
            if (MODE == INT8) {
#pragma unroll
                for (int mi = 0; mi < MT; mi++)
#pragma unroll
                    for (int ni = 0; ni < NT; ni++) mma_k32(accI[mi][ni], a[mi], b[ni]);
            } else {
                float fa[MT][2], fb[NT][2];
#pragma unroll
                for (int mi = 0; mi < MT; mi++) {
                    fa[mi][0] = fA[s][wm + mi * 16 + g][h];
                    fa[mi][1] = fA[s][wm + mi * 16 + g + 8][h];
                }
#pragma unroll
                for (int ni = 0; ni < NT; ni++) {
                    fb[ni][0] = fB[s][wn + ni * 8 + t * 2][h];
                    fb[ni][1] = fB[s][wn + ni * 8 + t * 2 + 1][h];
                }
#pragma unroll
                for (int mi = 0; mi < MT; mi++)
#pragma unroll
                    for (int ni = 0; ni < NT; ni++) {
                        int p[4] = {0, 0, 0, 0};
                        if (MODE == MX9) mma_k16(p, a[mi][0], a[mi][1], b[ni][0]);
                        else mma_k32(p, a[mi], b[ni]);
                        accF[mi][ni][0] += static_cast<float>(p[0]) * (fa[mi][0] * fb[ni][0]);
                        accF[mi][ni][1] += static_cast<float>(p[1]) * (fa[mi][0] * fb[ni][1]);
                        accF[mi][ni][2] += static_cast<float>(p[2]) * (fa[mi][1] * fb[ni][0]);
                        accF[mi][ni][3] += static_cast<float>(p[3]) * (fa[mi][1] * fb[ni][1]);
                    }
            }
        }
    }
    const bool atomic = gridDim.z > 1;
#pragma unroll
    for (int mi = 0; mi < MT; mi++)
#pragma unroll
        for (int ni = 0; ni < NT; ni++) {
            const int r = bm + wm + mi * 16 + g, c = bn + wn + ni * 8 + t * 2;
#pragma unroll
            for (int k = 0; k < 4; k++) {
                const int rr = r + (k >> 1) * 8, cc = c + (k & 1);
                const float v = MODE == INT8 ? static_cast<float>(accI[mi][ni][k]) : accF[mi][ni][k];
                float* dst = C + static_cast<size_t>(rr) * N + cc;
                if (atomic) atomicAdd(dst, v); else *dst = v;
            }
        }
}

// ---------------------------------------------------------------- host side
struct Problem {
    int M, N, K;
    std::vector<int8_t> A, B, EA, EB;
    std::vector<uint8_t> UA, UB;
};
static Problem make_problem(int M, int N, int K, int mode, unsigned seed) {
    Problem p{M, N, K};
    std::mt19937 rng(seed);
    std::uniform_int_distribution<int> elem(-127, 127), expo(-4, 4), bits(0, 255);
    p.A.resize(static_cast<size_t>(M) * K);
    p.B.resize(static_cast<size_t>(N) * K);
    for (auto& x : p.A) x = static_cast<int8_t>(elem(rng));
    for (auto& x : p.B) x = static_cast<int8_t>(elem(rng));
    const int blocks = mode == MX9 ? K / 16 : K / 32;
    p.EA.resize(static_cast<size_t>(M) * blocks);
    p.EB.resize(static_cast<size_t>(N) * blocks);
    for (auto& x : p.EA) x = static_cast<int8_t>(expo(rng));
    for (auto& x : p.EB) x = static_cast<int8_t>(expo(rng));
    p.UA.resize(p.EA.size());
    p.UB.resize(p.EB.size());
    for (auto& x : p.UA) x = static_cast<uint8_t>(bits(rng));
    for (auto& x : p.UB) x = static_cast<uint8_t>(bits(rng));
    return p;
}
static std::vector<double> reference(const Problem& p, int mode, std::vector<double>* magnitude) {
    const int bs = mode == MX9 ? 16 : 32, nb = p.K / bs;
    auto elem = [&](const std::vector<int8_t>& X, const std::vector<uint8_t>& U, int row, int k) {
        int v = X[static_cast<size_t>(row) * p.K + k];
        if (mode == MX9 && ((U[static_cast<size_t>(row) * nb + k / 16] >> ((k % 16) / 2)) & 1)) v >>= 1;
        return v;
    };
    std::vector<double> C(static_cast<size_t>(p.M) * p.N);
    magnitude->assign(C.size(), 0.0);
    for (int i = 0; i < p.M; i++)
        for (int j = 0; j < p.N; j++) {
            double acc = 0, mag = 0;
            for (int b = 0; b < nb; b++) {
                long long part = 0;
                for (int k = b * bs; k < (b + 1) * bs; k++)
                    part += static_cast<long long>(elem(p.A, p.UA, i, k)) * elem(p.B, p.UB, j, k);
                const double term = mode == INT8 ? static_cast<double>(part)
                    : std::ldexp(static_cast<double>(part),
                                 p.EA[static_cast<size_t>(i) * nb + b] + p.EB[static_cast<size_t>(j) * nb + b]);
                acc += term;
                mag += fabs(term);
            }
            C[static_cast<size_t>(i) * p.N + j] = acc;
            (*magnitude)[static_cast<size_t>(i) * p.N + j] = mag;
        }
    return C;
}

struct Device { int8_t *A, *B, *EA, *EB; uint8_t *UA, *UB; float* C; };
template <class T> static T* upload(const std::vector<T>& v) {
    T* d; CHECK(cudaMalloc(&d, v.size() * sizeof(T)));
    CHECK(cudaMemcpy(d, v.data(), v.size() * sizeof(T), cudaMemcpyHostToDevice));
    return d;
}
static Device upload(const Problem& p) {
    Device d{upload(p.A), upload(p.B), upload(p.EA), upload(p.EB), upload(p.UA), upload(p.UB), nullptr};
    CHECK(cudaMalloc(&d.C, static_cast<size_t>(p.M) * p.N * sizeof(float)));
    return d;
}
static void release(Device& d) {
    cudaFree(d.A); cudaFree(d.B); cudaFree(d.EA); cudaFree(d.EB); cudaFree(d.UA); cudaFree(d.UB); cudaFree(d.C);
}

struct Config { int bm, bn, splits; };
static int g_sms = 132;
// Small M: one row of 8 warps along N; split K until there are ~4 CTAs per SM.
static Config choose(int M, int N, int K) {
    Config c{M >= 128 ? 128 : (M >= 64 ? 64 : (M >= 32 ? 32 : 16)), M >= 128 ? 128 : 64, 1};
    const int ctas = (N / c.bn) * (M / c.bm);
    while (ctas * c.splits < 4 * g_sms && (K / BK) % (c.splits * 2) == 0 && K / (c.splits * 2) >= 4 * BK)
        c.splits *= 2;
    return c;
}
template <int MODE, int WM, int WN, int MT, int NT>
static void run_cfg(const Device& d, int M, int N, int K, int splits) {
    constexpr int BM = WM * MT * 16, BN = WN * NT * 8;
    dim3 grid(N / BN, M / BM, splits);
    if (splits > 1) CHECK(cudaMemsetAsync(d.C, 0, static_cast<size_t>(M) * N * sizeof(float)));
    gemm<MODE, WM, WN, MT, NT><<<grid, THREADS>>>(d.A, d.B, d.EA, d.EB, d.UA, d.UB, d.C, M, N, K);
}
template <int MODE>
static void launch_mode(const Device& d, int M, int N, int K, const Config& c) {
    if (c.bm == 128) run_cfg<MODE, 2, 4, 4, 4>(d, M, N, K, c.splits);
    else if (c.bm == 64) run_cfg<MODE, 1, 8, 4, 1>(d, M, N, K, c.splits);
    else if (c.bm == 32) run_cfg<MODE, 1, 8, 2, 1>(d, M, N, K, c.splits);
    else run_cfg<MODE, 1, 8, 1, 1>(d, M, N, K, c.splits);
}
static void launch(int mode, const Device& d, int M, int N, int K, const Config& c) {
    if (mode == INT8) launch_mode<INT8>(d, M, N, K, c);
    if (mode == MXINT8) launch_mode<MXINT8>(d, M, N, K, c);
    if (mode == MX9) launch_mode<MX9>(d, M, N, K, c);
    CHECK(cudaGetLastError());
}

static bool verify(int mode, int M, int N, int K) {
    Problem p = make_problem(M, N, K, mode, 7 + mode + M);
    Device d = upload(p);
    Config c = choose(M, N, K);
    launch(mode, d, M, N, K, c);
    CHECK(cudaDeviceSynchronize());
    std::vector<float> C(static_cast<size_t>(M) * N);
    CHECK(cudaMemcpy(C.data(), d.C, C.size() * sizeof(float), cudaMemcpyDeviceToHost));
    release(d);
    std::vector<double> mag;
    std::vector<double> R = reference(p, mode, &mag);
    double worst = 0;
    for (size_t i = 0; i < C.size(); i++) worst = fmax(worst, fabs(C[i] - R[i]) / fmax(1.0, mag[i]));
    // INT8 is exact without split-K; float split-K adds one rounding per partial sum.
    const double bound = (mode == INT8 && c.splits == 1) ? 0.0 : ((K / 16) + c.splits) * 1.2e-7;
    const bool ok = worst <= bound;
    printf("verify %-6s M=%-4d N=%-4d K=%-4d tile %dx%d split %d  err/sum|terms| %.3g (bound %.2g) %s\n",
           kModeName[mode], M, N, K, c.bm, c.bn, c.splits, worst, bound, ok ? "OK" : "FAIL");
    return ok;
}

int main(int argc, char** argv) {
    int reps = 50;
    bool quick = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--reps") && i + 1 < argc) reps = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--quick")) quick = true;
    }
    cudaDeviceProp prop;
    CHECK(cudaGetDeviceProperties(&prop, 0));
    g_sms = prop.multiProcessorCount;
    int memClockKHz = 0, busWidth = 0;
    CHECK(cudaDeviceGetAttribute(&memClockKHz, cudaDevAttrMemoryClockRate, 0));
    CHECK(cudaDeviceGetAttribute(&busWidth, cudaDevAttrGlobalMemoryBusWidth, 0));
    const double peakGBs = 2.0 * memClockKHz * 1e3 * (busWidth / 8) / 1e9;
    printf("# %s, %d SMs, HBM peak %.0f GB/s (from clock x bus width), reps %d\n",
           prop.name, g_sms, peakGBs, reps);
    bool ok = true;
    for (int m = 0; m < 3; m++) {
        ok &= verify(m, 16, 128, 1024);   // small tile + split-K
        ok &= verify(m, 64, 256, 512);
        ok &= verify(m, 256, 256, 512);   // large tile
    }
    if (!ok) return 1;

    struct Shape { const char* name; int N, K; };
    // Qwen3-8B linear layers (hidden 4096, 32 q heads + 8 kv heads x 128, intermediate 12288).
    std::vector<Shape> shapes = {{"qkv", 6144, 4096}, {"o", 4096, 4096},
                                 {"gate_up", 24576, 4096}, {"down", 4096, 12288}};
    std::vector<int> Ms = {16, 32, 64, 128, 256, 512, 1024, 4096};
    if (quick) { shapes.resize(1); Ms = {16, 4096}; }
    cudaEvent_t start, stop;
    CHECK(cudaEventCreate(&start));
    CHECK(cudaEventCreate(&stop));
    printf("%-8s %5s %-6s %8s %5s %10s %8s %10s %7s %8s\n", "layer", "M", "mode", "tile", "split",
           "us", "TOPS", "B GB/s", "%peak", "vs INT8");
    for (const Shape& sh : shapes)
        for (int M : Ms) {
            const Config c = choose(M, sh.N, sh.K);
            double base = 0;
            for (int m = 0; m < 3; m++) {
                Problem p = make_problem(M, sh.N, sh.K, m, 1);
                Device d = upload(p);
                for (int w = 0; w < 3; w++) launch(m, d, M, sh.N, sh.K, c);
                CHECK(cudaEventRecord(start));
                for (int r = 0; r < reps; r++) launch(m, d, M, sh.N, sh.K, c);
                CHECK(cudaEventRecord(stop));
                CHECK(cudaEventSynchronize(stop));
                float ms;
                CHECK(cudaEventElapsedTime(&ms, start, stop));
                const double us = 1e3 * ms / reps;
                if (m == INT8) base = us;
                // Weight bytes actually needed: elements + scales (+ MX9 micro bits).
                const double wbytes = static_cast<double>(sh.N) * sh.K *
                    (1.0 + (m == MXINT8 ? 1.0 / 32 : m == MX9 ? 2.0 / 16 : 0.0));
                const double gbs = wbytes / (us * 1e-6) / 1e9;
                printf("%-8s %5d %-6s %4dx%-3d %5d %10.2f %8.1f %10.0f %6.1f%% %7.3fx\n", sh.name, M,
                       kModeName[m], c.bm, c.bn, c.splits, us,
                       2.0 * M * sh.N * sh.K / (us * 1e-6) / 1e12, gbs, 100 * gbs / peakGBs, us / base);
                release(d);
            }
        }
    return 0;
}
