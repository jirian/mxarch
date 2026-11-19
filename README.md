# How Avant-Garde Scales to Large LLM Inference

CS-471 project (EPFL): reproduction and extension of Avant-Garde (ISCA 2025),
hardware support for scaled numeric formats on GPUs.

- `emulator/` — PyTorch numerical emulator of MX9 / flattening (GPT-2, ViT,
  Qwen3 dense and MoE), with the Figure 7/8 tensor-core model, hierarchical
  activation policy, MXINT8 references and layer fallback. Full history of the
  team repository, merged in branch form (see below).
- `rtl/` — H1.2 hardware study: RTL for (a) Avant-Garde's lossy flattening +
  INT8 dot product, (b) lossless 9-bit operands, (c) late microexponent shift,
  in two's-complement and sign-magnitude variants; emulator-generated golden
  vectors, testbenches, Yosys and OpenROAD (Nangate45) flows, real-tensor
  power analysis and per-GPU area scaling.

## rtl/ quick start

```
rtl/lib/fetch_lib.sh                      # Nangate45 liberty
cd rtl
verilator --binary --top-module tb_mx9_units -Mdir build/v rtl/mx9_units.sv tb/tb_mx9_units.sv -o tb
./build/v/tb                              # 60,030 golden vectors
syn/run_syn.sh                            # quick Yosys area
python3 analysis/gpu_scaling.py           # tensor-core / SM area scaling
```

Place-and-route (`syn/orfs/`) and power (`power/`) run on the cluster with the
OpenROAD-flow-scripts image under Apptainer; results are in
`syn/orfs/results_tc.tsv`.

## Commit hashes

The emulator history was imported with tool-attribution trailers removed from
commit messages, which changes some hashes. Cluster run logs refer to the
original merge commit `4aae500`, which is `e98fc57` here.
