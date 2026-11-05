"""Hierarchical shared-microexponent MX9, distinct from OCP MXINT8.

Elements are signed magnitude integers in [-127,127]. Integer-code units
absorb the implicit fixed-point factor: x = q * 2**outer_exp * 2**micro_exp.
The latter is 0 or -1. See docs/numerics.md for reconstruction assumptions.
"""
from dataclasses import dataclass
from typing import Literal

import torch
import torch.nn.functional as F

Mode = Literal["fp32", "mx9_hierarchical", "mx9_flattened", "mx9_lossless"]
MODES = ("fp32", "mx9_hierarchical", "mx9_flattened", "mx9_lossless")


@dataclass(frozen=True)
class MX9Config:
    rounding: str = "even"
    flattened_bits: int = 8
    block_size: int = 16
    pair_size: int = 2
    exponent_min: int = -127
    exponent_max: int = 127

    def __post_init__(self):
        if self.rounding not in ("even", "nearest", "trunc"):
            raise ValueError("rounding must be even, nearest, or trunc")
        if self.flattened_bits < 2 or self.flattened_bits > 16:
            raise ValueError("flattened_bits must be between 2 and 16")
        if (self.block_size, self.pair_size) != (16, 2):
            raise ValueError("This MX9 implementation requires 16-element blocks and pairs")
        if (self.exponent_min, self.exponent_max) != (-127, 127):
            raise ValueError("This implementation uses outer scale exponents [-127,127]")


@dataclass
class MX9Tensor:
    elements: torch.Tensor  # [..., nblocks, 16], int8 or int16
    outer_exp: torch.Tensor  # [..., nblocks, 1], integer-code scale exponent
    micro_exp: torch.Tensor | None  # [..., nblocks, 8], 0 or -1
    shape: tuple[int, ...]  # original tensor shape
    axis: int
    stats: dict[str, torch.Tensor]
    fractional_bits: int = 0  # lossless flattening keeps one fractional bit


def _round(x, rounding):
    if rounding == "even":
        return torch.round(x)
    if rounding == "nearest":
        return x.sign() * torch.floor(x.abs() + 0.5)
    return torch.trunc(x)


def _mask(shape, axis, blocks, device):
    moved = list(shape)
    length = moved.pop(axis)
    moved.append(blocks * 16)
    valid = torch.arange(blocks * 16, device=device) < length
    return valid.expand(moved).reshape(*moved[:-1], blocks, 16)


def quantize_mx9(x: torch.Tensor, axis: int = -1,
                 config: MX9Config = MX9Config()) -> MX9Tensor:
    if not x.is_floating_point() or x.ndim == 0 or x.numel() == 0:
        raise ValueError("Expected a nonempty floating-point tensor with rank >= 1")
    if not -x.ndim <= axis < x.ndim:
        raise ValueError("Quantization axis out of range")
    if not bool(torch.isfinite(x).all()):
        raise ValueError("Nonfinite MX9 input; no implicit NaN/Inf encoding is assumed")
    axis %= x.ndim
    values = x.detach().movedim(axis, -1).to(torch.float64)
    length = values.shape[-1]
    values = F.pad(values, (0, (-length) % 16))
    blocks = values.reshape(*values.shape[:-1], -1, 16)
    maximum = blocks.abs().amax(-1, keepdim=True)
    # frexp avoids log2 rounding up immediately below powers of two.
    raw_exp = torch.frexp(maximum).exponent - 1
    raw_exp = torch.where(maximum == 0, 0, raw_exp)
    outer_unclamped = raw_exp - 6
    outer = outer_unclamped.clamp(config.exponent_min, config.exponent_max)
    pair_maximum = blocks.abs().reshape(*blocks.shape[:-1], 8, 2).amax(-1)
    pair_exp = torch.frexp(pair_maximum).exponent - 1
    micro = torch.where((pair_maximum == 0) | (pair_exp < raw_exp), -1, 0)
    full_exp = outer + micro.repeat_interleave(2, -1)
    scaled = torch.ldexp(blocks, -full_exp)
    rounded = _round(scaled, config.rounding)
    clipped = rounded.clamp(-127, 127)
    valid = _mask(tuple(x.shape), axis, blocks.shape[-2], x.device)
    decoded = torch.ldexp(clipped, full_exp)
    error = (decoded - blocks).abs()
    stats = {
        "elements": valid.sum(),
        "rounding_changed": ((rounded != scaled) & valid).sum(),
        "rounded_to_zero": ((blocks != 0) & (clipped == 0) & valid).sum(),
        "out_of_range": ((scaled.abs() > 127) & valid).sum(),
        "saturated": ((rounded.abs() > 127) & valid).sum(),
        "scale_clamped_blocks": (outer_unclamped != outer).sum(),
        "nonfinite": torch.zeros((), device=x.device, dtype=torch.int64),
        "abs_error_sum": (error * valid).sum(),
        "squared_error_sum": (error.square() * valid).sum(),
        "max_abs_error": (error * valid).amax(),
    }
    return MX9Tensor(clipped.to(torch.int8), outer.to(torch.int16),
                     micro.to(torch.int8), tuple(x.shape), axis, stats)


def flatten_mx9(x: MX9Tensor, config: MX9Config = MX9Config(),
                lossless: bool = False) -> MX9Tensor:
    if x.micro_exp is None:
        raise ValueError("Operand is already flattened")
    micro = x.micro_exp.repeat_interleave(2, -1).to(torch.int32)
    # Exact half-integers, then one rounding into the retained outer-scale grid.
    absorbed = torch.ldexp(x.elements.to(torch.float64), micro)
    fractional_bits = 1 if lossless else 0
    scaled = absorbed * (2 ** fractional_bits)
    rounded = scaled if lossless else _round(scaled, config.rounding)
    limit = 255 if lossless else (2 ** (config.flattened_bits - 1) - 1)
    clipped = rounded.clamp(-limit, limit)
    valid = _mask(x.shape, x.axis, x.elements.shape[-2], x.elements.device)
    decoded_error = torch.ldexp((clipped / (2 ** fractional_bits) - absorbed).abs(),
                                x.outer_exp)
    stats = {
        "elements": valid.sum(),
        "rounding_changed": ((rounded != scaled) & valid).sum(),
        "rounded_to_zero": ((absorbed != 0) & (clipped == 0) & valid).sum(),
        "out_of_range": ((scaled.abs() > limit) & valid).sum(),
        "saturated": ((rounded.abs() > limit) & valid).sum(),
        "nonfinite": torch.zeros((), device=absorbed.device, dtype=torch.int64),
        "abs_error_sum": (decoded_error * valid).sum(),
        "squared_error_sum": (decoded_error.square() * valid).sum(),
        "max_abs_error": (decoded_error * valid).amax(),
    }
    dtype = torch.int8 if not lossless and config.flattened_bits <= 8 else torch.int16
    return MX9Tensor(clipped.to(dtype), x.outer_exp, None, x.shape, x.axis,
                     stats, fractional_bits)


def dequantize(x: MX9Tensor, dtype: torch.dtype = torch.float32) -> torch.Tensor:
    exp = x.outer_exp.to(torch.int32) - x.fractional_bits
    if x.micro_exp is not None:
        exp = exp + x.micro_exp.repeat_interleave(2, -1)
    values = torch.ldexp(x.elements.to(torch.float64), exp)
    length = x.shape[x.axis]
    moved_shape = list(x.shape)
    moved_shape.pop(x.axis)
    values = values.reshape(*moved_shape, -1)[..., :length]
    return values.movedim(-1, x.axis).to(dtype)


def reference_matmul(a: MX9Tensor, b: MX9Tensor) -> torch.Tensor:
    """Slow independent blockwise FP64 reference for 2-D operands."""
    left, right = dequantize(a, torch.float64), dequantize(b, torch.float64)
    if left.ndim != 2 or right.ndim != 2 or left.shape[1] != right.shape[0]:
        raise ValueError("Expected compatible 2-D matrices")
    out = torch.zeros((left.shape[0], right.shape[1]), dtype=torch.float64,
                      device=left.device)
    for start in range(0, left.shape[1], 16):
        for k in range(start, min(start + 16, left.shape[1])):
            out += left[:, k, None] * right[k, None, :]
    return out
