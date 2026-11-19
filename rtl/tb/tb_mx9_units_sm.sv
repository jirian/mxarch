// Checks the sign-magnitude units against the same golden vectors as
// tb_mx9_units.sv; codes are converted from two's complement on the fly.
module tb_mx9_units_sm;
  reg  [15:0]     sa, sb;
  reg  [16*7-1:0] ma, mb;
  reg  [7:0]      mua, mub;

  wire [16*7-1:0] fa_t, fb_t, fa_n, fb_n, fa_e, fb_e;
  wire [18:0]     sum_a_t, sum_a_n, sum_a_e;
  wire [16*8-1:0] wa, wb;
  wire [20:0]     sum_b, sum_c;

  ot_flat8_sm #(`RND_TRUNC)   ot_t_a (.m(ma), .mu(mua), .f(fa_t));
  ot_flat8_sm #(`RND_TRUNC)   ot_t_b (.m(mb), .mu(mub), .f(fb_t));
  ot_flat8_sm #(`RND_NEAREST) ot_n_a (.m(ma), .mu(mua), .f(fa_n));
  ot_flat8_sm #(`RND_NEAREST) ot_n_b (.m(mb), .mu(mub), .f(fb_n));
  ot_flat8_sm #(`RND_EVEN)    ot_e_a (.m(ma), .mu(mua), .f(fa_e));
  ot_flat8_sm #(`RND_EVEN)    ot_e_b (.m(mb), .mu(mub), .f(fb_e));
  dp_sm #(7) dp_t (.sa(sa), .sb(sb), .ma(fa_t), .mb(fb_t), .sum(sum_a_t));
  dp_sm #(7) dp_n (.sa(sa), .sb(sb), .ma(fa_n), .mb(fb_n), .sum(sum_a_n));
  dp_sm #(7) dp_e (.sa(sa), .sb(sb), .ma(fa_e), .mb(fb_e), .sum(sum_a_e));
  ot_wide9_sm ow_a (.m(ma), .mu(mua), .f(wa));
  ot_wide9_sm ow_b (.m(mb), .mu(mub), .f(wb));
  dp_sm #(8) dp_b (.sa(sa), .sb(sb), .ma(wa), .mb(wb), .sum(sum_b));
  dp_lateshift_sm dp_c (.sa(sa), .sb(sb), .ma(ma), .mb(mb), .mua(mua), .mub(mub), .sum(sum_c));

  integer fd, n, errors, rc, k, i;
  reg [31:0] h [0:37];
  reg [7:0]  qa, qb;
  reg [8*256-1:0] path;

  task check(input [31:0] got, input [31:0] want, input [8*8-1:0] name);
    if (got !== want) begin
      errors = errors + 1;
      if (errors < 10) $display("vec %0d: %0s got %0d want %0d", n, name, $signed(got), $signed(want));
    end
  endtask

  initial begin
    if (!$value$plusargs("vectors=%s", path)) path = "vectors/vectors.hex";
    fd = $fopen(path, "r");
    if (fd == 0) begin $display("cannot open vectors"); $finish; end
    n = 0; errors = 0; rc = 38;
    while (rc == 38) begin
      rc = 0;
      for (k = 0; k < 38; k = k + 1) rc = rc + $fscanf(fd, "%h", h[k]);
      if (rc == 38) begin
        for (i = 0; i < 16; i = i + 1) begin
          qa = h[i][7:0];
          qb = h[17 + i][7:0];
          sa[i] = qa[7];
          sb[i] = qb[7];
          ma[7*i +: 7] = qa[7] ? 7'(-qa) : qa[6:0];
          mb[7*i +: 7] = qb[7] ? 7'(-qb) : qb[6:0];
        end
        mua = h[16][7:0];
        mub = h[33][7:0];
        #1;
        check({{13{sum_a_t[18]}}, sum_a_t}, {{13{h[34][18]}}, h[34][18:0]}, "a-trunc");
        check({{13{sum_a_n[18]}}, sum_a_n}, {{13{h[35][18]}}, h[35][18:0]}, "a-near");
        check({{13{sum_a_e[18]}}, sum_a_e}, {{13{h[36][18]}}, h[36][18:0]}, "a-even");
        check({{11{sum_b[20]}}, sum_b},     {{11{h[37][20]}}, h[37][20:0]}, "b");
        check({{11{sum_c[20]}}, sum_c},     {{11{h[37][20]}}, h[37][20:0]}, "c");
        n = n + 1;
      end
    end
    $fclose(fd);
    $display("%0d vectors, %0d mismatches", n, errors);
    if (errors != 0 || n == 0) $display("FAIL"); else $display("PASS");
    $finish;
  end
endmodule
