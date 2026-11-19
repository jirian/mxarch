// Instruction latency/throughput microbenchmarks for the Avant-Garde spreadsheet model.
// Timed in-kernel with clock64(); needs no GPU performance-counter access.
//   latency:    1 warp, one dependent chain, cycles per instruction
//   throughput: many warps x ILP independent chains, instructions per cycle per SM
// Check the emitted SASS with: cuobjdump -sass ubench | grep -E 'HMMA|IMMA|I2F|FFMA|...'
#include <cstdio>
#include <cstdint>
#include <cuda_runtime.h>

#define CHECK(x) do { cudaError_t e = (x); if (e != cudaSuccess) { \
    printf("CUDA error %s at %s:%d\n", cudaGetErrorString(e), __FILE__, __LINE__); return 1; } } while (0)

constexpr int ITERS = 4096;
constexpr int ILP = 8;   // independent chains per thread in throughput mode

// One step of each operation on chain state `s` (kept in registers).
struct HMMA {  // mma.sync m16n8k16 f16 x f16 + f32 -> f32
    static constexpr const char* name = "HMMA.16816.F32 (mma m16n8k16 f16)";
    float d[4]; uint32_t a[4], b[2];
    __device__ void init(int t, int) { for (int i = 0; i < 4; i++) { d[i] = 0.f; a[i] = 0x3c003c00u + t; } b[0] = b[1] = 0x3c003c00u; }
    __device__ void step() {
        asm volatile("mma.sync.aligned.m16n8k16.row.col.f32.f16.f16.f32 "
                     "{%0,%1,%2,%3}, {%4,%5,%6,%7}, {%8,%9}, {%0,%1,%2,%3};"
                     : "+f"(d[0]), "+f"(d[1]), "+f"(d[2]), "+f"(d[3])
                     : "r"(a[0]), "r"(a[1]), "r"(a[2]), "r"(a[3]), "r"(b[0]), "r"(b[1]));
    }
    __device__ float out() { return d[0] + d[1] + d[2] + d[3]; }
};
struct IMMA {  // mma.sync m16n8k32 s8 x s8 + s32 -> s32 (INT8 engine used by MX9/MXINT8)
    static constexpr const char* name = "IMMA.16832.S8 (mma m16n8k32 s8)";
    int d[4]; uint32_t a[4], b[2];
    __device__ void init(int t, int) { for (int i = 0; i < 4; i++) { d[i] = 0; a[i] = 0x01010101u + t; } b[0] = b[1] = 0x01010101u; }
    __device__ void step() {
        asm volatile("mma.sync.aligned.m16n8k32.row.col.s32.s8.s8.s32 "
                     "{%0,%1,%2,%3}, {%4,%5,%6,%7}, {%8,%9}, {%0,%1,%2,%3};"
                     : "+r"(d[0]), "+r"(d[1]), "+r"(d[2]), "+r"(d[3])
                     : "r"(a[0]), "r"(a[1]), "r"(a[2]), "r"(a[3]), "r"(b[0]), "r"(b[1]));
    }
    __device__ float out() { return float(d[0] + d[1] + d[2] + d[3]); }
};
// Scalar ops: the CUDA-core work a software MX GEMM adds per partial sum.
#define SCALAR_OP(NAME, LABEL, T, INIT, ASM, OUTC, INC)                                   \
struct NAME {                                                                       \
    static constexpr const char* name = LABEL;                                      \
    T x; T k;                                                                       \
    /* k is a runtime value (seed), so ptxas cannot fold the chain */             \
    __device__ void init(int t, int seed) { x = (T)(INIT + t); k = (T)(INIT) * (T)seed; } \
    __device__ void step() { asm volatile(ASM : OUTC(x) : INC(k)); }           \
    __device__ float out() { return (float)x; }                                     \
};
SCALAR_OP(FFMA, "FFMA (fma.rn.f32)", float, 1.0001f, "fma.rn.f32 %0, %0, %1, %1;", "+f", "f")
SCALAR_OP(FMUL, "FMUL (mul.rn.f32)", float, 1.0001f, "mul.rn.f32 %0, %0, %1;", "+f", "f")
SCALAR_OP(IMAD, "IMAD (mad.lo.s32)", int, 3, "mad.lo.s32 %0, %0, %1, %1;", "+r", "r")
SCALAR_OP(SHF, "SHF (shf.l.wrap.b32, rotate)", uint32_t, 3, "shf.l.wrap.b32 %0, %0, %0, %1;", "+r", "r")
struct I2F {  // int32 partial sum -> float, the conversion before scaling
    static constexpr const char* name = "I2F (cvt.rn.f32.s32) + F2I chain";
    int x; __device__ void init(int t, int) { x = 7 + t; }
    __device__ void step() {
        float f;
        asm volatile("cvt.rn.f32.s32 %0, %1;" : "=f"(f) : "r"(x));
        asm volatile("cvt.rzi.s32.f32 %0, %1;" : "=r"(x) : "f"(f));
    }
    __device__ float out() { return (float)x; }
};
struct EX2 {  // 2^x on the SFU, one way to build a scale from an exponent
    static constexpr const char* name = "MUFU.EX2 (ex2.approx.f32)";
    float x; __device__ void init(int t, int) { x = 0.5f + t * 1e-3f; }
    __device__ void step() { asm volatile("ex2.approx.ftz.f32 %0, %0;" : "+f"(x)); }
    __device__ float out() { return x; }
};

template <class Op, int CHAINS>
__global__ void bench(long long* cycles, float* sink, int seed) {
    Op op[CHAINS];
    for (int c = 0; c < CHAINS; c++) op[c].init(threadIdx.x + c, seed);
    __syncthreads();
    long long start = clock64();
    for (int i = 0; i < ITERS; i++) {
#pragma unroll
        for (int c = 0; c < CHAINS; c++) op[c].step();
    }
    __syncthreads();
    long long stop = clock64();
    float acc = 0.f;
    for (int c = 0; c < CHAINS; c++) acc += op[c].out();
    sink[blockIdx.x * blockDim.x + threadIdx.x] = acc;
    if (threadIdx.x == 0) cycles[blockIdx.x] = stop - start;
}

template <class Op>
int run(int sms, float* sink, long long* cycles_d) {
    long long cyc[1024];
    // Latency: one warp, one chain.
    bench<Op, 1><<<1, 32>>>(cycles_d, sink, 1);
    CHECK(cudaDeviceSynchronize());
    CHECK(cudaMemcpy(cyc, cycles_d, sizeof(long long), cudaMemcpyDeviceToHost));
    double latency = double(cyc[0]) / ITERS;
    // Throughput: one block per SM, 16 warps x ILP chains. Instructions are
    // counted per warp (one warp-wide mma/scalar instruction = 1).
    const int warps = 16;
    bench<Op, ILP><<<sms, 32 * warps>>>(cycles_d, sink, 1);
    CHECK(cudaDeviceSynchronize());
    CHECK(cudaMemcpy(cyc, cycles_d, sms * sizeof(long long), cudaMemcpyDeviceToHost));
    long long worst = 0;
    for (int i = 0; i < sms; i++) worst = cyc[i] > worst ? cyc[i] : worst;
    double per_sm = double(warps) * ILP * ITERS / worst;
    printf("%-40s latency %7.2f cycles   throughput %7.3f warp-instr/cycle/SM\n",
           Op::name, latency, per_sm);
    return 0;
}

int main() {
    cudaDeviceProp p;
    CHECK(cudaGetDeviceProperties(&p, 0));
    printf("# %s, %d SMs, SM clock %d MHz, ITERS=%d ILP=%d\n", p.name, p.multiProcessorCount,
           p.clockRate / 1000, ITERS, ILP);
    float* sink; long long* cycles;
    CHECK(cudaMalloc(&sink, p.multiProcessorCount * 512 * sizeof(float)));
    CHECK(cudaMalloc(&cycles, 1024 * sizeof(long long)));
    int sms = p.multiProcessorCount;
    if (run<HMMA>(sms, sink, cycles) || run<IMMA>(sms, sink, cycles) ||
        run<FFMA>(sms, sink, cycles) || run<FMUL>(sms, sink, cycles) ||
        run<IMAD>(sms, sink, cycles) ||
        run<SHF>(sms, sink, cycles) || run<I2F>(sms, sink, cycles) ||
        run<EX2>(sms, sink, cycles)) return 1;
    return 0;
}
