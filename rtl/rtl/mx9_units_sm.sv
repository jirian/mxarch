// Sign-magnitude variants of the MX9 block dot-product units.
//
// MX9 elements are a sign bit and a 7-bit magnitude (avant_garde/mx9.py), so a
// datapath may keep that encoding instead of two's complement. Element i
// occupies s[i] and m[7*i +: 7]; value = (-1)^s * m. Same pair bits mu as in
// mx9_units.sv. Outputs are two's complement, identical to the two's-complement
// units, so both are checked against the same golden vectors.
//
//   (a) ot_flat8_sm + dp_sm #(7)    lossy, 7-bit magnitudes after flattening
//   (b) ot_wide9_sm + dp_sm #(8)    lossless, 8-bit magnitudes
//   (c) dp_lateshift_sm             lossless, 7x7 products shifted by 0..2
//
// Uses the RND_* defines from mx9_units.sv (read that file first).

// Flattening on magnitudes: truncation is a plain shift, nearest adds the
// dropped bit, ties-to-even adds it only when the kept LSB is odd.
module ot_flat8_sm #(parameter integer ROUND = `RND_TRUNC) (
  input  wire [16*7-1:0] m,
  input  wire [7:0]      mu,
  output wire [16*7-1:0] f
);
  genvar i;
  generate
    for (i = 0; i < 16; i = i + 1) begin : g_elem
      wire [6:0] mi  = m[7*i +: 7];
      wire [6:0] sh  = {1'b0, mi[6:1]};
      wire       inc = (ROUND == `RND_TRUNC)   ? 1'b0
                     : (ROUND == `RND_NEAREST) ? mi[0]
                     :                           (mi[0] & mi[1]);
      assign f[7*i +: 7] = mu[i/2] ? sh + {6'b0, inc} : mi;
    end
  endgenerate
endmodule

// Widening on magnitudes: magnitude * 2^(1 + micro_exp), 8 bits, never lossy.
module ot_wide9_sm (
  input  wire [16*7-1:0] m,
  input  wire [7:0]      mu,
  output wire [16*8-1:0] f
);
  genvar i;
  generate
    for (i = 0; i < 16; i = i + 1) begin : g_elem
      wire [6:0] mi = m[7*i +: 7];
      assign f[8*i +: 8] = mu[i/2] ? {1'b0, mi} : {mi, 1'b0};
    end
  endgenerate
endmodule

// 16-element dot product of sign-magnitude operands with W-bit magnitudes:
// unsigned W x W products, sign by XOR, conditional negation into the tree.
module dp_sm #(parameter integer W = 7) (
  input  wire [15:0]      sa, sb,
  input  wire [16*W-1:0]  ma, mb,
  output reg  [2*W+4:0]   sum
);
  wire [16*(2*W+1)-1:0] term;
  genvar i;
  generate
    for (i = 0; i < 16; i = i + 1) begin : g_prod
      wire [2*W-1:0] p = ma[W*i +: W] * mb[W*i +: W];
      wire           neg = sa[i] ^ sb[i];
      assign term[(2*W+1)*i +: 2*W+1] = neg ? -{1'b0, p} : {1'b0, p};
    end
  endgenerate
  integer k;
  always @* begin
    sum = 0;
    for (k = 0; k < 16; k = k + 1)
      sum = sum + {{4{term[(2*W+1)*k+2*W]}}, term[(2*W+1)*k +: 2*W+1]};
  end
endmodule

// (c) Late microexponent on sign-magnitude codes: 7x7 products shifted left by
// 2 - mu_a - mu_b, then signed into the tree.
module dp_lateshift_sm (
  input  wire [15:0]     sa, sb,
  input  wire [16*7-1:0] ma, mb,
  input  wire [7:0]      mua, mub,
  output reg  [20:0]     sum
);
  wire [16*17-1:0] term;
  genvar i;
  generate
    for (i = 0; i < 16; i = i + 1) begin : g_prod
      wire [13:0] p = ma[7*i +: 7] * mb[7*i +: 7];
      wire [1:0]  fine = {mua[i/2], mub[i/2]};
      wire [15:0] ps = (fine == 2'b00) ? {p, 2'b00}
                     : (fine == 2'b11) ? {2'b00, p}
                     :                   {1'b0, p, 1'b0};
      wire        neg = sa[i] ^ sb[i];
      assign term[17*i +: 17] = neg ? -{1'b0, ps} : {1'b0, ps};
    end
  endgenerate
  integer k;
  always @* begin
    sum = 0;
    for (k = 0; k < 16; k = k + 1)
      sum = sum + {{4{term[17*k+16]}}, term[17*k +: 17]};
  end
endmodule
