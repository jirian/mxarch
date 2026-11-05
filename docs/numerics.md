# Numerical contract and provenance

This is a numerical reconstruction.

Sources:

- [Avant-Garde, ISCA 2025](https://doi.org/10.1145/3695053.3731100),
  Sections 3, 4, 5.5, Figure 5, and Table 2.
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

Retain `S` and compute `q_flat = saturate(round(q * 2**micro), -127, 127)`.
Decode as `q_flat * 2**S`. Both micro scales have magnitude at most one, so this
rule cannot overflow an 8-bit element already in range. Odd codes in pairs
scaled by one half can lose a fractional bit. This is an effect to measure, not
evidence of incorrectly handled overflow in the authors' implementation.
A narrower configurable flattened width is a separate sensitivity experiment.

The lossless control stores `2 * q * 2**micro` in int16 and retains `S` plus one
fractional bit, preserving the hierarchical values exactly. Hierarchical and
lossless model outputs must match exactly on a given backend.

Default rounding is nearest, ties to even. Alternatives are ties away from zero
(`nearest`) and toward zero (`trunc`). Microsoft's name for toward-zero rounding
is `floor`; this repository avoids that ambiguous name.

The paper does not fully specify flattened radix/width, tie handling, exceptional
values, layer coverage, checkpoint revisions, or evaluation preprocessing.
These choices are reconstruction assumptions, not claims of bit equivalence.
Matching Table 4 is not an acceptance test. The primary path applies no overflow
correction or rescaling during flattening.

## Computation boundaries

- Quantize/dequantize GEMM operands, then use FP32 PyTorch GEMMs and accumulation.
  FP64 codec intermediates protect FP32 exponent boundaries; emulator speed is
  secondary to correctness.
- Cache decoded weights per storage/view/reduction axis/version. Parameters,
  embedding lookups and weight tying stay intact. Quantize activation operands
  on every use, including both attention products.
- Unfold ViT patch convolution into GEMM. Keep biases, normalization, softmax,
  GELU, residuals and other non-GEMM operations in FP32.
- Outputs remain FP32 until used as another quantized operand. This selects the
  paper's floating output option, rather than persistent flattened activations
  across non-GEMM operations. Other boundaries can change rounding history.
- Disable TF32 and fused attention. Disable KV caching for perplexity evaluation.
  Target tested eager GPT-2/ViT architectures, not arbitrary compiled, distributed,
  sparse or third-party quantized models. No training is supported.

## Diagnostics

`quantize` measures against incoming FP32 operands; `flatten` measures additional
error against the already quantized hierarchy. Counts exclude padding.
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
