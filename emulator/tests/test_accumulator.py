import pytest
import torch

from avant_garde.inference import MX9Inference
from avant_garde.mx9 import quantize_mx9
from avant_garde.tensor_core import ACCUMULATORS, figure8_mma, round_accumulator


def test_fp32_accumulator_is_unchanged():
    a, b = quantize_mx9(torch.randn(5, 48)), quantize_mx9(torch.randn(48, 3), -2)
    torch.testing.assert_close(figure8_mma(a, b, accumulator="fp32"), figure8_mma(a, b), rtol=0, atol=0)


def test_mantissa_rounding_keeps_15_significant_bits():
    x = torch.tensor([1 + 2**-14, 1 + 2**-15, 1 + 3 * 2**-16, -(1 + 2**-14), 3.0, 0.0])
    y = round_accumulator(x, "fp32-m14")
    # 1 + 2**-14 is representable; 1 + 2**-15 is a tie and rounds to even (1.0);
    # 1 + 3*2**-16 rounds up to 1 + 2**-14.
    torch.testing.assert_close(y, torch.tensor([1 + 2**-14, 1.0, 1 + 2**-14, -(1 + 2**-14), 3.0, 0.0]),
                               rtol=0, atol=0)


@pytest.mark.parametrize("accumulator", ["bf16", "fp16", "fp32-m14"])
def test_reduced_accumulator_matches_scalar_reference(accumulator):
    torch.manual_seed(0)
    a, b = quantize_mx9(torch.randn(3, 64)), quantize_mx9(torch.randn(64, 2), -2)
    exact = figure8_mma(a, b)
    actual = figure8_mma(a, b, accumulator=accumulator)
    # Independent loop: per block, round the scaled partial sum, add, round again.
    da = a.elements.double() * torch.ldexp(torch.ones_like(a.elements.double()),
                                           (a.outer_exp + a.micro_exp.repeat_interleave(2, -1)).int())
    db = b.elements.double() * torch.ldexp(torch.ones_like(b.elements.double()),
                                           (b.outer_exp + b.micro_exp.repeat_interleave(2, -1)).int())
    ref = torch.zeros(3, 2)
    for k in range(4):
        part = (da[:, k, :] @ db[:, k, :].T).float()
        ref = round_accumulator(ref + round_accumulator(part, accumulator), accumulator)
    torch.testing.assert_close(actual, ref, rtol=0, atol=0)
    assert not torch.equal(actual, exact) or accumulator == "fp32"


def test_accumulator_reaches_adapter_and_report():
    model = torch.nn.Linear(40, 6).eval()
    x = torch.randn(4, 40)
    outs = {}
    for acc in ACCUMULATORS:
        adapter = MX9Inference(model, "mx9_hierarchical", activation_policy="fp32", accumulator=acc)
        with adapter.apply():
            outs[acc] = model(x)
        assert adapter.report()["accumulator_dtype"].startswith({"fp32": "float32", "bf16": "bfloat16",
                                                                  "fp16": "float16", "fp32-m14": "float32"}[acc])
    assert not torch.equal(outs["bf16"], outs["fp32"])
    with pytest.raises(ValueError):
        MX9Inference(model, "mx9_hierarchical", backend="dequantized", accumulator="bf16")
    MX9Inference(model, "fp32", accumulator="bf16")  # FP32 reference ignores the setting
