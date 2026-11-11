"""Independent scalar oracles and adversarial tests for Figures 7 and 8."""
import math
import os
from dataclasses import replace

import numpy as np
import pytest
import torch

from avant_garde.mx9 import (MX9Config, MX9Tensor, dequantize, flatten_mx9,
                             operand_transform, quantize_mx9, unflatten_mx9)
from avant_garde.tensor_core import combine_exponents, figure8_mma


def packed(codes, exponents, *, right=False):
    codes = torch.tensor(codes, dtype=torch.int8).reshape(1, -1, 16)
    return MX9Tensor(codes, torch.tensor(exponents, dtype=torch.int16).reshape(1, -1, 1),
                     None, (codes.numel(), 1) if right else (1, codes.numel()),
                     0 if right else 1, {})


@pytest.mark.parametrize("rounding", ["even", "nearest", "trunc"])
def test_figure7_every_signed_code_and_pair(rounding):
    # Exhaust every MX9 code in every position and both scale states. Distinct
    # neighboring pair scales catch an incorrect repeat rather than interleave.
    codes = torch.arange(-127, 128).reshape(-1, 1, 1).expand(-1, 2, 16).to(torch.int8)
    micro = torch.tensor([[0, -1] * 4, [-1, 0] * 4], dtype=torch.int8).expand(255, -1, -1)
    q = MX9Tensor(codes, torch.zeros(255, 2, 1, dtype=torch.int16), micro, (255, 32), 1, {})
    expected = np.empty((255, 2, 16))
    for row in range(255):
        for block in range(2):
            for pair in range(8):
                for element in (2 * pair, 2 * pair + 1):
                    expected[row, block, element] = (row - 127) * 2.0 ** int(micro[row, block, pair])
    torch.testing.assert_close(operand_transform(q), torch.from_numpy(expected), rtol=0, atol=0)
    rounded = (np.rint(expected) if rounding == "even" else np.trunc(expected) if rounding == "trunc"
               else np.sign(expected) * np.floor(np.abs(expected) + .5))
    flat = flatten_mx9(q, MX9Config(flatten_rounding=rounding))
    np.testing.assert_array_equal(flat.elements.numpy(), rounded)
    torch.testing.assert_close(flat.outer_exp, q.outer_exp)
    np.testing.assert_array_equal(flatten_mx9(q, lossless=True).elements.numpy(), expected * 2)


def scalar_oracle(a, b, c):
    # Decode ONLY mantissas, retaining the scale until after each 16-way dot.
    out = np.empty((a.shape[0], b.shape[1]), dtype=np.float32)
    for i in range(a.shape[0]):
        for j in range(b.shape[1]):
            acc = np.float32(c[j])
            for block in range(a.elements.shape[-2]):
                dot = 0.0
                for k in range(16):
                    am = int(a.micro_exp[i, block, k // 2]) if a.micro_exp is not None else -a.fractional_bits
                    bm = int(b.micro_exp[j, block, k // 2]) if b.micro_exp is not None else -b.fractional_bits
                    dot += int(a.elements[i, block, k]) * int(b.elements[j, block, k]) * 2.0 ** (am + bm)
                exponent = int(a.outer_exp[i, block, 0]) + int(b.outer_exp[j, block, 0])
                acc = np.float32(acc + np.float32(math.ldexp(dot, exponent)))
            out[i, j] = acc
    return torch.from_numpy(out)


@pytest.mark.parametrize("kind", ["hierarchical", "flattened", "lossless"])
def test_figure8_against_scalar_oracle_noncontiguous_padding_bias(kind):
    torch.manual_seed(91)
    a = quantize_mx9(torch.randn(35, 3).T)
    b = quantize_mx9(torch.randn(4, 35).T, -2)
    if kind != "hierarchical":
        a, b = (flatten_mx9(q, lossless=kind == "lossless") for q in (a, b))
    c = torch.randn(4)
    torch.testing.assert_close(figure8_mma(a, b, c), scalar_oracle(a, b, c), rtol=0, atol=0)


def test_broadcast_and_lossless_control():
    torch.manual_seed(92)
    a = quantize_mx9(torch.randn(2, 1, 3, 33))
    b = quantize_mx9(torch.randn(1, 4, 33, 5), -2)
    result = figure8_mma(a, b)
    assert result.shape == (2, 4, 3, 5)
    torch.testing.assert_close(result, figure8_mma(flatten_mx9(a, lossless=True),
                                                 flatten_mx9(b, lossless=True)), rtol=0, atol=0)
    for i in range(2):
        for j in range(4):
            qa = quantize_mx9(dequantize(a)[i, 0])
            qb = quantize_mx9(dequantize(b)[0, j], -2)
            torch.testing.assert_close(result[i, j], scalar_oracle(qa, qb, torch.zeros(5)), rtol=0, atol=0)


def test_pipeline_rounding_and_initial_c():
    # +2**24, +1, -2**24: ordered FP32 accumulation loses the middle 1.
    a = packed([1] + [0]*15 + [1] + [0]*15 + [-1] + [0]*15, [24, 0, 24])
    b = packed([1] + [0]*15 + [1] + [0]*15 + [1] + [0]*15, [0, 0, 0], right=True)
    assert figure8_mma(a, b).item() == 0
    assert (dequantize(a, torch.float64) @ dequantize(b, torch.float64)).item() == 1
    # C belongs in the pipeline before block accumulation, not a bias epilogue.
    a = packed([-1] + [0]*15 + [1] + [0]*15, [24, 0])
    b = packed([1] + [0]*15 + [1] + [0]*15, [0, 0], right=True)
    assert figure8_mma(a, b, torch.tensor(2.0**24)).item() == 1
    a.elements[0, 0, 0] = 1
    a.elements[0, 1, 0] = -1
    a.outer_exp[0, 1, 0] = 24
    assert figure8_mma(a, b, torch.tensor(1.0)).item() == 0
    assert (figure8_mma(a, b) + 1).item() == 1


def test_scaling_after_dot_cancellation_and_subnormal():
    a = packed([1, -1] + [0]*14, [100])
    b = packed([1, 1] + [0]*14, [100], right=True)
    assert figure8_mma(a, b, exponent_overflow="wide").item() == 0
    assert not torch.isfinite(dequantize(a) @ dequantize(b)).all()
    a = packed([1]*16, [-75])
    b = packed([1]*16, [-75], right=True)
    assert figure8_mma(a, b, exponent_overflow="wide").item() == 2.0**-146
    assert ((dequantize(a).flatten() * dequantize(b).flatten()).sum()).item() == 0


def test_exponent_adder_overflow_is_explicit():
    a, b = torch.tensor([-128, 127, 100]), torch.tensor([-1, 1, 100])
    with pytest.raises(OverflowError):
        combine_exponents(a, b)
    assert combine_exponents(a, b, "wrap").tolist() == [127, -128, -56]
    assert combine_exponents(a, b, "wide").tolist() == [-129, 128, 200]
    qa = packed([1] + [0]*15, [100])
    qb = packed([1] + [0]*15, [100], right=True)
    with pytest.raises(OverflowError):
        figure8_mma(qa, qb, exponent_overflow="error")
    assert figure8_mma(qa, qb, exponent_overflow="wrap").item() == 2.0**-56
    assert torch.isinf(figure8_mma(qa, qb, exponent_overflow="wide")).all()


def test_small_probability_products_use_wide_internal_exponents_by_default():
    # These are valid finite operands. Internal exponents include fixed-point
    # radix offsets and their sum may lie outside int8 even for a normal output.
    qa = packed([64] + [0]*15, [-120])
    qb = packed([64] + [0]*15, [-10], right=True)
    assert figure8_mma(qa, qb).item() == 2.0**-118
    with pytest.raises(OverflowError):
        figure8_mma(qa, qb, exponent_overflow="error")


@pytest.mark.skipif(os.environ.get("AVANT_GARDE_TEST_CUDA") != "1",
                    reason="GPU checks run only in the Slurm smoke job")
def test_cuda_matches_cpu():
    assert torch.cuda.is_available()
    def cuda(q):
        return replace(q, elements=q.elements.cuda(), outer_exp=q.outer_exp.cuda(),
                       micro_exp=q.micro_exp.cuda() if q.micro_exp is not None else None)
    torch.manual_seed(17)
    a, b = quantize_mx9(torch.randn(2, 3, 35)), quantize_mx9(torch.randn(2, 35, 5), -2)
    for lossless in (None, False, True):
        qa, qb = (a, b) if lossless is None else (flatten_mx9(q, lossless=lossless) for q in (a, b))
        c = torch.randn(5)
        torch.testing.assert_close(figure8_mma(cuda(qa), cuda(qb), c.cuda()).cpu(),
                                   figure8_mma(qa, qb, c), rtol=0, atol=0)
        if lossless is None:
            torch.testing.assert_close(operand_transform(cuda(a)).cpu(), operand_transform(a), rtol=0, atol=0)
        else:
            rebuilt_gpu, rebuilt_cpu = unflatten_mx9(cuda(qa)), unflatten_mx9(qa)
            for field in ("elements", "outer_exp", "micro_exp"):
                torch.testing.assert_close(getattr(rebuilt_gpu, field).cpu(), getattr(rebuilt_cpu, field), rtol=0, atol=0)
    for exponent in (-75, 100):
        qa = packed([1]*16, [exponent])
        qb = packed([1]*16, [exponent], right=True)
        torch.testing.assert_close(figure8_mma(cuda(qa), cuda(qb), exponent_overflow="wide").cpu(),
                                   figure8_mma(qa, qb, exponent_overflow="wide"), rtol=0, atol=0)
