import math

import pytest
import torch

from avant_garde.mx9 import (MX9Config, quantize_mx9, flatten_mx9,
                              dequantize, reference_matmul)


def scalar_reference(values, rounding="even"):
    def rnd(v):
        if rounding == "even":
            return round(v)
        if rounding == "nearest":
            return math.copysign(math.floor(abs(v) + .5), v)
        return math.trunc(v)
    result, flat = [], []
    for start in range(0, len(values), 16):
        block = values[start:start + 16]
        padded = block + [0.] * (16 - len(block))
        maximum = max(map(abs, padded))
        exponent = math.frexp(maximum)[1] - 1 if maximum else 0
        outer = max(-127, min(127, exponent - 6))
        for pair in range(0, 16, 2):
            pair_max = max(map(abs, padded[pair:pair + 2]))
            micro = -1 if not pair_max or math.frexp(pair_max)[1] - 1 < exponent else 0
            for value in padded[pair:pair + 2]:
                code = max(-127, min(127, rnd(math.ldexp(value, -outer - micro))))
                result.append(math.ldexp(code, outer + micro))
                flat.append(math.ldexp(rnd(math.ldexp(code, micro)), outer))
    return result[:len(values)], flat[:len(values)]


@pytest.mark.parametrize("rounding", ["even", "nearest", "trunc"])
def test_against_independent_scalar_reference(rounding):
    torch.manual_seed(1)
    x = torch.cat([torch.tensor([1.9999998807907104, -1.9999998807907104, 0., .015625]),
                   torch.randn(65)])
    expected, flattened = scalar_reference(x.tolist(), rounding)
    q = quantize_mx9(x, config=MX9Config(rounding))
    torch.testing.assert_close(dequantize(q), torch.tensor(expected), rtol=0, atol=0)
    torch.testing.assert_close(dequantize(flatten_mx9(q, MX9Config(rounding, flatten_rounding=rounding))),
                               torch.tensor(flattened), rtol=0, atol=0)


def test_micro_scales_and_rounding_loss_without_overflow():
    x = torch.zeros(16)
    x[:6] = torch.tensor([1., 0., 3 / 128, -3 / 128, 1 / 128, -1 / 128])
    q = quantize_mx9(x)
    assert q.outer_exp.item() == -6
    assert q.micro_exp[0, :3].tolist() == [0, -1, -1]
    flat = flatten_mx9(q)
    assert flat.stats["rounding_changed"].item() == 4
    assert flat.stats["rounded_to_zero"].item() == 2
    assert flat.stats["out_of_range"].item() == 0
    torch.testing.assert_close(dequantize(flat)[2:6], torch.tensor([1 / 64, -1 / 64, 0., 0.]))


@pytest.mark.parametrize("shape,axis", [((3, 35), -1), ((35, 3), 0), ((2, 7, 3), 1)])
def test_lossless_padding_axes_and_noncontiguous(shape, axis):
    x = torch.randn(shape).transpose(0, -1)
    q = quantize_mx9(x, axis)
    assert q.stats["elements"].item() == x.numel()
    lossless = flatten_mx9(q, lossless=True)
    torch.testing.assert_close(dequantize(q, torch.float64), dequantize(lossless, torch.float64),
                               rtol=0, atol=0)
    assert lossless.stats["rounding_changed"].item() == 0
    assert dequantize(q).shape == x.shape


def test_zero_boundaries_and_saturation():
    for x in [torch.zeros(17), torch.tensor([torch.finfo(torch.float32).tiny,
                                           torch.finfo(torch.float32).smallest_normal / 8388608,
                                           torch.finfo(torch.float32).max])]:
        q = quantize_mx9(x)
        assert torch.isfinite(dequantize(q)).all()
        assert q.elements.abs().max() <= 127
    q = quantize_mx9(torch.tensor([1.99999, -1.99999]))
    assert q.stats["saturated"].item() == 2
    assert q.elements.flatten()[:2].tolist() == [127, -127]
    narrow = flatten_mx9(q, MX9Config(flattened_bits=4))
    assert narrow.stats["saturated"].item() == 2
    assert narrow.elements.flatten()[:2].tolist() == [7, -7]


def test_subnormal_scale_boundary():
    x = torch.tensor([2. ** -149, -(2. ** -149)], dtype=torch.float32)
    q = quantize_mx9(x)
    assert q.stats["scale_clamped_blocks"].item() == 1
    assert q.stats["rounded_to_zero"].item() == 2


@pytest.mark.parametrize("value", [float("nan"), float("inf"), -float("inf")])
def test_nonfinite_rejected(value):
    with pytest.raises(ValueError, match="Nonfinite"):
        quantize_mx9(torch.tensor([value]))


def test_bad_inputs():
    for x in (torch.tensor(1.), torch.tensor([]), torch.tensor([1])):
        with pytest.raises(ValueError):
            quantize_mx9(x)
    with pytest.raises(ValueError):
        MX9Config(rounding="wrap")
    with pytest.raises(ValueError):
        quantize_mx9(torch.ones(3), axis=2)
    with pytest.raises(ValueError):
        flatten_mx9(flatten_mx9(quantize_mx9(torch.ones(2))))


@pytest.mark.parametrize("lossless", [False, True])
def test_blockwise_reference_matmul(lossless):
    a = flatten_mx9(quantize_mx9(torch.randn(3, 35), -1), lossless=lossless)
    b = flatten_mx9(quantize_mx9(torch.randn(35, 4), -2), lossless=lossless)
    expected = reference_matmul(a, b)
    actual = dequantize(a).double() @ dequantize(b).double()
    torch.testing.assert_close(actual, expected, rtol=0, atol=0)


@pytest.mark.parametrize("block_size", [16, 32])
@pytest.mark.parametrize("rounding", ["even", "nearest", "trunc"])
def test_mxint8_against_scalar_reference(block_size, rounding):
    from avant_garde.mx9 import quantize_mxint8
    torch.manual_seed(2)
    x = torch.cat([torch.tensor([1.9999998807907104, -0.75, 0., 3e-3]), torch.randn(71) * 4])
    rnd = {"even": round, "nearest": lambda v: math.copysign(math.floor(abs(v) + .5), v),
           "trunc": math.trunc}[rounding]
    expected = []
    values = x.tolist()
    for start in range(0, len(values), block_size):
        block = values[start:start + block_size]
        maximum = max(map(abs, block))
        outer = max(-127, min(127, (math.frexp(maximum)[1] - 1 if maximum else 0) - 6))
        expected += [math.ldexp(max(-127, min(127, rnd(math.ldexp(v, -outer)))), outer)
                     for v in block]
    q = quantize_mxint8(x, block_size=block_size, rounding=rounding)
    assert q.micro_exp is None
    assert dequantize(q, torch.float64).tolist() == expected


def test_mxint8_b16_matches_mx9_without_microexponents():
    from avant_garde.mx9 import quantize_mxint8
    # Every pair holds a value in the block's top binade, so all micro exponents are 0.
    x = (torch.rand(4, 64) + 1.) * torch.where(torch.rand(4, 64) < .5, -1., 1.)
    x[:, 1::2] *= torch.rand(4, 32)
    hierarchical = quantize_mx9(x)
    assert int(hierarchical.micro_exp.abs().sum()) == 0
    torch.testing.assert_close(dequantize(quantize_mxint8(x, block_size=16, rounding="even")),
                               dequantize(hierarchical), rtol=0, atol=0)
