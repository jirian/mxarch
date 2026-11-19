// Register-to-register wrappers so each unit is timed as one pipeline stage.
// Flip-flop area is identical in structure across wrappers and is reported
// separately from the combinational logic.

module reg_dp_int #(parameter integer W = 8) (
  input  wire              clk,
  input  wire [16*W-1:0]   a_in, b_in,
  output reg  [2*W+3:0]    sum_out
);
  reg  [16*W-1:0] a, b;
  wire [2*W+3:0]  sum;
  dp_int #(W) u (.a(a), .b(b), .sum(sum));
  always @(posedge clk) begin
    a <= a_in; b <= b_in; sum_out <= sum;
  end
endmodule

module reg_dp_int8 (input wire clk, input wire [127:0] a_in, b_in, output wire [19:0] sum_out);
  reg_dp_int #(8) u (.clk(clk), .a_in(a_in), .b_in(b_in), .sum_out(sum_out));
endmodule

module reg_dp_int9 (input wire clk, input wire [143:0] a_in, b_in, output wire [21:0] sum_out);
  reg_dp_int #(9) u (.clk(clk), .a_in(a_in), .b_in(b_in), .sum_out(sum_out));
endmodule

module reg_dp_lateshift (
  input  wire         clk,
  input  wire [127:0] qa_in, qb_in,
  input  wire [7:0]   mua_in, mub_in,
  output reg  [20:0]  sum_out
);
  reg  [127:0] qa, qb;
  reg  [7:0]   mua, mub;
  wire [20:0]  sum;
  dp_lateshift u (.qa(qa), .mua(mua), .qb(qb), .mub(mub), .sum(sum));
  always @(posedge clk) begin
    qa <= qa_in; qb <= qb_in; mua <= mua_in; mub <= mub_in; sum_out <= sum;
  end
endmodule

module reg_ot_flat8 #(parameter integer ROUND = `RND_NEAREST) (
  input  wire         clk,
  input  wire [127:0] q_in,
  input  wire [7:0]   mu_in,
  output reg  [127:0] f_out
);
  reg  [127:0] q;
  reg  [7:0]   mu;
  wire [127:0] f;
  ot_flat8 #(ROUND) u (.q(q), .mu(mu), .f(f));
  always @(posedge clk) begin
    q <= q_in; mu <= mu_in; f_out <= f;
  end
endmodule

module reg_ot_flat8_trunc (input wire clk, input wire [127:0] q_in, input wire [7:0] mu_in, output wire [127:0] f_out);
  reg_ot_flat8 #(`RND_TRUNC) u (.clk(clk), .q_in(q_in), .mu_in(mu_in), .f_out(f_out));
endmodule

module reg_ot_flat8_nearest (input wire clk, input wire [127:0] q_in, input wire [7:0] mu_in, output wire [127:0] f_out);
  reg_ot_flat8 #(`RND_NEAREST) u (.clk(clk), .q_in(q_in), .mu_in(mu_in), .f_out(f_out));
endmodule

module reg_ot_flat8_even (input wire clk, input wire [127:0] q_in, input wire [7:0] mu_in, output wire [127:0] f_out);
  reg_ot_flat8 #(`RND_EVEN) u (.clk(clk), .q_in(q_in), .mu_in(mu_in), .f_out(f_out));
endmodule

module reg_ot_wide9 (
  input  wire         clk,
  input  wire [127:0] q_in,
  input  wire [7:0]   mu_in,
  output reg  [143:0] f_out
);
  reg  [127:0] q;
  reg  [7:0]   mu;
  wire [143:0] f;
  ot_wide9 u (.q(q), .mu(mu), .f(f));
  always @(posedge clk) begin
    q <= q_in; mu <= mu_in; f_out <= f;
  end
endmodule
