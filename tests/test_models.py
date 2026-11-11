import pytest
import torch
from transformers import (GPT2Config, GPT2LMHeadModel, ViTConfig,
                          ViTForImageClassification)

from avant_garde.inference import MX9Inference, configure_fp32
from avant_garde.mx9 import MODES, dequantize, quantize_mx9
from avant_garde.tensor_core import figure8_mma


@pytest.fixture(autouse=True)
def deterministic():
    configure_fp32()
    torch.manual_seed(0)
    torch.set_num_threads(2)


def make_model(family):
    if family == "gpt2":
        config = GPT2Config(vocab_size=41, n_positions=32, n_embd=24, n_layer=2,
                            n_head=3, attn_implementation="eager")
        return GPT2LMHeadModel(config).eval(), {"input_ids": torch.randint(0, 41, (2, 17)),
                                               "use_cache": False}
    config = ViTConfig(image_size=16, patch_size=4, hidden_size=24,
                       num_hidden_layers=2, num_attention_heads=3,
                       intermediate_size=48, num_labels=7, attn_implementation="eager")
    return ViTForImageClassification(config).eval(), {"pixel_values": torch.randn(2, 3, 16, 16)}


@pytest.mark.parametrize("family", ["gpt2", "vit"])
def test_model_parity_coverage_and_unchanged_parameters(family):
    model, inputs = make_model(family)
    before = {name: p.clone() for name, p in model.named_parameters()}
    with torch.inference_mode():
        baseline = model(**inputs).logits
    outputs = {}
    for mode in MODES:
        adapter = MX9Inference(model, mode)
        with adapter.apply():
            result = model(**inputs).logits
            repeated = model(**inputs).logits
        torch.testing.assert_close(result, repeated, rtol=0, atol=0)
        assert torch.isfinite(result).all()
        outputs[mode] = result
        report = adapter.report()
        adapter.check_coverage(2)
        coverage = report["coverage"]
        assert sum(n for key, n in coverage.items()
                   if "aten.bmm" in key or "aten.matmul" in key) == 8
        if family == "vit":
            assert any("projection:aten.conv" in key for key in coverage)
            assert any("query:aten.addmm" in key or "query:aten.linear" in key for key in coverage)
        else:
            assert any("c_attn:aten.addmm" in key for key in coverage)
            assert model.lm_head.weight is model.transformer.wte.weight
            assert any("lm_head:aten.mm" in key or "lm_head:aten.linear" in key for key in coverage)
        if mode != "fp32":
            assert report["cached_weight_views"] > 0
            diagnostics = report["diagnostics"]
            assert any(":activation:" in key for key in diagnostics)
            assert any(":weight:" in key for key in diagnostics)
            if mode == "mx9_flattened":
                assert sum(s["out_of_range"] for key, s in diagnostics.items() if key.endswith(":flatten")) == 0
    torch.testing.assert_close(outputs["fp32"], baseline, rtol=0, atol=0)
    torch.testing.assert_close(outputs["mx9_hierarchical"], outputs["mx9_lossless"], rtol=0, atol=0)
    assert not torch.equal(outputs["fp32"], outputs["mx9_flattened"])
    for name, p in model.named_parameters():
        torch.testing.assert_close(p, before[name], rtol=0, atol=0)
    assert not any(m._forward_hooks or m._forward_pre_hooks for m in model.modules())


def test_linear_matches_manual_quantization_and_weight_cache():
    model = torch.nn.Linear(19, 7).eval()
    x = torch.randn(3, 19)
    expected = figure8_mma(quantize_mx9(x), quantize_mx9(model.weight.T, -2), model.bias)
    expected = dequantize(quantize_mx9(expected))
    adapter = MX9Inference(model, "mx9_hierarchical")
    with adapter.apply():
        result = model(x)
        model(x)
    torch.testing.assert_close(result, expected, rtol=0, atol=0)
    records = adapter.report()["diagnostics"]
    assert sum(s["elements"] for k, s in records.items() if ":weight:" in k) == model.weight.numel()


def test_weights_only_and_hook_cleanup_after_error():
    model, inputs = make_model("gpt2")
    adapter = MX9Inference(model, weights_only=True)
    with adapter.apply():
        model(**inputs)
    assert all(":activation:" not in key for key in adapter.report()["diagnostics"])
    with pytest.raises(RuntimeError, match="intentional"):
        with MX9Inference(model).apply():
            raise RuntimeError("intentional")
    assert not any(m._forward_hooks or m._forward_pre_hooks for m in model.modules())


def test_training_rejected():
    with pytest.raises(ValueError, match="eval"):
        with MX9Inference(torch.nn.Linear(2, 2)).apply():
            pass


def test_legacy_backend_and_effective_backend_reports():
    model = torch.nn.Linear(19, 7).eval()
    x = torch.randn(3, 19)
    expected = torch.nn.functional.linear(dequantize(quantize_mx9(x)),
                                          dequantize(quantize_mx9(model.weight)), model.bias)
    adapter = MX9Inference(model, "mx9_hierarchical", backend="dequantized", activation_policy="fp32")
    with adapter.apply():
        actual = model(x)
    torch.testing.assert_close(actual, expected, rtol=0, atol=0)
    assert adapter.report()["numerical_backend"] == "dequantized"
    assert MX9Inference(model, weights_only=True).report()["numerical_backend"] == "dequantized"
    assert MX9Inference(model, "fp32").report()["numerical_backend"] == "native_fp32"
    assert MX9Inference(model).report()["numerical_contract"] == "figure7-8-mx9-v2"


@pytest.mark.parametrize("batched", [False, True])
@pytest.mark.parametrize("alpha,beta", [(1, 1), (1, 0), (2, .5)])
def test_dispatch_addmm_bias_and_blas_scalars(batched, alpha, beta):
    model = torch.nn.Identity().eval()
    a = torch.randn((2, 3, 35) if batched else (3, 35))
    b = torch.randn((2, 35, 4) if batched else (35, 4))
    bias = torch.full((4,), float("nan")) if beta == 0 else torch.randn(4)
    qa, qb = quantize_mx9(a), quantize_mx9(b, -2)
    if alpha == 1:
        expected = figure8_mma(qa, qb, bias * beta if beta else None)
    else:
        expected = figure8_mma(qa, qb) * alpha + bias * beta
    adapter = MX9Inference(model, "mx9_hierarchical", activation_policy="fp32")
    with adapter.apply():
        result = (torch.baddbmm if batched else torch.addmm)(bias, a, b, alpha=alpha, beta=beta)
    torch.testing.assert_close(result, expected, rtol=0, atol=0)
