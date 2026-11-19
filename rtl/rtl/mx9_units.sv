// MX9 block dot-product units for the H1.2 hardware comparison.
//
// One MX9 operand block: 16 element codes q (8-bit two's complement, [-127, 127])
// and 8 pair bits mu (bit j = 1: pair j has micro_exp = -1, i.e. the finer scale).
// Element i occupies q[8*i +: 8]. The outer block exponents are added outside
// these units and are identical for every design, so only the integer datapath
// is modelled here.
//
//   (a) Avant-Garde:   ot_flat8 on both operands, then dp_int #(8)   (lossy)
//   (b) Wide operands: ot_wide9 on both operands, then dp_int #(9)   (lossless)
//   (c) Late shift:    dp_lateshift on the raw codes                 (lossless)
//
// (a) returns the dot product at scale S_a + S_b; (b) and (c) return the exact
// non-flattened value at scale S_a + S_b - 2, and must agree bit for bit.
//
// Written in the Verilog subset that Yosys, Verilator and Icarus all accept.

// Rounding modes of the emulator's flatten_mx9 (avant_garde/mx9.py).
`define RND_TRUNC   0
`define RND_NEAREST 1
`define RND_EVEN    2

// Operand Transformer of (a): fold the pair microexponent into the codes,
// halving codes of finer pairs with the selected rounding. Stays 8 bits wide.
module ot_flat8 #(parameter integer ROUND = `RND_NEAREST) (
  input  wire [16*8-1:0] q,
  input  wire [7:0]      mu,
  output wire [16*8-1:0] f
);
  genvar i;
  generate
    for (i = 0; i < 16; i = i + 1) begin : g_elem
      wire [7:0] qi  = q[8*i +: 8];
      wire [7:0] fl  = {qi[7], qi[7:1]};  // floor(q / 2)
      wire       odd = qi[0];
      wire       neg = qi[7];
      wire       inc = (ROUND == `RND_TRUNC)   ? (odd & neg)    // toward zero
                     : (ROUND == `RND_NEAREST) ? (odd & ~neg)   // ties away from zero
                     :                           (odd & fl[0]); // ties to even
      assign f[8*i +: 8] = mu[i/2] ? fl + {7'b0, inc} : qi;
    end
  endgenerate
endmodule

// Operand Transformer of (b): keep the absorbed bit by widening to 9 bits,
// i.e. code * 2^(1 + micro_exp). No rounding, never lossy.
module ot_wide9 (
  input  wire [16*8-1:0] q,
  input  wire [7:0]      mu,
  output wire [16*9-1:0] f
);
  genvar i;
  generate
    for (i = 0; i < 16; i = i + 1) begin : g_elem
      wire [7:0] qi = q[8*i +: 8];
      assign f[9*i +: 9] = mu[i/2] ? {qi[7], qi} : {qi, 1'b0};
    end
  endgenerate
endmodule

// Plain 16-element signed integer dot product: the conventional tensor-core
// lane, and the INT8 baseline when W = 8.
module dp_int #(parameter integer W = 8) (
  input  wire [16*W-1:0]  a,
  input  wire [16*W-1:0]  b,
  output reg  [2*W+3:0]   sum
);
  wire [16*2*W-1:0] prod;
  genvar i;
  generate
    for (i = 0; i < 16; i = i + 1) begin : g_prod
      wire signed [2*W-1:0] p = $signed(a[W*i +: W]) * $signed(b[W*i +: W]);
      assign prod[2*W*i +: 2*W] = p;
    end
  endgenerate
  integer k;
  always @* begin
    sum = 0;
    for (k = 0; k < 16; k = k + 1)
      sum = sum + {{4{prod[2*W*k+2*W-1]}}, prod[2*W*k +: 2*W]};
  end
endmodule

// (c) Late microexponent: multiply the raw 8-bit codes, then shift each
// product left by 2 - mu_a - mu_b in {0, 1, 2} before the adder tree.
module dp_lateshift (
  input  wire [16*8-1:0] qa,
  input  wire [7:0]      mua,
  input  wire [16*8-1:0] qb,
  input  wire [7:0]      mub,
  output reg  [20:0]     sum
);
  wire [16*18-1:0] term;
  genvar i;
  generate
    for (i = 0; i < 16; i = i + 1) begin : g_prod
      wire signed [15:0] p = $signed(qa[8*i +: 8]) * $signed(qb[8*i +: 8]);
      wire [1:0] fine = {mua[i/2], mub[i/2]};
      assign term[18*i +: 18] = (fine == 2'b00) ? {p, 2'b00}
                              : (fine == 2'b11) ? {{2{p[15]}}, p}
                              :                   {p[15], p, 1'b0};
    end
  endgenerate
  integer k;
  always @* begin
    sum = 0;
    for (k = 0; k < 16; k = k + 1)
      sum = sum + {{3{term[18*k+17]}}, term[18*k +: 18]};
  end
endmodule
