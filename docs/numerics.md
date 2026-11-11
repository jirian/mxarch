# Numerical contract and provenance

This is a numerical reconstruction.

Sources:

- [Avant-Garde, ISCA 2025](https://doi.org/10.1145/3695053.3731100),
  Sections 3, 4, 5.5, Figures 5, 7, 8, and Table 2. The supplied
  [local PDF](../avant_guard.pdf) shows Figures 7 and 8 on PDF pages 6 and 7.
- [With Shared Microexponents, A Little Shifting Goes a Long Way](https://arxiv.org/abs/2302.08007),
  the hierarchical format family referenced by Avant-Garde.
- [AMD's hierarchical MX9 description](https://quark.docs.amd.com/latest/pytorch/adv_two_level.html),
  an independently published explanation of scale selection.
- [Microsoft microxcaling](https://github.com/microsoft/microxcaling),
  especially its documented rounding and symmetric integer ranges. Its current
  OCP single-level quantizer is not substituted for hierarchical MX9.

## Encoding

Each row along the reduction dimension is zero-padded to a multiple of 16.
Each block retains its scale; adjacent blocks never acquire a common scale just
to represent a 32-element warp. Warp packing is unnecessary for numerical inference.

For a block maximum `M > 0`, let `E = floor(log2(M))`, extracted with `frexp` to
avoid log rounding near powers of two. The integer-code outer scale exponent is
`S = clamp(E - 6, -127, 127)`. For each pair, `micro = -1` if its maximum exponent
is less than `E`, else `0`. Zero pairs select `-1`; all-zero blocks use `E = 0`.

Store `q = saturate(round(x / 2**(S + micro)), -127, 127)` and decode as
`q * 2**(S + micro)`. The fixed-point radix is absorbed into `S`; metadata
integers are not a packed E8M0 encoding. The exponent bounds apply to the
integer-code scale, an explicit reconstruction convention. Tiny values below
the minimum scale can round to zero and are counted.

## Flattening assumptions

`operand_transform` implements Figure 7's multiplier routing explicitly:
reshape each block into eight pairs and multiply both elements of pair `j`
by `2**micro[j]`. It returns exact products before register quantization.
The two passes through sixteen multipliers for a 32-element warp are numerical
equivalents of this pairwise operation; software does not simulate the timing.
The first-level scale stays separate, including for two blocks in one warp.

Retain `S` and compute `q_flat = saturate(trunc(q * 2**micro), -127, 127)`.
Decode as `q_flat * 2**S`. Both micro scales have magnitude at most one, so this
rule cannot overflow an 8-bit element already in range. Odd codes in pairs
scaled by one half can lose a fractional bit. This is an effect to measure, not
evidence of incorrectly handled overflow in the authors' implementation.
A narrower configurable flattened width is a separate sensitivity experiment.

The lossless control stores `2 * q * 2**micro` in int16 and retains `S` plus one
fractional bit, preserving the hierarchical values exactly. Hierarchical and
lossless model outputs must match exactly on a given backend.

Conversion into hierarchical MX9 uses nearest-even by default (`--rounding`).
Flattening independently defaults to `--flatten-rounding trunc`: shift the
unsigned magnitude right by the secondary exponent, then restore its sign.
Thus `3/2 -> 1` and `-3/2 -> -1`, not `-2`. This matches discarding magnitude
bits in this signed-magnitude format. The FP64 multiplier output remains
available for diagnostics; the default flattened codes use actual integer shifts.
`even` and `nearest` remain explicit historical/sensitivity options. The
lossless control retains the fractional bit and does not truncate.

The paper does not fully specify flattened radix/width, tie handling, exceptional
values, layer coverage, checkpoint revisions, or evaluation preprocessing.
These choices are reconstruction assumptions, not claims of bit equivalence.
Matching Table 4 is not an acceptance test. The primary path applies no overflow
correction or rescaling during flattening.

## Computation boundaries

- The default `--backend figure8` keeps encoded operands and performs the
  block dot/scale/accumulate sequence described below. `--backend dequantized`
  reproduces the previous quantize/dequantize then FP32 PyTorch GEMM method.
  FP64 codec intermediates protect FP32 exponent boundaries; emulator speed is
  secondary to correctness.
- Cache encoded weights (decoded weights for the legacy backend) per
  storage/view/reduction axis/version. Parameters,
  embedding lookups and weight tying stay intact. Quantize activation operands
  on every use, including both attention products.
- Unfold ViT patch convolution into GEMM. Keep biases, normalization, softmax,
  GELU, residuals and other non-GEMM operations in FP32.
- With default `--activation-policy hierarchical`, matrix outputs and logical
  non-GEMM activation outputs are encoded into hierarchical MX9 as described
  below. `--activation-policy fp32` retains the previous behavior of leaving
  outputs in FP32 until the next GEMM. These policies have different rounding
  histories and are labeled separately in results.
- Disable TF32 and fused attention. Disable KV caching for perplexity evaluation.
  Target tested eager GPT-2/ViT architectures, not arbitrary compiled, distributed,
  sparse or third-party quantized models. No training is supported.

## Figure 8 numerical execution contract

`figure8_mma(A, B, C)` initializes an FP32 pipeline accumulator with `C` (zero
when absent). In increasing reduction-dimension order, for each 16-element block:

1. Compute the dot product of element codes without applying outer scales.
2. Add the two outer exponents. Interpret the result as an exponent, so the
   scaling factor is `2**(S_A + S_B)`, not the sum of the two scale magnitudes.
3. Multiply the dot result by that power of two, accounting for fixed-point
   fractional bits, and round the scaling-unit output to FP32.
4. Add that result to the pipeline register, rounding to FP32 again.

The code products and adder-tree sums are exact for MX9: even the widened
lossless control satisfies `16 * 255**2 < 2**24`. FP32 block matmul therefore
implements the integer dot without a dependence on tree shape. Each outer
scale is applied **after** the full block dot. Scaling uses FP64 `ldexp` then
one FP32 conversion to avoid premature overflow of a separately constructed
power of two. Accumulation is a separate addition, not a fused operation.
Overflow/subnormal results of the scaling unit and accumulator follow FP32.

Hierarchical and lossless controls share an exact half-integer mantissa grid:
hierarchical `q * 2**micro` is represented by integer `q * 2**(micro+1)` with
one fractional bit. This makes their dot/scale/accumulate results identical.
This widened control is not an assertion that Figure 8 accepts hierarchical
operands directly. The flattened experiment uses the rounded 8-bit codes.

The paper describes an 8-bit scale adder but does not specify carry handling,
scale-field encoding/bias and radix correction at that adder, multiplier/register
rounding, accumulation precision, or exact scheduling across MMA instructions.
Our signed integer-code exponents are an explicit convention, not a verified
packed hardware encoding. The default `--exponent-overflow wide` retains their
mathematical sum, leaving representability/underflow to the FP32 scaling unit.
An internal code-scale sum outside int8 is not sufficient evidence of hardware
overflow: for example, `64 * 64 * 2**(-120-10) = 2**-118` is normal FP32.
`error` rejects sums outside `[-128,127]`; `wrap` explicitly models signed 8-bit
wraparound. These remain optional sensitivity policies, **not
verified author behavior**. Fractional-bit corrections occur after this sum.
FP32 scale output, FP32 accumulation, separate roundings, and increasing-K
ordering are explicit reconstruction assumptions. Bit-for-bit equivalence to
the authors' hardware requires their arithmetic specification or implementation.

Linear and patch-projection biases initialize `C`. For `addmm`/`baddbmm`,
`beta*bias` initializes `C` when `alpha=1`; `beta=0` does not read bias values.
General `alpha!=1` uses a zero-initialized MMA followed by the BLAS epilogue.
Weights-only experiments use the legacy backend because unquantized FP32
activations do not match Figure 8's two scaled operands. Unquantized controls
always use native PyTorch FP32. Each JSON run records the requested/effective
backend, numerical-contract version, accumulator dtype, and overflow policy;
CSV and graph labels also distinguish backends. Previous JSON results remain
legacy dequantized-GEMM measurements and are not retroactively Figure 8 results.

## Hierarchical activation policy (v2)

This is the explicitly selected experimental policy, not an inference behavior
established by the paper. Section 3.2 describes rebuilding a hierarchical format
during training: regroup values, select scales from maxima, and encode the
elements and scales again. `unflatten_mx9` implements that reconstruction from
either flattened operands or floating-point arithmetic results. It does not
restore discarded bits or reuse stale scales from the input.

The numerical path in flattened mode is:

`hierarchical activation -> flatten by magnitude shifts -> block dot/scale/FP32
accumulation -> rebuild hierarchical MX9 -> decode for FP32 non-GEMM arithmetic
-> rebuild hierarchical MX9`.

The accumulator is kept FP32 throughout the whole K reduction. Rebuilding the
hierarchy happens after the matrix result and bias/BLAS epilogue, not between
K blocks. There is no additional lossy flattening on the output before this
conversion: it enters the hierarchy directly from the floating result. A later
GEMM flattens its input. The default output policy therefore uses the paper's
floating output option followed by the selected unflatten conversion.

Activation boundaries are explicit:

- Matrix results (including attention products and final logits) use the last
  output dimension. ViT patch projections use output channels before the NCHW
  reshape. Blocks contain 16 elements and pairs contain two.
- Embedding lookup, LayerNorm and complete GELU outputs are encoded along the
  last dimension. Their CUDA operations and internal intermediates remain FP32.
- Softmax outputs are encoded along the softmax dimension. Scaling/masking
  inside attention remains FP32; boolean masks and negative-infinity sentinels
  are control values, never encoded as MX9. Quantized probability rows need not
  sum to exactly one; there is no corrective renormalization.
- Residual and position additions in the tested GPT-2/ViT modules are encoded
  along the last dimension. Views, copies, reshapes, concatenations and eval-mode
  dropout do not introduce extra rounding.

Ordinary tensors carry decoded hierarchical values between these boundaries.
This is numerical storage emulation, not packed MX9 storage: CUDA cores receive
FP32 representations of MX9 values and perform their unchanged operations.
The next boundary re-encodes the result. A transpose can change the GEMM's
reduction grouping, so operands are regrouped along K as before. Norm parameters,
biases, masks and other non-GEMM parameters remain FP32.

The same boundaries apply to hierarchical, flattened and lossless modes;
unquantized and weights-only controls retain FP32 activations. Coverage checks
require the expected softmax, GELU, normalization, residual/position, embedding
and patch events for the tested architectures. JSON records both the requested
and effective activation policy, event counts and `hierarchical-boundaries-v1`.
`figure7-8-mx9-v2` identifies the updated integration. Older results remain valid
for their original assumptions; no saved result is relabeled as a new experiment.

## Conversion diagnostics

`quantize` measures against incoming FP32 operands; `flatten` measures additional
error against the already quantized hierarchy. Counts exclude padding.
`unflatten` measures rounding at hierarchical activation-storage boundaries.
`out_of_range` counts pre-rounded codes outside the finite code range;
`saturated` counts rounded codes requiring clipping. `rounded_to_zero` counts
lost nonzero incoming values. `rounding_changed` counts nonintegral codes.
Nonfinite inputs raise immediately rather than inventing an encoding;
`nonfinite` is zero for successful conversions.

Activation statistics accumulate over calls. Cached weights count once per view,
not once per window. Divide error sums by `elements` for mean absolute/squared
error. Maximum absolute error is recorded separately. Diagnostics are keyed by
module, role, axis and conversion stage. Failed runs do not emit success reports.

## Evaluation interpretation

GPT-2 scores `context - 1` transitions per nonoverlapping full window. All modes
in one experiment use identical inputs. Perplexity is exponential token-weighted
mean loss. A fixed window count changes token counts across contexts, so the
supplied sweeps are exploratory. Input hashes make paired comparisons auditable.
Text hashes, dataset fingerprints, checkpoint commits, seeds, versions and
operation coverage are recorded.

ImageNet labels must be zero-based IDs in the checkpoint's class order. The
manifest defines sample order; checkpoint processors define preprocessing.
Keep image contents immutable: the manifest hash does not checksum image bytes.

The CSV exporter makes positive degradation mean increased perplexity or reduced
accuracy (percentage points). Bar graphs compare unquantized FP32, hierarchical
MX9, and flattened MX9 as metric/FP32, with separate panels for perplexity and
top-1 accuracy. FP32 is 1; lower perplexity and higher accuracy are better.
The lossless diagnostic control stays in the CSV but is excluded from the bars.
Normalization is undefined for a zero FP32 baseline: CSV stores an empty cell
and plots mark N/A. Each report uses its own FP32 baseline. Labels distinguish
weights-only runs from the default weights-and-activations runs.
Size associations are descriptive; context length is not a reasoning benchmark.
