"""H3: how much of a Qwen3-8B prefill layer would Avant-Garde not accelerate?

Times one real decoder layer (BF16 weights, native CUDA kernels, CUDA events,
median of repeats) at the given sequence lengths, split into
  projection GEMMs  q/k/v/o, gate/up/down          (accelerated by Avant-Garde)
  attention GEMMs   Q K^T and P V                  (accelerated if MX operands)
  softmax           incl. causal mask and FP32 upcast
  other             RMSNorms (incl. q/k norms), RoPE, SiLU*up, residual adds
Attention is computed per query chunk so that 32k tokens fit in memory; the
chunks add up to exactly the full causal attention.

Then evaluates the proposal's bound S = 1 / (f + (1 - f) / s), where f is the
time fraction Avant-Garde leaves unchanged and s the speedup of the rest, for
two cases: only projection GEMMs accelerated, and attention GEMMs as well.
Times are for BF16 GEMMs; an MX baseline changes the GEMM share, so the
script also reports f with GEMM time scaled by --gemm-scale factors.
"""
import argparse
import json
import statistics

import torch
from transformers import AutoModelForCausalLM


def timed(fn, repeats):
    times = []
    for _ in range(repeats + 2):           # two warm-up runs
        start, end = torch.cuda.Event(enable_timing=True), torch.cuda.Event(enable_timing=True)
        start.record()
        fn()
        end.record()
        torch.cuda.synchronize()
        times.append(start.elapsed_time(end))
    return statistics.median(times[2:])


def rope(x, cos, sin):
    half = x.shape[-1] // 2
    rotated = torch.cat((-x[..., half:], x[..., :half]), -1)
    return x * cos + rotated * sin


def profile(model, layer_index, seq, chunk, repeats, attention="eager"):
    layer = model.model.layers[layer_index]
    attn, mlp = layer.self_attn, layer.mlp
    cfg = model.config
    heads, kv_heads, hd = cfg.num_attention_heads, cfg.num_key_value_heads, cfg.head_dim
    dev, dt = "cuda", torch.bfloat16
    h = torch.randn(1, seq, cfg.hidden_size, device=dev, dtype=dt)
    pos = torch.arange(seq, device=dev)[None]
    cos, sin = model.model.rotary_emb(h, pos)
    cos, sin = cos[:, None], sin[:, None]
    t = {}
    with torch.inference_mode():
        x = layer.input_layernorm(h)
        t["other:input_norm"] = timed(lambda: layer.input_layernorm(h), repeats)
        t["proj:qkv"] = timed(lambda: (attn.q_proj(x), attn.k_proj(x), attn.v_proj(x)), repeats)
        q = attn.q_proj(x).view(1, seq, heads, hd).transpose(1, 2)
        k = attn.k_proj(x).view(1, seq, kv_heads, hd).transpose(1, 2)
        v = attn.v_proj(x).view(1, seq, kv_heads, hd).transpose(1, 2)
        t["other:qk_norm_rope"] = timed(lambda: (rope(attn.q_norm(q), cos, sin), rope(attn.k_norm(k), cos, sin)), repeats)
        q, k = rope(attn.q_norm(q), cos, sin), rope(attn.k_norm(k), cos, sin)
        rep = heads // kv_heads
        k, v = k.repeat_interleave(rep, 1), v.repeat_interleave(rep, 1)
        scale = hd ** -0.5
        out = torch.empty_like(q)
        if attention == "fused":
            # Fused attention (FlashAttention backend): Q K^T, softmax and P V in one
            # kernel, as in production serving; their split is not observable.
            sdpa = torch.nn.functional.scaled_dot_product_attention
            t["fused_attn"] = timed(lambda: sdpa(q, k, v, is_causal=True), repeats)
            out = sdpa(q, k, v, is_causal=True)
        else:
            t["attn:qk"] = t["softmax"] = t["attn:pv"] = 0.0
        for s0 in (range(0, seq, chunk) if attention == "eager" else ()):
            s1 = min(seq, s0 + chunk)
            qc, kc, vc = q[:, :, s0:s1], k[:, :, :s1], v[:, :, :s1]
            mask = torch.ones(s1 - s0, s1, device=dev, dtype=torch.bool).tril(s0)
            t["attn:qk"] += timed(lambda: qc @ kc.transpose(-1, -2), repeats)
            scores = (qc @ kc.transpose(-1, -2)) * scale
            def soft():
                return torch.softmax(scores.float().masked_fill(~mask, float("-inf")), -1).to(dt)
            t["softmax"] += timed(soft, repeats)
            probs = soft()
            t["attn:pv"] += timed(lambda: probs @ vc, repeats)
            out[:, :, s0:s1] = probs @ vc
            del scores, probs
        a = out.transpose(1, 2).reshape(1, seq, heads * hd)
        t["proj:o"] = timed(lambda: attn.o_proj(a), repeats)
        h2 = h + attn.o_proj(a)
        t["other:residual"] = 2 * timed(lambda: h + h2, repeats)
        y = layer.post_attention_layernorm(h2)
        t["other:post_norm"] = timed(lambda: layer.post_attention_layernorm(h2), repeats)
        t["proj:gate_up"] = timed(lambda: (mlp.gate_proj(y), mlp.up_proj(y)), repeats)
        g, u = mlp.gate_proj(y), mlp.up_proj(y)
        t["other:silu_mul"] = timed(lambda: mlp.act_fn(g) * u, repeats)
        z = mlp.act_fn(g) * u
        t["proj:down"] = timed(lambda: mlp.down_proj(z), repeats)
    return t


def bound(f, s):
    return 1 / (f + (1 - f) / s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="Qwen/Qwen3-8B")
    ap.add_argument("--layer", type=int, default=17)
    ap.add_argument("--seq", type=int, nargs="+", default=[8192, 32768])
    ap.add_argument("--chunk", type=int, default=2048)
    ap.add_argument("--attention", choices=("eager", "fused"), default="eager",
                    help="eager: Q K^T, softmax, P V timed separately; fused: one SDPA kernel")
    ap.add_argument("--repeats", type=int, default=5)
    ap.add_argument("--speedups", type=float, nargs="+", default=[1.66, 1.93, 3.96])
    ap.add_argument("--gemm-scale", type=float, nargs="+", default=[1.0, 0.5, 1.98],
                    help="GEMM time relative to BF16: 1 = BF16, 0.5 = INT8 at 2x peak, "
                         "1.98 = software-scaled MX9 (0.5 x 3.96 measured)")
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    torch.backends.cuda.matmul.allow_tf32 = False
    model = AutoModelForCausalLM.from_pretrained(args.model, local_files_only=True,
                                                 torch_dtype=torch.bfloat16).eval().cuda()
    report = {"model": args.model, "layer": args.layer, "chunk": args.chunk,
              "attention": args.attention, "results": {}}
    for seq in args.seq:
        t = profile(model, args.layer, seq, args.chunk, args.repeats, args.attention)
        groups = {g: sum(v for k, v in t.items() if k.startswith(g))
                  for g in ("proj", "attn", "softmax", "other", "fused_attn")}
        res = {"times_ms": t, "groups_ms": groups, "scenarios": {}}
        for gs in args.gemm_scale:
            proj, att = groups["proj"] * gs, groups["attn"] * gs
            # Fused attention cannot be split: count it as not accelerated in the
            # "projections" scenario and as fully accelerated (an upper bound) in
            # "projections+attention".
            att += groups["fused_attn"] * gs
            rest = groups["softmax"] + groups["other"]
            total = proj + att + rest
            for label, accel in (("projections", proj), ("projections+attention", proj + att)):
                f = 1 - accel / total
                res["scenarios"][f"gemm_scale={gs}/{label}"] = {
                    "f": f, **{f"S(s={s})": bound(f, s) for s in args.speedups}}
        report["results"][str(seq)] = res
        print(seq, json.dumps(groups), flush=True)
        for key, val in res["scenarios"].items():
            print(f"  {key:42s} f={val['f']:.3f} " +
                  " ".join(f"{k}={v:.2f}" for k, v in val.items() if k != "f"), flush=True)
        torch.cuda.empty_cache()
    json.dump(report, open(args.output, "w"), indent=1)


if __name__ == "__main__":
    main()
