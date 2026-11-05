import pytest
import torch
from transformers import (GPT2Config, GPT2LMHeadModel, ViTConfig,
                          ViTForImageClassification)

from avant_garde.inference import MX9Inference, configure_fp32
from avant_garde.mx9 import MODES, dequantize, quantize_mx9


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
    expected = torch.nn.functional.linear(dequantize(quantize_mx9(x)),
                                            dequantize(quantize_mx9(model.weight)), model.bias)
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
