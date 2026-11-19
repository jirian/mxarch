// Replays real Qwen3 block pairs through one routed wrapper netlist at the
// 2.5 ns clock, dumps switching activity (VCD) for OpenSTA power analysis, and
// checks dot-product outputs against the golden values (2-cycle latency).
//
// Select the design with +define+DUT_<name>; operand transformers take
// operand A, or operand B with +define+OPERAND_B. Stimulus for the dot
// products comes from the RTL operand transformers (truncating flattening
// for (a), widening for (b)), i.e. what each lane would receive.
`timescale 1ps/1ps
module tb_power;
  localparam integer PERIOD = 2500;
  reg clk = 0;
  always #(PERIOD/2) clk = ~clk;

  reg  [16*8-1:0] qa, qb;
  reg  [7:0]      mua, mub;
  wire [16*8-1:0] fa, fb;
  wire [16*9-1:0] wa, wb;
  ot_flat8 #(`RND_TRUNC) ref_fa (.q(qa), .mu(mua), .f(fa));
  ot_flat8 #(`RND_TRUNC) ref_fb (.q(qb), .mu(mub), .f(fb));
  ot_wide9 ref_wa (.q(qa), .mu(mua), .f(wa));
  ot_wide9 ref_wb (.q(qb), .mu(mub), .f(wb));

`ifdef OPERAND_B
  wire [16*8-1:0] q_op = qb;  wire [7:0] mu_op = mub;
`else
  wire [16*8-1:0] q_op = qa;  wire [7:0] mu_op = mua;
`endif

  // Sign-magnitude view of the same codes, for the *_sm designs.
  wire [15:0]     sa, sb;
  wire [16*7-1:0] ma, mb;
  genvar gi;
  generate
    for (gi = 0; gi < 16; gi = gi + 1) begin : g_sm
      wire [7:0] ca = qa[8*gi +: 8], cb = qb[8*gi +: 8];
      wire [7:0] na = -ca, nb = -cb;
      assign sa[gi] = ca[7];
      assign sb[gi] = cb[7];
      assign ma[7*gi +: 7] = ca[7] ? na[6:0] : ca[6:0];
      assign mb[7*gi +: 7] = cb[7] ? nb[6:0] : cb[6:0];
    end
  endgenerate
  wire [16*7-1:0] fma, fmb, m_op;
  wire [16*8-1:0] wma, wmb;
  ot_flat8_sm #(`RND_TRUNC) ref_fma (.m(ma), .mu(mua), .f(fma));
  ot_flat8_sm #(`RND_TRUNC) ref_fmb (.m(mb), .mu(mub), .f(fmb));
  ot_wide9_sm ref_wma (.m(ma), .mu(mua), .f(wma));
  ot_wide9_sm ref_wmb (.m(mb), .mu(mub), .f(wmb));
`ifdef OPERAND_B
  assign m_op = mb;
`else
  assign m_op = ma;
`endif

`ifdef DUT_reg_dp_int8
  wire [19:0] out;  localparam integer OUTW = 19;  localparam integer GOLD = 34;  // golden field widths
  reg_dp_int8 dut (.clk(clk), .a_in(fa), .b_in(fb), .sum_out(out));
`elsif DUT_reg_dp_int9
  wire [21:0] out;  localparam integer OUTW = 21;  localparam integer GOLD = 37;
  reg_dp_int9 dut (.clk(clk), .a_in(wa), .b_in(wb), .sum_out(out));
`elsif DUT_reg_dp_lateshift
  wire [20:0] out;  localparam integer OUTW = 21;  localparam integer GOLD = 37;
  reg_dp_lateshift dut (.clk(clk), .qa_in(qa), .qb_in(qb), .mua_in(mua), .mub_in(mub), .sum_out(out));
`elsif DUT_reg_dp_sm7
  wire [18:0] out;  localparam integer OUTW = 19;  localparam integer GOLD = 34;
  reg_dp_sm7 dut (.clk(clk), .sa_in(sa), .sb_in(sb), .ma_in(fma), .mb_in(fmb), .sum_out(out));
`elsif DUT_reg_dp_sm8
  wire [20:0] out;  localparam integer OUTW = 21;  localparam integer GOLD = 37;
  reg_dp_sm8 dut (.clk(clk), .sa_in(sa), .sb_in(sb), .ma_in(wma), .mb_in(wmb), .sum_out(out));
`elsif DUT_reg_dp_lateshift_sm
  wire [20:0] out;  localparam integer OUTW = 21;  localparam integer GOLD = 37;
  reg_dp_lateshift_sm dut (.clk(clk), .sa_in(sa), .sb_in(sb), .ma_in(ma), .mb_in(mb),
                           .mua_in(mua), .mub_in(mub), .sum_out(out));
`elsif DUT_reg_ot_flat8_sm_trunc
  wire [111:0] out;  localparam integer OUTW = 0;  localparam integer GOLD = 0;
  reg_ot_flat8_sm_trunc dut (.clk(clk), .m_in(m_op), .mu_in(mu_op), .f_out(out));
`elsif DUT_reg_ot_flat8_sm_nearest
  wire [111:0] out;  localparam integer OUTW = 0;  localparam integer GOLD = 0;
  reg_ot_flat8_sm_nearest dut (.clk(clk), .m_in(m_op), .mu_in(mu_op), .f_out(out));
`elsif DUT_reg_ot_wide9_sm
  wire [127:0] out;  localparam integer OUTW = 0;  localparam integer GOLD = 0;
  reg_ot_wide9_sm dut (.clk(clk), .m_in(m_op), .mu_in(mu_op), .f_out(out));
`elsif DUT_reg_ot_wide9
  wire [143:0] out;  localparam integer OUTW = 0;  localparam integer GOLD = 0;
  reg_ot_wide9 dut (.clk(clk), .q_in(q_op), .mu_in(mu_op), .f_out(out));
`else
  wire [127:0] out;  localparam integer OUTW = 0;  localparam integer GOLD = 0;
  `ifdef DUT_reg_ot_flat8_trunc
  reg_ot_flat8_trunc dut (.clk(clk), .q_in(q_op), .mu_in(mu_op), .f_out(out));
  `elsif DUT_reg_ot_flat8_nearest
  reg_ot_flat8_nearest dut (.clk(clk), .q_in(q_op), .mu_in(mu_op), .f_out(out));
  `else
  reg_ot_flat8_even dut (.clk(clk), .q_in(q_op), .mu_in(mu_op), .f_out(out));
  `endif
`endif

  integer fd, n, rc, k, i, errors;
  reg [31:0] h [0:37];
  reg [31:0] gold [0:2];   // golden values of the two previous vectors
  reg [8*256-1:0] path, vcd;

  initial begin
    if (!$value$plusargs("vectors=%s", path)) path = "vectors/power_vectors.hex";
    if (!$value$plusargs("vcd=%s", vcd)) vcd = "power.vcd";
    fd = $fopen(path, "r");
    if (fd == 0) begin $display("cannot open vectors"); $finish; end
    qa = 0; qb = 0; mua = 0; mub = 0; n = 0; errors = 0; rc = 38;
    gold[0] = 0; gold[1] = 0; gold[2] = 0;
    // Settle the pipeline before recording activity.
    repeat (3) @(negedge clk);
    $dumpfile(vcd);
    $dumpvars(0, dut);
    while (rc == 38) begin
      rc = 0;
      for (k = 0; k < 38; k = k + 1) rc = rc + $fscanf(fd, "%h", h[k]);
      if (rc == 38) begin
        @(negedge clk);
        for (i = 0; i < 16; i = i + 1) begin
          qa[8*i +: 8] = h[i][7:0];
          qb[8*i +: 8] = h[17 + i][7:0];
        end
        mua = h[16][7:0];
        mub = h[33][7:0];
        gold[2] = gold[1]; gold[1] = gold[0]; gold[0] = (GOLD != 0) ? h[GOLD] : 0;
        n = n + 1;
        // Output registered two edges after its inputs were applied.
        if (OUTW != 0 && n > 2 && ((out ^ gold[2]) & ((1 << OUTW) - 1)) != 0) begin
          errors = errors + 1;
          if (errors < 5) $display("vec %0d: got %h want %h", n - 2, out, gold[2]);
        end
      end
    end
    repeat (3) @(negedge clk);
    $dumpoff;
    $fclose(fd);
    $display("%0d vectors, %0d output mismatches", n, errors);
    if (errors == 0) $display("PASS"); else $display("FAIL");
    $finish;
  end
endmodule
