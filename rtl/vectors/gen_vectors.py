"""Generate block dot-product test vectors from the accuracy emulator.

Golden values come from avant_garde.mx9 (quantize_mx9, flatten_mx9, dequantize),
the code behind every reported perplexity, so the RTL is checked against the
same numerics. One line per block pair, all fields hex, space separated:

  a_q[0..15] a_mu b_q[0..15] b_mu flat_trunc flat_nearest flat_even exact

a_q/b_q: 8-bit two's complement codes in [-127, 127].
a_mu/b_mu: 8 bits, bit j = 1 if pair j has micro_exp = -1 (finer pair).
flat_*: 19-bit two's complement integer dot product of the flattened 8-bit
  codes (block scale S_a + S_b), one per emulator rounding mode.
exact: 21-bit two's complement integer equal to the non-flattened MX9 dot
  product times 2^-(S_a + S_b - 2).
"""
import argparse

import torch

from avant_garde.mx9 import MX9Config, MX9Tensor, dequantize, flatten_mx9, quantize_mx9

ROUNDINGS = ("trunc", "nearest", "even")


def tensor_from_codes(q, micro):
    """Wrap raw codes as an MX9Tensor with outer exponent 0 (one block per row)."""
    n = q.shape[0]
    return MX9Tensor(q.to(torch.int8).reshape(n, 1, 16), torch.zeros(n, 1, 1, dtype=torch.int16),
                     micro.to(torch.int8).reshape(n, 1, 8), (n, 16), 1, {})


def codes_from_quantizer(x):
    t = quantize_mx9(x, -1)
    return t.elements.reshape(-1, 16), t.micro_exp.reshape(-1, 8)


def random_codes(n, gen):
    q = torch.randint(-127, 128, (n, 16), generator=gen)
    micro = -torch.randint(0, 2, (n, 8), generator=gen)
    return q, micro


def corner_codes():
    alternating = 127 * (-1) ** torch.arange(16)
    patterns = [torch.full((16,), v) for v in (127, -127, 1, -1, 0, 63, -63, 3, -3)] + [alternating]
    rows = []
    for q in patterns:
        for micro in (torch.zeros(8), -torch.ones(8), -(torch.arange(8) % 2)):
            rows.append((q.to(torch.int64), micro.to(torch.int64)))
    q = torch.stack([r[0] for r in rows])
    micro = torch.stack([r[1] for r in rows])
    return q, micro


def flat_dot(qa, ma, qb, mb, rounding):
    cfg = MX9Config(rounding)
    fa = flatten_mx9(tensor_from_codes(qa, ma), cfg).elements.reshape(-1, 16).to(torch.int64)
    fb = flatten_mx9(tensor_from_codes(qb, mb), cfg).elements.reshape(-1, 16).to(torch.int64)
    return (fa * fb).sum(-1)


def exact_dot(qa, ma, qb, mb):
    da = dequantize(tensor_from_codes(qa, ma), torch.float64)
    db = dequantize(tensor_from_codes(qb, mb), torch.float64)
    scaled = (da * db).sum(-1) * 4  # outer exponents are 0, so scale is 2^-(0+0-2)
    exact = scaled.round()
    assert torch.equal(exact, scaled), "non-integer exact dot product"
    # Lossless flattening must agree with the hierarchical value.
    la = flatten_mx9(tensor_from_codes(qa, ma), lossless=True).elements.reshape(-1, 16).to(torch.int64)
    lb = flatten_mx9(tensor_from_codes(qb, mb), lossless=True).elements.reshape(-1, 16).to(torch.int64)
    assert torch.equal((la * lb).sum(-1), exact.to(torch.int64))
    return exact.to(torch.int64)


def hexfield(v, bits):
    return format(int(v) & ((1 << bits) - 1), "0{}x".format((bits + 3) // 4))


def mu_bits(micro):
    return sum((1 << j) for j in range(8) if int(micro[j]) == -1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--random", type=int, default=20000)
    ap.add_argument("--quantized", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out", default="vectors.hex")
    args = ap.parse_args()
    gen = torch.Generator().manual_seed(args.seed)

    parts = [corner_codes(), random_codes(args.random, gen)]
    # Codes the quantizer actually produces: Gaussian and heavy-tailed rows.
    for x in (torch.randn(args.quantized, 16, generator=gen),
              torch.randn(args.quantized, 16, generator=gen) ** 3):
        parts.append(codes_from_quantizer(x.to(torch.float64)))
    q = torch.cat([p[0].to(torch.int64) for p in parts])
    micro = torch.cat([p[1].to(torch.int64) for p in parts])
    # Pair each A row with a shuffled B row.
    perm = torch.randperm(q.shape[0], generator=gen)
    qa, ma, qb, mb = q, micro, q[perm], micro[perm]

    flats = [flat_dot(qa, ma, qb, mb, r) for r in ROUNDINGS]
    exact = exact_dot(qa, ma, qb, mb)
    with open(args.out, "w") as f:
        for i in range(q.shape[0]):
            fields = [hexfield(v, 8) for v in qa[i]] + [hexfield(mu_bits(ma[i]), 8)]
            fields += [hexfield(v, 8) for v in qb[i]] + [hexfield(mu_bits(mb[i]), 8)]
            fields += [hexfield(fl[i], 19) for fl in flats] + [hexfield(exact[i], 21)]
            f.write(" ".join(fields) + "\n")
    print(f"{q.shape[0]} vectors -> {args.out}")


if __name__ == "__main__":
    main()
