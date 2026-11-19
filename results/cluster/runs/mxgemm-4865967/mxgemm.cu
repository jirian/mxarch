// Software-scaled block-format GEMMs on an unmodified GPU (the Avant-Garde baseline).
//
// One mma.sync INT8 GEMM (128x128 CTA tile, 8 warps of 64x32, cp.async double buffer),
// specialized three ways:
//   INT8    plain s8 GEMM, int32 accumulation. Lower bound: what remains if a tensor core
//           applies block scales for free (Avant-Garde's claim).
//   MXINT8  single-level, one E8M0-style exponent per 32 elements per row of A / column
//           of B. Per k32 IMMA the warp converts int32 partials to float and applies
//           2^(ea+eb) on CUDA cores: acc += float(p) * (fa * fb)   (Avant-Garde Fig. 2).
//   MX9     two-level: exponent per 16 elements plus a 1-bit micro-exponent per pair.
//           Micro-exponents are applied once per CTA tile in shared memory (per-byte
//           arithmetic halving, i.e. 8-bit flattening with round toward -inf); then two
//           k16 IMMAs per 32 elements, each scaled by its own sub-block exponents.
// A is M x K row-major, B is N x K (K contiguous), C is M x N float.
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
constexpr int BM = 128, BN = 128, BK = 32, LDS = 48;  // 48-byte smem rows: conflict-free fragments
constexpr int THREADS = 256;

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

// Per-byte arithmetic >>1 on the bytes selected by mask (0xFF bytes).
__device__ __forceinline__ uint32_t halve_masked(uint32_t x, uint32_t m) {
    uint32_t sh = ((x >> 1) & 0x7F7F7F7Fu) | (x & 0x80808080u);
    return (sh & m) | (x & ~m);
}
// Apply one 16-element sub-block's micro-exponents (bit p set: pair p is halved).
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

template <int MODE>
__global__ void __launch_bounds__(THREADS)
gemm(const int8_t* __restrict__ A, const int8_t* __restrict__ B,
     const int8_t* __restrict__ EA, const int8_t* __restrict__ EB,     // exponents per row/col per block
     const uint8_t* __restrict__ UA, const uint8_t* __restrict__ UB,   // MX9 micro bits per 16 elements
     float* __restrict__ C, int M, int N, int K) {
    constexpr int SUB = MODE == MX9 ? 2 : 1;  // scale sub-blocks per BK
    __shared__ __align__(16) int8_t sA[2][BM * LDS];
    __shared__ __align__(16) int8_t sB[2][BN * LDS];
    __shared__ float fA[2][BM][SUB];
    __shared__ float fB[2][BN][SUB];
    const int tid = threadIdx.x, warp = tid >> 5, lane = tid & 31, g = lane >> 2, t = lane & 3;
    const int wm = (warp >> 2) * 64, wn = (warp & 3) * 32;
    const int bm = blockIdx.y * BM, bn = blockIdx.x * BN;
    const int lr = tid >> 1, lc = (tid & 1) * 16;            // this thread's 16-byte load chunk
    const int8_t* gA = A + static_cast<size_t>(bm + lr) * K + lc;
    const int8_t* gB = B + static_cast<size_t>(bn + lr) * K + lc;
    const int nk = K / BK, eStride = K / (BK / SUB);

    int accI[4][4][4];
    float accF[4][4][4];
#pragma unroll
    for (int i = 0; i < 4; i++)
#pragma unroll
        for (int j = 0; j < 4; j++)
#pragma unroll
            for (int k = 0; k < 4; k++) { accI[i][j][k] = 0; accF[i][j][k] = 0.f; }

    auto load = [&](int stage, int kt) {
        cp_async16(&sA[stage][lr * LDS + lc], gA + kt * BK);
        cp_async16(&sB[stage][lr * LDS + lc], gB + kt * BK);
        cp_commit();
        if (MODE != INT8) {  // scale factors for this K tile: threads 0..127 rows of A, 128..255 cols of B
            const int r = tid & 127;
            const int8_t* E = tid < 128 ? EA + static_cast<size_t>(bm + r) * eStride
                                        : EB + static_cast<size_t>(bn + r) * eStride;
            float* f = tid < 128 ? fA[stage][r] : fB[stage][r];
#pragma unroll
            for (int s = 0; s < SUB; s++) f[s] = exp2i(E[kt * SUB + s]);
        }
    };

    load(0, 0);
    for (int kt = 0; kt < nk; kt++) {
        const int s = kt & 1;
        cp_wait_all();
        if (MODE == MX9) {  // own chunk is complete: flatten it in place
            const int sub = kt * 2 + (lc >> 4);
            flatten16(&sA[s][lr * LDS + lc], UA[static_cast<size_t>(bm + lr) * eStride + sub]);
            flatten16(&sB[s][lr * LDS + lc], UB[static_cast<size_t>(bn + lr) * eStride + sub]);
        }
        __syncthreads();
        if (kt + 1 < nk) load(s ^ 1, kt + 1);
        const int8_t* a_s = sA[s];
        const int8_t* b_s = sB[s];
#pragma unroll
        for (int h = 0; h < (MODE == MX9 ? 2 : 1); h++) {
            uint32_t a[4][4], b[4][2];
#pragma unroll
            for (int mi = 0; mi < 4; mi++) {
                const int r0 = (wm + mi * 16 + g) * LDS, r1 = r0 + 8 * LDS;
                if (MODE == MX9) {
                    a[mi][0] = *reinterpret_cast<const uint32_t*>(a_s + r0 + h * 16 + t * 4);
                    a[mi][1] = *reinterpret_cast<const uint32_t*>(a_s + r1 + h * 16 + t * 4);
                } else {
                    a[mi][0] = *reinterpret_cast<const uint32_t*>(a_s + r0 + t * 4);
                    a[mi][1] = *reinterpret_cast<const uint32_t*>(a_s + r1 + t * 4);
                    a[mi][2] = *reinterpret_cast<const uint32_t*>(a_s + r0 + 16 + t * 4);
                    a[mi][3] = *reinterpret_cast<const uint32_t*>(a_s + r1 + 16 + t * 4);
                }
            }
#pragma unroll
            for (int ni = 0; ni < 4; ni++) {
                const int c0 = (wn + ni * 8 + g) * LDS;
                if (MODE == MX9) {
                    b[ni][0] = *reinterpret_cast<const uint32_t*>(b_s + c0 + h * 16 + t * 4);
                } else {
                    b[ni][0] = *reinterpret_cast<const uint32_t*>(b_s + c0 + t * 4);
                    b[ni][1] = *reinterpret_cast<const uint32_t*>(b_s + c0 + 16 + t * 4);
                }
            }
            if (MODE == INT8) {
#pragma unroll
                for (int mi = 0; mi < 4; mi++)
#pragma unroll
                    for (int ni = 0; ni < 4; ni++) mma_k32(accI[mi][ni], a[mi], b[ni]);
            } else {
                float fa[4][2], fb[4][2];
#pragma unroll
                for (int mi = 0; mi < 4; mi++) {
                    fa[mi][0] = fA[s][wm + mi * 16 + g][h];
                    fa[mi][1] = fA[s][wm + mi * 16 + g + 8][h];
                }
#pragma unroll
                for (int ni = 0; ni < 4; ni++) {
                    fb[ni][0] = fB[s][wn + ni * 8 + t * 2][h];
                    fb[ni][1] = fB[s][wn + ni * 8 + t * 2 + 1][h];
                }
#pragma unroll
                for (int mi = 0; mi < 4; mi++)
#pragma unroll
                    for (int ni = 0; ni < 4; ni++) {
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
#pragma unroll
    for (int mi = 0; mi < 4; mi++)
#pragma unroll
        for (int ni = 0; ni < 4; ni++) {
            const int r = bm + wm + mi * 16 + g, c = bn + wn + ni * 8 + t * 2;
#pragma unroll
            for (int k = 0; k < 4; k++) {
                const int rr = r + (k >> 1) * 8, cc = c + (k & 1);
                C[static_cast<size_t>(rr) * N + cc] =
                    MODE == INT8 ? static_cast<float>(accI[mi][ni][k]) : accF[mi][ni][k];
            }
        }
}

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

// CPU reference with the same semantics (flattening = floor halving of marked pairs).
static std::vector<double> reference(const Problem& p, int mode) {
    const int bs = mode == MX9 ? 16 : 32, nb = p.K / bs;
    auto elem = [&](const std::vector<int8_t>& X, const std::vector<uint8_t>& U, int row, int k) {
        int v = X[static_cast<size_t>(row) * p.K + k];
        if (mode == MX9 && ((U[static_cast<size_t>(row) * nb + k / 16] >> ((k % 16) / 2)) & 1)) v >>= 1;
        return v;
    };
    std::vector<double> C(static_cast<size_t>(p.M) * p.N);
    for (int i = 0; i < p.M; i++)
        for (int j = 0; j < p.N; j++) {
            double acc = 0;
            for (int b = 0; b < nb; b++) {
                long long part = 0;
                for (int k = b * bs; k < (b + 1) * bs; k++)
                    part += static_cast<long long>(elem(p.A, p.UA, i, k)) * elem(p.B, p.UB, j, k);
                acc += mode == INT8 ? static_cast<double>(part)
                                    : std::ldexp(static_cast<double>(part),
                                                 p.EA[static_cast<size_t>(i) * nb + b] + p.EB[static_cast<size_t>(j) * nb + b]);
            }
            C[static_cast<size_t>(i) * p.N + j] = acc;
        }
    return C;
}

struct Device {
    int8_t *A, *B, *EA, *EB;
    uint8_t *UA, *UB;
    float* C;
};
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
static void launch(int mode, const Device& d, int M, int N, int K) {
    dim3 grid(N / BN, M / BM);
    if (mode == INT8) gemm<INT8><<<grid, THREADS>>>(d.A, d.B, d.EA, d.EB, d.UA, d.UB, d.C, M, N, K);
    if (mode == MXINT8) gemm<MXINT8><<<grid, THREADS>>>(d.A, d.B, d.EA, d.EB, d.UA, d.UB, d.C, M, N, K);
    if (mode == MX9) gemm<MX9><<<grid, THREADS>>>(d.A, d.B, d.EA, d.EB, d.UA, d.UB, d.C, M, N, K);
    CHECK(cudaGetLastError());
}

static bool verify(int mode) {
    const int M = 256, N = 256, K = 512;
    Problem p = make_problem(M, N, K, mode, 7 + mode);
    Device d = upload(p);
    launch(mode, d, M, N, K);
    CHECK(cudaDeviceSynchronize());
    std::vector<float> C(static_cast<size_t>(M) * N);
    CHECK(cudaMemcpy(C.data(), d.C, C.size() * sizeof(float), cudaMemcpyDeviceToHost));
    release(d);
    std::vector<double> R = reference(p, mode);
    double worst = 0;
    for (size_t i = 0; i < C.size(); i++)
        worst = fmax(worst, fabs(C[i] - R[i]) / fmax(1.0, fabs(R[i])));
    const bool ok = mode == INT8 ? worst == 0 : worst < 1e-5;
    printf("verify %-6s %dx%dx%d  max rel err %.3g  %s\n", kModeName[mode], M, N, K, worst, ok ? "OK" : "FAIL");
    return ok;
}

int main(int argc, char** argv) {
    int reps = 20;
    std::vector<int> sizes = {2048, 4096, 8192};
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--reps") && i + 1 < argc) reps = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--size") && i + 1 < argc) sizes = {atoi(argv[++i])};
    }
    cudaDeviceProp prop;
    CHECK(cudaGetDeviceProperties(&prop, 0));
    printf("# %s, %d SMs; CTA %dx%dx%d, %d threads; reps %d\n", prop.name, prop.multiProcessorCount,
           BM, BN, BK, THREADS, reps);
    bool ok = true;
    for (int m = 0; m < 3; m++) ok &= verify(m);
    if (!ok) return 1;
    cudaEvent_t start, stop;
    CHECK(cudaEventCreate(&start));
    CHECK(cudaEventCreate(&stop));
    printf("%6s %-7s %10s %9s %12s\n", "size", "mode", "ms", "TOPS", "vs INT8");
    for (int S : sizes) {
        double base = 0;
        for (int m = 0; m < 3; m++) {
            Problem p = make_problem(S, S, S, m, 1);
            Device d = upload(p);
            for (int w = 0; w < (reps > 1 ? 3 : 0); w++) launch(m, d, S, S, S);
            CHECK(cudaEventRecord(start));
            for (int r = 0; r < reps; r++) launch(m, d, S, S, S);
            CHECK(cudaEventRecord(stop));
            CHECK(cudaEventSynchronize(stop));
            float ms;
            CHECK(cudaEventElapsedTime(&ms, start, stop));
            ms /= reps;
            if (m == INT8) base = ms;
            printf("%6d %-7s %10.3f %9.1f %11.3fx\n", S, kModeName[m], ms, 2.0 * S * S * S / ms / 1e9, ms / base);
            release(d);
        }
    }
    return 0;
}
