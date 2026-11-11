"""Scoped ATen adapters for eager GPT-2 and ViT inference.

Dispatch is disabled inside __torch_dispatch__, so emulation operations cannot
recursively quantize themselves. Original model parameters are never replaced.
"""
from collections import Counter
from contextlib import contextmanager
from dataclasses import asdict

import torch
import torch.nn.functional as F
from torch.utils._python_dispatch import TorchDispatchMode

from .mx9 import MODES, MX9Config, quantize_mx9, flatten_mx9, dequantize, unflatten_mx9
from .tensor_core import EXPONENT_POLICIES, figure8_mma


class MX9Inference(TorchDispatchMode):
    def __init__(self, model, mode="mx9_flattened", config=MX9Config(),
                 weights_only=False, backend="figure8", exponent_overflow="wide",
                 activation_policy="hierarchical"):
        super().__init__()
        if mode not in MODES:
            raise ValueError(f"Unknown mode {mode}")
        self.model, self.mode, self.config = model, mode, config
        self.weights_only = weights_only
        if backend not in ("figure8", "dequantized") or exponent_overflow not in EXPONENT_POLICIES:
            raise ValueError("Unknown numerical backend or exponent overflow policy")
        self.requested_backend = backend
        # A weight-only experiment has ordinary FP32 activation operands and
        # cannot represent the scaled A/B interface in Figure 8.
        self.backend = "native_fp32" if mode == "fp32" else ("dequantized" if weights_only else backend)
        self.exponent_overflow = exponent_overflow
        if activation_policy not in ("hierarchical", "fp32"):
            raise ValueError("Unknown activation policy")
        self.activation_policy = "fp32" if mode == "fp32" or weights_only else activation_policy
        self.requested_activation_policy = activation_policy
        self.activation_events = Counter()
        self._in_conversion = False
        self.modules = dict(model.named_modules())
        self.weights = {p.untyped_storage().data_ptr(): name
                        for name, p in model.named_parameters()}
        self.cache = {}
        self.stats = {}
        self.coverage = Counter()
        self.stack = []

    def _activation(self, x, boundary, axis=-1):
        """Store a hierarchical activation, carried as exact decoded FP32 values.

        A plain tensor avoids changing the model's CUDA arithmetic. Only values
        representable by the selected MX9 quantizer cross this boundary.
        """
        if self.activation_policy != "hierarchical":
            return x
        if not isinstance(x, torch.Tensor) or not x.is_floating_point() or not x.numel():
            return x
        self._in_conversion = True
        try:
            q = unflatten_mx9(x, axis, self.config)
            layer = self.stack[-1] if self.stack else "<root>"
            key = f"{layer}:activation:{boundary}:axis={axis}"
            self._record(key + ":unflatten", q.stats)
            self.activation_events[boundary] += 1
            return dequantize(q)
        finally:
            self._in_conversion = False

    def _record(self, key, stats):
        if key not in self.stats:
            self.stats[key] = {k: v.detach().clone() for k, v in stats.items()}
        else:
            for name, value in stats.items():
                if name == "max_abs_error":
                    self.stats[key][name] = torch.maximum(self.stats[key][name], value)
                else:
                    self.stats[key][name] += value

    def _operand(self, x, axis, role=None):
        ptr = x.untyped_storage().data_ptr()
        weight_name = self.weights.get(ptr)
        is_weight = role == "weight" or weight_name is not None
        if self.mode == "fp32" or (self.weights_only and not is_weight):
            return x
        layer = self.stack[-1] if self.stack else "<root>"
        label = weight_name if is_weight and weight_name else layer
        label = f"{label}:{'weight' if is_weight else 'activation'}:axis={axis}"
        # A transposed view needs a distinct reduction-axis quantization.
        cache_key = (ptr, x.storage_offset(), tuple(x.shape), tuple(x.stride()),
                     axis, x._version) if is_weight else None
        if is_weight and cache_key in self.cache:
            return self.cache[cache_key]
        q = quantize_mx9(x, axis, self.config)
        self._record(label + ":quantize", q.stats)
        if self.mode in ("mx9_flattened", "mx9_lossless"):
            q = flatten_mx9(q, self.config, lossless=self.mode == "mx9_lossless")
            self._record(label + ":flatten", q.stats)
        result = q if self.backend == "figure8" else dequantize(q)
        if is_weight:
            self.cache[cache_key] = result
        return result

    def _product(self, a, b, bias=None, *, alpha=1, beta=1):
        if self.backend == "figure8":
            # Normal MMA initializes C before the K loop. General BLAS alpha
            # is an external epilogue; it is not part of the Figure 8 interface.
            initial = bias * beta if bias is not None and beta != 0 else None
            if alpha == 1:
                return figure8_mma(a, b, initial, exponent_overflow=self.exponent_overflow)
            result = figure8_mma(a, b, exponent_overflow=self.exponent_overflow) * alpha
            return result if initial is None else result + initial
        result = torch.matmul(a, b) * alpha
        return result if bias is None or beta == 0 else result + bias * beta

    def __torch_dispatch__(self, func, types, args=(), kwargs=None):
        kwargs = kwargs or {}
        if self._in_conversion:
            return func(*args, **kwargs)
        name = str(func)
        if "scaled_dot_product" in name or "flash_attention" in name:
            raise RuntimeError("Fused attention bypasses MX9 operands; select eager attention")
        if name == "aten.linear.default":
            self.coverage[f"{self.stack[-1] if self.stack else '<root>'}:{name}"] += 1
            x, w = args[:2]
            bias = args[2] if len(args) > 2 else None
            if self.backend != "figure8":
                result = F.linear(self._operand(x, -1), self._operand(w, -1, role="weight"), bias)
            else:
                result = self._product(self._operand(x, -1), self._operand(w.T, -2, role="weight"), bias)
            return self._activation(result, "matrix_output")
        if name in ("aten.mm.default", "aten.bmm.default", "aten.matmul.default"):
            self.coverage[f"{self.stack[-1] if self.stack else '<root>'}:{name}"] += 1
            a, b = args[:2]
            a, b = self._operand(a, -1), self._operand(b, -2)
            result = self._product(a, b) if self.backend == "figure8" else func(a, b, **kwargs)
            return self._activation(result, "matrix_output")
        if name in ("aten.addmm.default", "aten.baddbmm.default"):
            self.coverage[f"{self.stack[-1] if self.stack else '<root>'}:{name}"] += 1
            bias, a, b = args[:3]
            a, b = self._operand(a, -1), self._operand(b, -2)
            result = (self._product(a, b, bias, **kwargs) if self.backend == "figure8"
                      else func(bias, a, b, **kwargs))
            return self._activation(result, "matrix_output")
        if name in ("aten.convolution.default", "aten.conv2d.default"):
            self.coverage[f"{self.stack[-1] if self.stack else '<root>'}:{name}"] += 1
            if self.mode == "fp32":
                return func(*args, **kwargs)
            if name == "aten.conv2d.default":
                defaults = [None, [1, 1], [0, 0], [1, 1], 1]
                x, w = args[:2]
                bias, stride, padding, dilation, groups = list(args[2:]) + defaults[len(args) - 2:]
                transposed = False
            else:
                x, w, bias, stride, padding, dilation, transposed, output_padding, groups = args
            if x.ndim != 4 or transposed or groups != 1:
                raise ValueError("Only ordinary 2-D patch convolutions are supported")
            patches = F.unfold(x, w.shape[-2:], dilation, padding, stride).transpose(1, 2)
            matrix = self._operand(w.flatten(1).T, -2, role="weight")
            result = self._product(self._operand(patches, -1), matrix, bias)
            result = self._activation(result, "patch_output")
            height = (x.shape[2] + 2 * padding[0] - dilation[0] * (w.shape[2] - 1) - 1) // stride[0] + 1
            width = (x.shape[3] + 2 * padding[1] - dilation[1] * (w.shape[3] - 1) - 1) // stride[1] + 1
            return result.transpose(1, 2).reshape(x.shape[0], w.shape[0], height, width)
        result = func(*args, **kwargs)
        if name in ("aten._softmax.default", "aten.softmax.int"):
            # The masked logits remain FP32 control data inside softmax.
            # Quantize probabilities along their actual reduction dimension.
            return self._activation(result, "softmax", axis=args[1])
        if name == "aten.add.Tensor" and self.stack:
            # Explicit model residual/position boundaries. Do not quantize
            # attention-mask construction or the internal steps of GELU/norm.
            module = self.modules.get(self.stack[-1])
            if type(module).__name__ in ("GPT2Block", "GPT2Model", "ViTLayer", "ViTOutput", "ViTEmbeddings"):
                return self._activation(result, "residual_or_position_add")
        return result

    @contextmanager
    def apply(self):
        if self.model.training:
            raise ValueError("Call model.eval() before numerical inference")
        handles = []
        def pre(name):
            def hook(module, args):
                self.stack.append(name)
            return hook
        def post(module, args, output):
            if isinstance(module, (torch.nn.LayerNorm, torch.nn.Embedding)):
                output = self._activation(output, type(module).__name__)
            elif isinstance(module, torch.nn.GELU) or type(module).__name__ in (
                    "GELUActivation", "NewGELUActivation", "FastGELUActivation", "PytorchGELUTanh"):
                output = self._activation(output, "gelu")
            self.stack.pop()
            return output
        for name, module in self.model.named_modules():
            handles.append(module.register_forward_pre_hook(pre(name or "<root>")))
            handles.append(module.register_forward_hook(post, always_call=True))
        try:
            with torch.inference_mode(), self:
                yield self
        finally:
            for handle in handles:
                handle.remove()
            self.stack.clear()

    def report(self):
        return {
            "mode": self.mode, "config": asdict(self.config),
            "weights_only": self.weights_only,
            "numerical_backend": self.backend,
            "requested_backend": self.requested_backend,
            "numerical_contract": {"figure8": "figure7-8-mx9-v2", "native_fp32": "native-fp32-v1",
                                   "dequantized": "dequantized-gemm-v1"}[self.backend],
            "activation_policy": self.activation_policy,
            "requested_activation_policy": self.requested_activation_policy,
            "activation_contract": "hierarchical-boundaries-v1" if self.activation_policy == "hierarchical" else "fp32-between-gemms-v1",
            "activation_events": dict(self.activation_events),
            "exponent_overflow": self.exponent_overflow if self.backend == "figure8" else None,
            "accumulator_dtype": "float32",
            "coverage": dict(self.coverage),
            "diagnostics": {key: {name: value.item() for name, value in stats.items()}
                            for key, stats in self.stats.items()},
            "cached_weight_views": len(self.cache),
        }

    def check_coverage(self, forwards):
        """Fail if a new backend silently bypasses expected attention operands."""
        family = getattr(self.model.config, "model_type", None)
        if family not in ("gpt2", "vit"):
            raise ValueError("Coverage validation supports GPT-2 and ViT only")
        layers = self.model.config.num_hidden_layers
        attention_products = sum(count for key, count in self.coverage.items()
                                 if key.endswith(("aten.matmul.default", "aten.bmm.default",
                                                  "aten.baddbmm.default")))
        if attention_products != 2 * layers * forwards:
            raise RuntimeError(f"Incomplete attention coverage: {attention_products} products; "
                               f"expected {2 * layers * forwards}")
        if family == "vit":
            patches = sum(count for key, count in self.coverage.items()
                          if key.endswith(("aten.convolution.default", "aten.conv2d.default")))
            if patches != forwards:
                raise RuntimeError("Incomplete ViT patch projection coverage")
        if self.mode != "fp32" and not self.cache:
            raise RuntimeError("No weights were quantized")
        if self.activation_policy == "hierarchical":
            required = {"softmax": layers * forwards, "gelu": layers * forwards,
                        "LayerNorm": (2 * layers + 1) * forwards,
                        "residual_or_position_add": (2 * layers + 1) * forwards}
            if family == "vit":
                required["patch_output"] = forwards
            else:
                required["Embedding"] = 2 * forwards
            for boundary, expected in required.items():
                actual = self.activation_events[boundary]
                if actual != expected:
                    raise RuntimeError(f"Incomplete activation boundary {boundary}: {actual}; expected {expected}")


def configure_fp32():
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    torch.set_float32_matmul_precision("highest")
