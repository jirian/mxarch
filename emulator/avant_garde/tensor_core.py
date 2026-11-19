"""Figure 8 stage-order emulator for MX9; see docs/numerics.md for assumptions.

This is a numerical implementation, not an RTL or cycle-accurate simulator.
"""
import torch

from .mx9 import MX9Tensor


EXPONENT_POLICIES = ("error", "wrap", "wide")
# Accumulator formats for the pipeline register. "fp32" is the paper-faithful
# default; the others are sensitivity settings, not claims about Avant-Garde:
# BF16/FP16 storage, and FP32 with its mantissa rounded to 14 bits, the kind of
# reduced-precision accumulation DeepSeek-V3 reports for H800 FP8 tensor cores.
ACCUMULATORS = ("fp32", "bf16", "fp16", "fp32-m14")


def round_accumulator(x, accumulator):
    """Round an FP32 tensor to the selected accumulator format (nearest-even)."""
    if accumulator == "fp32":
        return x
    if accumulator == "bf16":
        return x.to(torch.bfloat16).float()
    if accumulator == "fp16":
        return x.to(torch.float16).float()
    if accumulator == "fp32-m14":
        mantissa, exponent = torch.frexp(x)        # x = mantissa * 2**exponent, |mantissa| in [0.5, 1)
        # 14 stored mantissa bits plus the implicit bit: 15 significant bits.
        return torch.ldexp(torch.round(torch.ldexp(mantissa, torch.full_like(exponent, 15))),
                           exponent - 15)
    raise ValueError(f"Unknown accumulator format: {accumulator}")


def combine_exponents(a, b, overflow="error"):
    """Add signed integer-code exponents; never silently choose overflow behavior."""
    if overflow not in EXPONENT_POLICIES:
        raise ValueError(f"Unknown exponent overflow policy: {overflow}")
    total = a.to(torch.int32) + b.to(torch.int32)
    if overflow == "error" and bool(((total < -128) | (total > 127)).any()):
        raise OverflowError("Combined scale exponent exceeds signed 8-bit range; "
                            "the paper does not specify carry/overflow behavior. "
                            "Select wrap or wide explicitly for a sensitivity experiment.")
    if overflow == "wrap":
        total = (total + 128).remainder(256) - 128
    return total


def _codes(x):
    # A common half-integer grid preserves all hierarchical pair scales exactly.
    # This is a baseline/control representation, not an 8-bit flattened operand.
    codes = x.elements.to(torch.float32)
    if x.micro_exp is not None:
        codes = torch.ldexp(codes, x.micro_exp.repeat_interleave(2, -1).int() + 1)
        fractional_bits = 1
    else:
        fractional_bits = x.fractional_bits
    if bool((codes.abs() > 255).any()):
        raise ValueError("Exact block dot products require MX9 codes of magnitude <= 255")
    return codes, x.outer_exp.squeeze(-1).int(), fractional_bits


def figure8_mma(a: MX9Tensor, b: MX9Tensor, c=None, *, exponent_overflow="wide", accumulator="fp32"):
    """Compute C + A @ B with a separately rounded scale and an accumulator (FP32 by default).

    Each K block has 16 elements and independent outer scales. Blocks advance
    in increasing K order. Batched operands broadcast as in torch.matmul.
    Exponent addition precedes fixed-point radix correction. C initializes the
    pipeline register. Products/adder-tree sums are exact for this MX9 range.
    """
    if (len(a.shape) < 2 or len(b.shape) < 2 or a.axis != len(a.shape) - 1
            or b.axis != len(b.shape) - 2 or a.shape[-1] != b.shape[-2]):
        raise ValueError("Expected matrix operands quantized along their matching K axes")
    if a.elements.device != b.elements.device:
        raise ValueError("Operands must be on the same device")
    if exponent_overflow not in EXPONENT_POLICIES:
        raise ValueError(f"Unknown exponent overflow policy: {exponent_overflow}")
    if accumulator not in ACCUMULATORS:
        raise ValueError(f"Unknown accumulator format: {accumulator}")
    ac, ae, af = _codes(a)
    bc, be, bf = _codes(b)
    shape = (*torch.broadcast_shapes(a.shape[:-2], b.shape[:-2]), a.shape[-2], b.shape[-1])
    if c is None:
        acc = torch.zeros(shape, dtype=torch.float32, device=ac.device)
    else:
        acc = round_accumulator(torch.broadcast_to(c.to(device=ac.device, dtype=torch.float32), shape).clone(),
                                accumulator)
    # Validate the extrema per block once, avoiding a host synchronization for
    # each K block. Rows/columns are independent and every combination is used.
    if exponent_overflow == "error":
        combine_exponents(ae.amin(-2), be.amin(-2), "error")
        combine_exponents(ae.amax(-2), be.amax(-2), "error")
    for block in range(ac.shape[-2]):
        # All inputs are exact integers <=255, and 16*255**2 < 2**24.
        # Thus FP32 matmul gives the exact integer adder-tree result regardless
        # of reduction order; TF32 can also represent these small integers.
        dot = ac[..., :, block, :] @ bc[..., :, block, :].transpose(-1, -2)
        exponent = combine_exponents(ae[..., :, block, None], be[..., None, :, block],
                                     "wrap" if exponent_overflow == "wrap" else "wide")
        # FP64 ldexp avoids materializing an overflowing/underflowing FP32
        # power of two before multiplication. Round the scaling unit output
        # exactly once to FP32, including subnormal results, then add separately.
        scaled = torch.ldexp(dot.double(), exponent - af - bf).float()
        acc = round_accumulator(acc + round_accumulator(scaled, accumulator), accumulator)
    return acc
