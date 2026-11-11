"""Boundary semantics for decoded hierarchical MX9 activation storage."""
import pytest
import torch
from transformers.activations import NewGELUActivation

from avant_garde.inference import MX9Inference
from avant_garde.mx9 import MX9Config, MX9Tensor, dequantize, flatten_mx9, quantize_mx9, unflatten_mx9
from avant_garde.tensor_core import figure8_mma


@pytest.fixture(autouse=True)
def cpu_threads():
    torch.set_num_threads(2)


def hierarchical(x, axis=-1):
    return dequantize(quantize_mx9(x, axis))


def test_signed_shift_and_separate_rounding_settings():
    q = quantize_mx9(torch.tensor([1., 0., 3/128, -3/128, 5/128, -5/128]))
    assert MX9Config().rounding == "even"
    assert MX9Config().flatten_rounding == "trunc"
    flat = flatten_mx9(q)
    assert flat.elements.flatten()[2:6].tolist() == [1, -1, 2, -2]
    # Changing flattening rounding does not change initial MX9 conversion.
    even = MX9Config(flatten_rounding="even")
    torch.testing.assert_close(q.elements, quantize_mx9(dequantize(q), config=even).elements)
    assert flatten_mx9(q, even).elements.flatten()[2:4].tolist() == [2, -2]


def test_unflatten_rebuilds_scales_without_restoring_lost_bits():
    original = quantize_mx9(torch.tensor([1., 0., 3/128, -3/128]))
    flat = flatten_mx9(original)
    rebuilt = unflatten_mx9(flat)
    assert rebuilt.micro_exp is not None
    torch.testing.assert_close(dequantize(rebuilt), dequantize(flat), rtol=0, atol=0)
    assert not torch.equal(dequantize(rebuilt), dequantize(original))
    # Input storage scale need not be the normalized hierarchical output scale.
    sparse = MX9Tensor(torch.tensor([[[1] + [0]*15]], dtype=torch.int8),
                       torch.tensor([[[5]]], dtype=torch.int16), None, (1, 16), 1, {})
    rebuilt = unflatten_mx9(sparse)
    assert rebuilt.outer_exp.item() == -1
    assert rebuilt.elements[0, 0, 0].item() == 64
    torch.testing.assert_close(dequantize(rebuilt), dequantize(sparse), rtol=0, atol=0)
    with pytest.raises(ValueError, match="flattened"):
        unflatten_mx9(original)


@pytest.mark.parametrize("module,boundary", [
    (torch.nn.LayerNorm(19), "LayerNorm"),
    (torch.nn.GELU(), "gelu"),
    (NewGELUActivation(), "gelu"),
])
def test_non_gemm_operations_use_fp32_then_hierarchical_storage(module, boundary):
    torch.manual_seed(5)
    module.eval()
    x = hierarchical(torch.randn(2, 19))
    with torch.inference_mode():
        expected = hierarchical(module(x))
    adapter = MX9Inference(module)
    with adapter.apply():
        actual = module(x)
    torch.testing.assert_close(actual, expected, rtol=0, atol=0)
    assert adapter.activation_events == {boundary: 1}
    assert not any(key.endswith(":flatten") for key in adapter.report()["diagnostics"])


def test_masked_softmax_preserves_control_masks_and_stores_mx9_probabilities():
    x = hierarchical(torch.tensor([[1., 2., 3., 4.]]))
    x[0, 2:] = -float("inf")
    expected = hierarchical(torch.softmax(x, -1))
    adapter = MX9Inference(torch.nn.Identity().eval())
    with adapter.apply():
        actual = torch.softmax(x, -1)
    torch.testing.assert_close(actual, expected, rtol=0, atol=0)
    assert actual[0, 2:].tolist() == [0., 0.]
    assert adapter.activation_events == {"softmax": 1}


def test_linear_gelu_linear_pipeline_matches_explicit_boundary_reference():
    torch.manual_seed(6)
    model = torch.nn.Sequential(torch.nn.Linear(19, 23), NewGELUActivation(),
                                torch.nn.Linear(23, 7)).eval()
    x = torch.randn(3, 19)
    def product(x, layer):
        a = flatten_mx9(quantize_mx9(x))
        b = flatten_mx9(quantize_mx9(layer.weight.T, -2))
        return hierarchical(figure8_mma(a, b, layer.bias))
    with torch.inference_mode():
        expected = product(hierarchical(model[1](product(x, model[0]))), model[2])
    adapter = MX9Inference(model)
    with adapter.apply():
        actual = model(x)
    torch.testing.assert_close(actual, expected, rtol=0, atol=0)
    assert adapter.activation_events == {"matrix_output": 2, "gelu": 1}


def test_old_fp32_activation_policy_remains_available():
    torch.manual_seed(7)
    model = torch.nn.Linear(19, 7).eval()
    x = torch.randn(2, 19)
    expected = figure8_mma(flatten_mx9(quantize_mx9(x)),
                           flatten_mx9(quantize_mx9(model.weight.T, -2)), model.bias)
    adapter = MX9Inference(model, activation_policy="fp32")
    with adapter.apply():
        actual = model(x)
    torch.testing.assert_close(actual, expected, rtol=0, atol=0)
    assert adapter.activation_events == {}
