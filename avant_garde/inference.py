"""Scoped ATen adapters for eager GPT-2 and ViT inference.

Dispatch is disabled inside __torch_dispatch__, so emulation operations cannot
recursively quantize themselves. Original model parameters are never replaced.
"""
import re
from collections import Counter
from contextlib import contextmanager
from dataclasses import asdict

import torch
import torch.nn.functional as F
from torch.utils._python_dispatch import TorchDispatchMode

from .mx9 import (MODES, MXINT_BLOCKS, MX9Config, quantize_mx9, quantize_mxint8,
                  flatten_mx9, dequantize)


class MX9Inference(TorchDispatchMode):
    CHUNK_ELEMENTS = 1 << 25
    FAMILIES = ("gpt2", "vit", "qwen3", "qwen3_moe")
    # Products inside these modules are not tensor-core operand GEMMs (Qwen3's RoPE
    # computes inv_freq @ positions); they stay in FP32 and are not counted.
    FP32_MODULES = re.compile(r"rotary_emb")
    def __init__(self, model, mode="mx9_flattened", config=MX9Config(),
                 weights_only=False, exempt=None, exempt_mode="mx9_hierarchical",
                 cache_weights=True):
        super().__init__()
        if mode not in MODES or exempt_mode not in MODES:
            raise ValueError(f"Unknown mode {mode}")
        # Modules whose name matches `exempt` use `exempt_mode` (layer fallback, H1.1).
        self.exempt = re.compile(exempt) if exempt else None
        self.exempt_mode = exempt_mode
        self.exempted = Counter()
        self.model, self.mode, self.config = model, mode, config
        self.weights_only = weights_only
        self.weights = {p.untyped_storage().data_ptr(): name
                        for name, p in model.named_parameters()}
        self.cache = {}
        # Without the cache, weights are re-quantized on every use (same values, less memory).
        self.cache_weights = cache_weights
        self.converted_weights = 0
        self.stats = {}
        self.coverage = Counter()
        self.stack = []

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
        layer = self.stack[-1] if self.stack else "<root>"
        mode = self.mode
        if self.exempt is not None and self.exempt.search(layer):
            mode = self.exempt_mode
            self.exempted[layer] += 1
        if mode == "fp32" or (self.weights_only and not is_weight):
            return x
        label = weight_name if is_weight and weight_name else layer
        label = f"{label}:{'weight' if is_weight else 'activation'}:axis={axis}"
        # A transposed view needs a distinct reduction-axis quantization.
        cache_key = (ptr, x.storage_offset(), tuple(x.shape), tuple(x.stride()),
                     axis, x._version, mode) if is_weight else None
        if is_weight and self.cache_weights and cache_key in self.cache:
            return self.cache[cache_key]
        result = self._convert(x, axis, mode, label)
        if is_weight:
            self.converted_weights += 1
            if self.cache_weights:
                self.cache[cache_key] = result
        return result

    def _convert(self, x, axis, mode, label):
        """Quantize (and flatten) then dequantize; chunk very large operands.

        Blocks run along `axis` only, so splitting along another dimension is exact.
        It bounds the FP64 codec temporaries (e.g. a 152k-vocabulary LM head or
        long-context attention scores) to about CHUNK_ELEMENTS elements each.
        """
        axis %= x.ndim
        others = [d for d in range(x.ndim) if d != axis and x.shape[d] > 1]
        if x.numel() > self.CHUNK_ELEMENTS and others:
            dim = max(others, key=lambda d: x.shape[d])
            step = max(1, x.shape[dim] * self.CHUNK_ELEMENTS // x.numel())
            return torch.cat([self._convert(part, axis, mode, label)
                              for part in x.split(step, dim)], dim)
        if mode in MXINT_BLOCKS:
            q = quantize_mxint8(x, axis, MXINT_BLOCKS[mode], self.config.rounding)
        else:
            q = quantize_mx9(x, axis, self.config)
        self._record(label + ":quantize", q.stats)
        if mode in ("mx9_flattened", "mx9_lossless"):
            q = flatten_mx9(q, self.config, lossless=mode == "mx9_lossless")
            self._record(label + ":flatten", q.stats)
        return dequantize(q)

    def __torch_dispatch__(self, func, types, args=(), kwargs=None):
        kwargs = kwargs or {}
        name = str(func)
        if self.stack and self.FP32_MODULES.search(self.stack[-1]):
            return func(*args, **kwargs)
        if "scaled_dot_product" in name or "flash_attention" in name:
            raise RuntimeError("Fused attention bypasses MX9 operands; select eager attention")
        if name == "aten.linear.default":
            self.coverage[f"{self.stack[-1] if self.stack else '<root>'}:{name}"] += 1
            x, w = args[:2]
            bias = args[2] if len(args) > 2 else None
            return F.linear(self._operand(x, -1), self._operand(w, -1, role="weight"), bias)
        if name in ("aten.mm.default", "aten.bmm.default", "aten.matmul.default"):
            self.coverage[f"{self.stack[-1] if self.stack else '<root>'}:{name}"] += 1
            a, b = args[:2]
            return func(self._operand(a, -1), self._operand(b, -2), **kwargs)
        if name in ("aten.addmm.default", "aten.baddbmm.default"):
            self.coverage[f"{self.stack[-1] if self.stack else '<root>'}:{name}"] += 1
            bias, a, b = args[:3]
            return func(bias, self._operand(a, -1), self._operand(b, -2), **kwargs)
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
            matrix = self._operand(w.flatten(1), -1, role="weight")
            result = self._operand(patches, -1) @ matrix.T
            if bias is not None:
                result = result + bias
            height = (x.shape[2] + 2 * padding[0] - dilation[0] * (w.shape[2] - 1) - 1) // stride[0] + 1
            width = (x.shape[3] + 2 * padding[1] - dilation[1] * (w.shape[3] - 1) - 1) // stride[1] + 1
            return result.transpose(1, 2).reshape(x.shape[0], w.shape[0], height, width)
        return func(*args, **kwargs)

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
            self.stack.pop()
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
            "exempt": self.exempt.pattern if self.exempt else None,
            "exempt_mode": self.exempt_mode, "exempted_calls": dict(self.exempted),
            "coverage": dict(self.coverage),
            "diagnostics": {key: {name: value.item() for name, value in stats.items()}
                            for key, stats in self.stats.items()},
            "cached_weight_views": len(self.cache),
            "converted_weight_views": self.converted_weights,
        }

    def check_coverage(self, forwards):
        """Fail if a new backend silently bypasses expected attention operands."""
        family = getattr(self.model.config, "model_type", None)
        if family not in self.FAMILIES:
            raise ValueError(f"Coverage validation supports {', '.join(self.FAMILIES)} only")
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
        if self.mode != "fp32" and not self.converted_weights:
            raise RuntimeError("No weights were quantized")


def configure_fp32():
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    torch.set_float32_matmul_precision("highest")
