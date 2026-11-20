# Poster talk: How Avant-Garde Scales to Large LLM Inference

Numbers below match the final report and `RESULTS.md`. Point at the poster
block named in brackets.

## 2-minute pitch

[The problem] LLM inference is limited by energy and memory, and narrow
block-scaled formats help with both. But on an H100 the tensor core can't
apply block scales, so they're applied in software afterwards. Avant-Garde, an
ISCA 2025 paper, adds hardware for this. Its key step is *flattening*: MX9 gives
every pair of elements an extra 1-bit exponent, and Avant-Garde folds that into
the elements so an INT8-style tensor core can use them. Halving those elements
drops a bit, and the paper never says how it's rounded.

[Result 1] We tested flattening on Qwen3-8B and the 30B mixture-of-experts
model. With round-to-nearest, perplexity rises 1.1 to 2.5%, far above the
paper's 0.2%. With truncation, a plain hardware shift, it *drops* instead,
and task accuracy on ARC and HellaSwag stays the same. Small GPT-2 models fail
by 3 to 4% either way. So flattening is not equivalent to MX9, and an
unspecified rounding choice decides the outcome.

[Result 2] The overhead Avant-Garde removes is real: on an H100, software
scaling makes MX9 GEMMs 2x slower in decode and 4x in prefill.

[Result 3] We also built a lossless alternative in RTL: apply the
microexponent after the multipliers. Placed and routed in 45 nm, it keeps
INT8 throughput and costs 13 to 22% of tensor-core area, under 1% of an SM.

## 5-minute walkthrough

1. **The problem (45 s).** Decode is 77-99% of a request's energy. Block-scaled
   formats share one scale per block; MX9 adds a 1-bit microexponent per pair.
   H100 tensor cores do plain integer dot products, so scales go to the CUDA
   cores. Avant-Garde's Operand Transformer flattens MX9 into one scale per
   block. Diagram: pairs with mu = 1 are halved, odd codes lose their last bit.

2. **Previous work (30 s).** Blackwell natively supports single-level MX formats
   and NVFP4, but not per-pair microexponents. The shared-microexponent paper
   proposed shifting products inside the dot product; nobody compared that with
   flattening as a GPU tensor core. Avant-Garde reported accuracy only for
   GPT-2/ViT and left rounding unspecified.

3. **Methods (45 s).** Three tracks. Accuracy: a PyTorch emulator that
   quantizes every GEMM, with the paper's tensor-core arithmetic order;
   perplexity on Wikipedia and WikiText-2, plus ARC and HellaSwag accuracy,
   with paired bootstrap confidence intervals. Performance: our own H100
   kernels for INT8, MXINT8 and MX9. Hardware: RTL for three lane designs,
   verified bit for bit against the emulator, placed and routed with
   OpenROAD in FreePDK45, power from real Qwen3 operands.

4. **Result 1 (75 s).** The chart: blue is round-to-nearest, orange truncation.
   GPT-2 Small/Medium fail either way; Large/XL pass, as the paper says. Qwen3
   flips sign: +1.1% vs -0.6% on 8B, +2.5% vs -1.5% on the MoE model, same at
   8k context and on WikiText-2. Truncation lands 0.9% *below* FP32, which is a
   bias, but task accuracy doesn't drop, so it isn't harmful. 67-82% of real
   pairs use the finer exponent, so the bit is lost in most pairs. On the MoE
   model the loss sits in attention and the LM head, not in the experts.

5. **Result 2 (45 s).** Software scaling: MX9 is 2.1x INT8 in decode and 4x in
   prefill. Decode does not hide it behind memory: a better INT8 kernel widens
   the gap, because scaling is bound by instruction issue. We checked whether
   the paper's k16 INT8 baseline explains our 2x larger MX9 overhead; it
   doesn't, k16 INT8 is only 0-2% slower.

6. **Result 3 (60 s).** Three designs: (a) Avant-Garde's flattening, (b) 9-bit
   operands, (c) late shift by 0-2 positions after the multiplier. Both (b) and
   (c) are exact. The late shift is cheaper than wide operands. Over Avant-Garde
   in the same encoding it costs 13-22% area and 16-39% power per tensor core,
   under 1% of an SM; with sign-magnitude elements, a lossless tensor core costs
   about as much as today's INT8 one. Same throughput, at most one extra
   pipeline stage.

7. **Takeaways (20 s).** The overhead is worth removing; flattening's accuracy
   depends on an unspecified rounding choice; a late microexponent shift makes
   it exact for little hardware.

## Likely questions

**Why does truncation lower perplexity?**
Truncation shrinks halved elements toward zero, a consistent bias in every
affected dot product. On text the model has likely seen in training, that
happens to lower perplexity. We don't claim it improves the model: ARC and
HellaSwag accuracy stay within noise (one metric +1.1 points), which only shows
it isn't harmful on these tasks.

**Is the Wikipedia evaluation text contaminated?**
Probably, for Qwen3, which is why we also used WikiText-2 (same flip:
+1.29% vs -0.83%) and task accuracy. Every comparison is paired on identical
tokens, so contamination shifts absolute perplexity, not the flattened vs
non-flattened difference.

**Why is your MX9 overhead twice the paper's?**
Our 4x is measured wall-clock time; the paper's 1.93x is modelled with
Accel-Sim and instruction counts. We tested the obvious baseline difference
(k16 vs k32 INT8 instructions): it changes INT8 by only 0-2%. The overhead is
the CUDA-core scaling work: MX9 runs 8.2x the instructions of INT8 and halves
occupancy.

**Why 45 nm and open-source tools?**
FreePDK45 is the node the paper used, so our overheads are comparable to its
1.2-3.9%. Absolute areas from Yosys/OpenROAD differ from commercial tools, so we
only compare designs within one flow.

**How do you know the RTL is right?**
Golden values come from the same emulator that produced every accuracy number:
60,030 synthetic and 6,656 real Qwen3 block pairs, bit-exact for the RTL, the
synthesized and the routed netlists, in two simulators. Injected bugs are
caught. The operand transformers are also formally proven equal to their RTL.

**What does "share of an SM" assume?**
That tensor cores are about 5% of SM area, inferred from the paper's own 3.9%
(tensor core) and 1.4% (overall) overheads. The tensor-core percentages don't
depend on it.

**Why not just widen to 9-bit operands?**
It's exact too, but costs more area (+23% vs +15% per tensor core in two's
complement): 9x9 multipliers are bigger than 8x8 ones plus small shifters.

**Does the extra critical path cost throughput?**
No. All designs issue one dot product per lane per clock. The lossless lanes are
6-7% slower, at most one more pipeline stage, about 4% more MMA latency, which
memory-bound decode hides. The late shift also removes Avant-Garde's 2-cycle
flattening stage.

**What about the MoE model?**
The loss under round-to-nearest sits in attention products (52%), attention
projections (42%) and the LM head (23%); flattening only the experts is
harmless. We validated the static policy: flatten only the experts and router
(47% of the GEMM work), keep attention and the LM head exact, and the loss is
gone (-0.28%, also on held-out windows). Under truncation it's the other way
round (experts hurt, +0.60%), so the right split depends on the rounding too.

**Does accumulator precision matter?**
FP16 or a 14-bit FP32 mantissa change nothing; BF16 accumulation shifts the
penalty (GPT-2 Small with truncation 3.8% -> 5.3%).

**What didn't you do?**
Long-generation tasks, MX6/MX4, and the decode attention kernel (so the decode
result covers linear layers only).

**How much of prefill would Avant-Garde actually speed up?**
With fused attention, norms, RoPE, SiLU and residual adds still take 24-37%
of a Qwen3-8B layer. So even removing the whole scaling overhead from the
projection GEMMs gives at most 1.3-1.7x per layer; 2.3-2.8x only if attention
also runs in MX9.
