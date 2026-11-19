// Software-scaled block-format GEMMs across LLM shapes, from decode (small M) to prefill.
// Same three variants as mxgemm.cu (INT8 / MXINT8 / MX9, see there), generalized
// (mxgemm2.cu plus deep K stages for small M and a measured bandwidth roofline):
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
constexpr int BK = 32, THREADS = 256;  // BK: MX block (32 elements)

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

template <int N> __device__ __forceinline__ void cp_wait() { asm volatile("cp.async.wait_group %0;" :: "n"(N)); }

// KB: K bytes per pipeline stage (multiple of the 32-element MX block); STAGES: cp.async depth.
template <int MODE, int WM, int WN, int MT, int NT, int KB, int STAGES>
__global__ void __launch_bounds__(THREADS)
gemm(const int8_t* __restrict__ A, const int8_t* __restrict__ B,
     const int8_t* __restrict__ EA, const int8_t* __restrict__ EB,
     const uint8_t* __restrict__ UA, const uint8_t* __restrict__ UB,
     float* __restrict__ C, int M, int N, int K) {
    static_assert(WM * WN * 32 == THREADS, "8 warps");
    static_assert(KB % BK == 0 && STAGES >= 2, "stage shape");
    constexpr int BM = WM * MT * 16, BN = WN * NT * 8;
    constexpr int SUB = MODE == MX9 ? 2 : 1;           // scale sub-blocks per 32 elements
    constexpr int NS = SUB * KB / BK;                  // scales per row per stage
    constexpr int LDK = KB + 16;                       // padded row: conflict-free fragments
    constexpr int CPR = KB / 16;                       // 16-byte chunks per row
    constexpr int CHUNKS = (BM + BN) * CPR;
    __shared__ __align__(16) int8_t sA[STAGES][BM * LDK];
    __shared__ __align__(16) int8_t sB[STAGES][BN * LDK];
    __shared__ float fA[STAGES][BM][NS];
    __shared__ float fB[STAGES][BN][NS];
    const int tid = threadIdx.x, warp = tid >> 5, lane = tid & 31, g = lane >> 2, t = lane & 3;
    const int wm = (warp / WN) * MT * 16, wn = (warp % WN) * NT * 8;
    const int bm = blockIdx.y * BM, bn = blockIdx.x * BN;
    const int ksplit = K / gridDim.z, k0 = blockIdx.z * ksplit;
    const int nk = ksplit / KB, eStride = K / (BK / SUB);

    int accI[MT][NT][4];
    float accF[MT][NT][4];
#pragma unroll
    for (int i = 0; i < MT; i++)
#pragma unroll
        for (int j = 0; j < NT; j++)
#pragma unroll
            for (int k = 0; k < 4; k++) { accI[i][j][k] = 0; accF[i][j][k] = 0.f; }

    // Chunk c -> (A or B, row, column) of the stage tile.
    auto chunk = [&](int c, int& row, int& col, bool& isA) {
        isA = c < BM * CPR;
        const int cc = isA ? c : c - BM * CPR;
        row = cc / CPR;
        col = (cc % CPR) * 16;
    };
    auto load = [&](int stage, int kt) {
        for (int c = tid; c < CHUNKS; c += THREADS) {
            int row, col; bool isA;
            chunk(c, row, col, isA);
            int8_t* s = (isA ? sA[stage] : sB[stage]) + row * LDK + col;
            const int8_t* gp = (isA ? A + static_cast<size_t>(bm + row) * K
                                    : B + static_cast<size_t>(bn + row) * K) + k0 + kt * KB + col;
            cp_async16(s, gp);
        }
        if (MODE != INT8) {
            const int e0 = (k0 + kt * KB) / (BK / SUB);
            for (int r = tid; r < BM + BN; r += THREADS) {
                const bool isA = r < BM;
                const int rr = isA ? r : r - BM;
                const int8_t* E = (isA ? EA + static_cast<size_t>(bm + rr) * eStride
                                       : EB + static_cast<size_t>(bn + rr) * eStride) + e0;
                float* f = isA ? fA[stage][rr] : fB[stage][rr];
#pragma unroll
                for (int s = 0; s < NS; s++) f[s] = exp2i(E[s]);
            }
        }
    };

#pragma unroll
    for (int s = 0; s < STAGES - 1; s++) {
        if (s < nk) load(s, s);
        cp_commit();
    }
    for (int kt = 0; kt < nk; kt++) {
        const int s = kt % STAGES;
        cp_wait<STAGES - 2>();          // this thread's copies for stage kt are complete
        if (MODE == MX9) {
            for (int c = tid; c < CHUNKS; c += THREADS) {
                int row, col; bool isA;
                chunk(c, row, col, isA);
                const uint8_t* U = isA ? UA + static_cast<size_t>(bm + row) * eStride
                                       : UB + static_cast<size_t>(bn + row) * eStride;
                flatten16((isA ? sA[s] : sB[s]) + row * LDK + col, U[(k0 + kt * KB + col) / 16]);
            }
        }
        __syncthreads();
        if (kt + STAGES - 1 < nk) load((kt + STAGES - 1) % STAGES, kt + STAGES - 1);
        cp_commit();
        const int8_t* a_s = sA[s];
        const int8_t* b_s = sB[s];
#pragma unroll
        for (int kk = 0; kk < KB / BK; kk++)
#pragma unroll
        for (int h = 0; h < SUB; h++) {
            const int off = kk * BK + (MODE == MX9 ? h * 16 : 0);
            uint32_t a[MT][4], b[NT][2];
#pragma unroll
            for (int mi = 0; mi < MT; mi++) {
                const int r0 = (wm + mi * 16 + g) * LDK, r1 = r0 + 8 * LDK;
                a[mi][0] = *reinterpret_cast<const uint32_t*>(a_s + r0 + off + t * 4);
                a[mi][1] = *reinterpret_cast<const uint32_t*>(a_s + r1 + off + t * 4);
                if (MODE != MX9) {
                    a[mi][2] = *reinterpret_cast<const uint32_t*>(a_s + r0 + off + 16 + t * 4);
                    a[mi][3] = *reinterpret_cast<const uint32_t*>(a_s + r1 + off + 16 + t * 4);
                }
            }
#pragma unroll
            for (int ni = 0; ni < NT; ni++) {
                const int c0 = (wn + ni * 8 + g) * LDK;
                b[ni][0] = *reinterpret_cast<const uint32_t*>(b_s + c0 + off + t * 4);
                if (MODE != MX9) b[ni][1] = *reinterpret_cast<const uint32_t*>(b_s + c0 + off + 16 + t * 4);
            }
            if (MODE == INT8) {
#pragma unroll
                for (int mi = 0; mi < MT; mi++)
#pragma unroll
                    for (int ni = 0; ni < NT; ni++) mma_k32(accI[mi][ni], a[mi], b[ni]);
            } else {
                const int si = kk * SUB + h;
                float fa[MT][2], fb[NT][2];
#pragma unroll
                for (int mi = 0; mi < MT; mi++) {
                    fa[mi][0] = fA[s][wm + mi * 16 + g][si];
                    fa[mi][1] = fA[s][wm + mi * 16 + g + 8][si];
                }
#pragma unroll
                for (int ni = 0; ni < NT; ni++) {
                    fb[ni][0] = fB[s][wn + ni * 8 + t * 2][si];
                    fb[ni][1] = fB[s][wn + ni * 8 + t * 2 + 1][si];
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

// Streaming-read bandwidth: the achievable decode roofline (no performance counters).
__global__ void read_bw(const uint4* __restrict__ p, size_t n, unsigned* out) {
    unsigned acc = 0;
    for (size_t i = blockIdx.x * static_cast<size_t>(blockDim.x) + threadIdx.x; i < n;
         i += static_cast<size_t>(gridDim.x) * blockDim.x) {
        const uint4 v = __ldcs(p + i);
        acc ^= v.x ^ v.y ^ v.z ^ v.w;
    }
    if (acc == 0x12345678u) out[0] = acc;  // keeps the loads live
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

struct Config { int bm, bn, kb, splits; };
static int g_sms = 132;
static bool g_legacy = false;  // --legacy: the job-4865978 configuration (KB 32, 2 stages)
// Small M: one row of 8 warps along N with deep K stages; split K until ~4 CTAs per SM.
static Config choose(int M, int N, int K) {
    Config c{M >= 128 ? 128 : (M >= 64 ? 64 : (M >= 32 ? 32 : 16)), M >= 128 ? 128 : 64, 32, 1};
    if (!g_legacy && c.bm < 128) c.kb = c.bm == 16 ? 128 : 64;
    const int ctas = (N / c.bn) * (M / c.bm);
    while (ctas * c.splits < 4 * g_sms && (K / c.kb) % (c.splits * 2) == 0 && K / (c.splits * 2) >= 4 * c.kb)
        c.splits *= 2;
    return c;
}
template <int MODE, int WM, int WN, int MT, int NT, int KB, int STAGES>
static void run_cfg(const Device& d, int M, int N, int K, int splits) {
    constexpr int BM = WM * MT * 16, BN = WN * NT * 8;
    dim3 grid(N / BN, M / BM, splits);
    if (splits > 1) CHECK(cudaMemsetAsync(d.C, 0, static_cast<size_t>(M) * N * sizeof(float)));
    gemm<MODE, WM, WN, MT, NT, KB, STAGES><<<grid, THREADS>>>(d.A, d.B, d.EA, d.EB, d.UA, d.UB, d.C, M, N, K);
}
template <int MODE>
static void launch_mode(const Device& d, int M, int N, int K, const Config& c) {
    if (c.bm == 128) run_cfg<MODE, 2, 4, 4, 4, 32, 2>(d, M, N, K, c.splits);
    else if (c.kb == 32) {
        if (c.bm == 64) run_cfg<MODE, 1, 8, 4, 1, 32, 2>(d, M, N, K, c.splits);
        else if (c.bm == 32) run_cfg<MODE, 1, 8, 2, 1, 32, 2>(d, M, N, K, c.splits);
        else run_cfg<MODE, 1, 8, 1, 1, 32, 2>(d, M, N, K, c.splits);
    } else {
        if (c.bm == 64) run_cfg<MODE, 1, 8, 4, 1, 64, 3>(d, M, N, K, c.splits);
        else if (c.bm == 32) run_cfg<MODE, 1, 8, 2, 1, 64, 4>(d, M, N, K, c.splits);
        else run_cfg<MODE, 1, 8, 1, 1, 128, 3>(d, M, N, K, c.splits);
    }
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
    printf("verify %-6s M=%-4d N=%-4d K=%-4d tile %dx%dx%d split %d  err/sum|terms| %.3g (bound %.2g) %s\n",
           kModeName[mode], M, N, K, c.bm, c.bn, c.kb, c.splits, worst, bound, ok ? "OK" : "FAIL");
    return ok;
}

int main(int argc, char** argv) {
    int reps = 50;
    bool quick = false, small_only = false;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--reps") && i + 1 < argc) reps = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--quick")) quick = true;
        else if (!strcmp(argv[i], "--legacy")) g_legacy = true;
        else if (!strcmp(argv[i], "--small-only")) small_only = true;
    }
    cudaDeviceProp prop;
    CHECK(cudaGetDeviceProperties(&prop, 0));
    g_sms = prop.multiProcessorCount;
    int memClockKHz = 0, busWidth = 0;
    CHECK(cudaDeviceGetAttribute(&memClockKHz, cudaDevAttrMemoryClockRate, 0));
    CHECK(cudaDeviceGetAttribute(&busWidth, cudaDevAttrGlobalMemoryBusWidth, 0));
    const double peakGBs = 2.0 * memClockKHz * 1e3 * (busWidth / 8) / 1e9;
    (void)peakGBs;  // the driver's HBM3 clock attribute underestimates; measure instead
    double bwGBs = 0;
    {
        const size_t bytes = size_t(4) << 30;
        uint4* buf; unsigned* out;
        CHECK(cudaMalloc(&buf, bytes));
        CHECK(cudaMalloc(&out, sizeof(unsigned)));
        CHECK(cudaMemset(buf, 1, bytes));
        cudaEvent_t a, b; CHECK(cudaEventCreate(&a)); CHECK(cudaEventCreate(&b));
        read_bw<<<g_sms * 8, 512>>>(buf, bytes / 16, out);
        CHECK(cudaEventRecord(a));
        for (int r = 0; r < 10; r++) read_bw<<<g_sms * 8, 512>>>(buf, bytes / 16, out);
        CHECK(cudaEventRecord(b));
        CHECK(cudaEventSynchronize(b));
        float ms; CHECK(cudaEventElapsedTime(&ms, a, b));
        bwGBs = 10.0 * bytes / (ms * 1e-3) / 1e9;
        CHECK(cudaFree(buf)); CHECK(cudaFree(out));
    }
    const double refGBs = bwGBs;
    printf("# %s, %d SMs, measured streaming-read bandwidth %.0f GB/s (4 GiB, spec 3350), reps %d, %s\n",
           prop.name, g_sms, bwGBs, reps, g_legacy ? "legacy KB32x2" : "deep-K decode tiles");
    bool ok = true;
    for (int m = 0; m < 3; m++) {
        ok &= verify(m, 16, 128, 2048);   // small tile + split-K
        ok &= verify(m, 32, 128, 1024);
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
    if (small_only) Ms = {16, 32, 64};
    cudaEvent_t start, stop;
    CHECK(cudaEventCreate(&start));
    CHECK(cudaEventCreate(&stop));
    printf("%-8s %5s %-6s %8s %5s %10s %8s %10s %7s %8s\n", "layer", "M", "mode", "tile", "split",
           "us", "TOPS", "B GB/s", "%meas", "vs INT8");
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
                       2.0 * M * sh.N * sh.K / (us * 1e-6) / 1e12, gbs, 100 * gbs / refGBs, us / base);
                release(d);
            }
        }
    return 0;
}
