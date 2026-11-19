"""Cross-check our MXINT8 emulation against Microsoft's microxcaling emulator.

Avant-Garde's accuracy numbers come from a modified microxcaling. Its MXINT8
(scale_bits 8, block 32, round nearest) should reproduce our `mxint8` mode on
identical windows if both harnesses quantize the same GEMM operands. bfloat 0
leaves vector ops in FP32 as ours does; bfloat 16 is the README's MXINT8 recipe.
"""
import argparse
import json
from pathlib import Path

import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

from avant_garde.evaluation import perplexity, token_windows
from avant_garde.inference import configure_fp32


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--microxcaling", required=True, help="microxcaling checkout")
    p.add_argument("--model", default="openai-community/gpt2")
    p.add_argument("--text-file", required=True)
    p.add_argument("--context", type=int, default=1024)
    p.add_argument("--windows", type=int, default=64)
    p.add_argument("--bfloat", type=int, default=0)
    p.add_argument("--elem-format", default="int8")
    p.add_argument("--block-size", type=int, default=32)
    p.add_argument("--output", required=True)
    args = p.parse_args()
    import sys
    sys.path.insert(0, args.microxcaling)
    from mx import mx_mapping
    from mx.specs import MxSpecs, finalize_mx_specs

    configure_fp32()
    tokenizer = AutoTokenizer.from_pretrained(args.model, local_files_only=True)
    tokens = tokenizer(Path(args.text_file).read_text(), add_special_tokens=False,
                       verbose=False)["input_ids"]
    windows = token_windows(tokens, args.context, args.windows)
    model = AutoModelForCausalLM.from_pretrained(
        args.model, local_files_only=True, attn_implementation="eager",
        torch_dtype=torch.float32).eval().cuda()
    results = {"fp32": perplexity(model, windows, "cuda")}
    specs = MxSpecs()
    specs["scale_bits"] = 8
    specs["w_elem_format"] = args.elem_format
    specs["a_elem_format"] = args.elem_format
    specs["block_size"] = args.block_size
    specs["bfloat"] = args.bfloat
    specs["custom_cuda"] = False
    specs["quantize_backprop"] = False
    specs = finalize_mx_specs(specs)
    mx_mapping.inject_pyt_ops(specs)
    results["microxcaling"] = perplexity(model, windows, "cuda")
    summary = {"arguments": vars(args), "mx_specs": dict(specs),
               "perplexity": {k: v["perplexity"] for k, v in results.items()},
               "scored_tokens": results["fp32"]["scored_tokens"]}
    Path(args.output).write_text(json.dumps(summary, indent=2, default=str) + "\n")
    print(json.dumps(summary["perplexity"]), flush=True)


if __name__ == "__main__":
    main()
