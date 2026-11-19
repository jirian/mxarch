"""Capture real Qwen3-8B GEMM operand blocks as power-analysis stimuli.

Runs one Wikipedia window through Qwen3-8B, hooks the inputs of selected
linear layers, quantizes activations and weights to MX9 along the reduction
axis (the emulator's quantize_mx9), and writes block pairs in the same format
as gen_vectors.py. Each sequence holds consecutive reduction blocks of one
(token, output-channel) dot product, the order in which one dot-product lane
consumes them. Also reports how often real blocks use the finer microexponent.
"""
import argparse
import json

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from avant_garde.mx9 import quantize_mx9
from gen_vectors import ROUNDINGS, exact_dot, flat_dot, hexfield, mu_bits

LAYERS = (0, 17, 35)
PROJS = ("self_attn.q_proj", "self_attn.o_proj", "mlp.gate_proj", "mlp.down_proj")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="Qwen/Qwen3-8B")
    ap.add_argument("--text-file", required=True)
    ap.add_argument("--context", type=int, default=512)
    ap.add_argument("--sequences", type=int, default=16, help="per layer")
    ap.add_argument("--blocks", type=int, default=32, help="consecutive blocks per sequence")
    ap.add_argument("--out", default="power_vectors.hex")
    ap.add_argument("--stats", default="power_vectors_stats.json")
    args = ap.parse_args()
    gen = torch.Generator().manual_seed(0)

    tok = AutoTokenizer.from_pretrained(args.model, local_files_only=True)
    model = AutoModelForCausalLM.from_pretrained(args.model, local_files_only=True,
                                                 torch_dtype=torch.bfloat16).eval().cuda()
    text = open(args.text_file, encoding="utf-8").read()
    ids = tok(text[:200_000], return_tensors="pt").input_ids[:, :args.context].cuda()

    names = [f"model.layers.{l}.{p}" for l in LAYERS for p in PROJS] + ["lm_head"]
    captured = {}
    modules = dict(model.named_modules())
    def capture(name):
        def hook(module, inp, out):
            # Must return None: a returned value would replace the module output.
            captured.setdefault(name, inp[0][0].float().cpu())
        return hook
    hooks = [modules[n].register_forward_hook(capture(n)) for n in names]
    with torch.inference_mode():
        model(ids)
    for h in hooks:
        h.remove()

    qa, ma, qb, mb, stats = [], [], [], [], {}
    for n in names:
        x = captured[n].to(torch.float64)                       # [tokens, in]
        weight = modules[n].weight.detach()                     # [out, in]
        # Rows quantize independently along the reduction axis, so quantizing a
        # random subset of 256 weight rows gives the same codes as the full matrix.
        rows = torch.randperm(weight.shape[0], generator=gen)[:256]
        w = weight[rows.to(weight.device)].float().cpu().to(torch.float64)
        xq, wq = quantize_mx9(x, -1), quantize_mx9(w, -1)
        stats[n] = {"act_fine_pairs": float((xq.micro_exp == -1).double().mean()),
                    "wt_fine_pairs": float((wq.micro_exp == -1).double().mean())}
        nblk = xq.elements.shape[-2]
        for _ in range(args.sequences):
            t = int(torch.randint(x.shape[0], (1,), generator=gen))
            o = int(torch.randint(w.shape[0], (1,), generator=gen))
            k0 = int(torch.randint(nblk - args.blocks + 1, (1,), generator=gen))
            ks = slice(k0, k0 + args.blocks)
            qa.append(xq.elements[t, ks]); ma.append(xq.micro_exp[t, ks])
            qb.append(wq.elements[o, ks]); mb.append(wq.micro_exp[o, ks])
    qa, ma, qb, mb = (torch.cat(v).to(torch.int64) for v in (qa, ma, qb, mb))

    flats = [flat_dot(qa, ma, qb, mb, r) for r in ROUNDINGS]
    exact = exact_dot(qa, ma, qb, mb)
    with open(args.out, "w") as f:
        for i in range(qa.shape[0]):
            fields = [hexfield(v, 8) for v in qa[i]] + [hexfield(mu_bits(ma[i]), 8)]
            fields += [hexfield(v, 8) for v in qb[i]] + [hexfield(mu_bits(mb[i]), 8)]
            fields += [hexfield(fl[i], 19) for fl in flats] + [hexfield(exact[i], 21)]
            f.write(" ".join(fields) + "\n")
    with open(args.stats, "w") as f:
        json.dump(stats, f, indent=1)
    print(f"{qa.shape[0]} vectors -> {args.out}")
    print(json.dumps(stats, indent=1))


if __name__ == "__main__":
    main()
