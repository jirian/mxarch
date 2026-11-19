// Register-to-register wrappers for the sign-magnitude units (see reg_wrappers.sv).

module reg_dp_sm7 (input wire clk, input wire [15:0] sa_in, sb_in,
                   input wire [111:0] ma_in, mb_in, output reg [18:0] sum_out);
  reg [15:0] sa, sb; reg [111:0] ma, mb; wire [18:0] sum;
  dp_sm #(7) u (.sa(sa), .sb(sb), .ma(ma), .mb(mb), .sum(sum));
  always @(posedge clk) begin
    sa <= sa_in; sb <= sb_in; ma <= ma_in; mb <= mb_in; sum_out <= sum;
  end
endmodule

module reg_dp_sm8 (input wire clk, input wire [15:0] sa_in, sb_in,
                   input wire [127:0] ma_in, mb_in, output reg [20:0] sum_out);
  reg [15:0] sa, sb; reg [127:0] ma, mb; wire [20:0] sum;
  dp_sm #(8) u (.sa(sa), .sb(sb), .ma(ma), .mb(mb), .sum(sum));
  always @(posedge clk) begin
    sa <= sa_in; sb <= sb_in; ma <= ma_in; mb <= mb_in; sum_out <= sum;
  end
endmodule

module reg_dp_lateshift_sm (input wire clk, input wire [15:0] sa_in, sb_in,
                            input wire [111:0] ma_in, mb_in, input wire [7:0] mua_in, mub_in,
                            output reg [20:0] sum_out);
  reg [15:0] sa, sb; reg [111:0] ma, mb; reg [7:0] mua, mub; wire [20:0] sum;
  dp_lateshift_sm u (.sa(sa), .sb(sb), .ma(ma), .mb(mb), .mua(mua), .mub(mub), .sum(sum));
  always @(posedge clk) begin
    sa <= sa_in; sb <= sb_in; ma <= ma_in; mb <= mb_in; mua <= mua_in; mub <= mub_in;
    sum_out <= sum;
  end
endmodule

module reg_ot_flat8_sm #(parameter integer ROUND = `RND_TRUNC) (
  input wire clk, input wire [111:0] m_in, input wire [7:0] mu_in, output reg [111:0] f_out);
  reg [111:0] m; reg [7:0] mu; wire [111:0] f;
  ot_flat8_sm #(ROUND) u (.m(m), .mu(mu), .f(f));
  always @(posedge clk) begin
    m <= m_in; mu <= mu_in; f_out <= f;
  end
endmodule

module reg_ot_flat8_sm_trunc (input wire clk, input wire [111:0] m_in, input wire [7:0] mu_in, output wire [111:0] f_out);
  reg_ot_flat8_sm #(`RND_TRUNC) u (.clk(clk), .m_in(m_in), .mu_in(mu_in), .f_out(f_out));
endmodule

module reg_ot_flat8_sm_nearest (input wire clk, input wire [111:0] m_in, input wire [7:0] mu_in, output wire [111:0] f_out);
  reg_ot_flat8_sm #(`RND_NEAREST) u (.clk(clk), .m_in(m_in), .mu_in(mu_in), .f_out(f_out));
endmodule

module reg_ot_wide9_sm (input wire clk, input wire [111:0] m_in, input wire [7:0] mu_in, output reg [127:0] f_out);
  reg [111:0] m; reg [7:0] mu; wire [127:0] f;
  ot_wide9_sm u (.m(m), .mu(mu), .f(f));
  always @(posedge clk) begin
    m <= m_in; mu <= mu_in; f_out <= f;
  end
endmodule
