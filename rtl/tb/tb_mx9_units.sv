// Checks every unit against the emulator's golden vectors (vectors/gen_vectors.py).
// With +define+GATES the units are the synthesized netlists in syn/out/.
module tb_mx9_units;
  reg  [16*8-1:0] qa, qb;
  reg  [7:0]      mua, mub;

  // (a) for each emulator rounding mode: trunc, nearest, even
  wire [16*8-1:0] fa_t, fb_t, fa_n, fb_n, fa_e, fb_e;
  wire [19:0]     sum_a_t, sum_a_n, sum_a_e;
  // (b) and (c)
  wire [16*9-1:0] wa, wb;
  wire [21:0]     sum_b;
  wire [20:0]     sum_c;

  ot_flat8 #(`RND_TRUNC)   ot_t_a (.q(qa), .mu(mua), .f(fa_t));
  ot_flat8 #(`RND_TRUNC)   ot_t_b (.q(qb), .mu(mub), .f(fb_t));
  ot_flat8 #(`RND_NEAREST) ot_n_a (.q(qa), .mu(mua), .f(fa_n));
  ot_flat8 #(`RND_NEAREST) ot_n_b (.q(qb), .mu(mub), .f(fb_n));
  ot_flat8 #(`RND_EVEN)    ot_e_a (.q(qa), .mu(mua), .f(fa_e));
  ot_flat8 #(`RND_EVEN)    ot_e_b (.q(qb), .mu(mub), .f(fb_e));
  dp_int #(8) dp_t (.a(fa_t), .b(fb_t), .sum(sum_a_t));
  dp_int #(8) dp_n (.a(fa_n), .b(fb_n), .sum(sum_a_n));
  dp_int #(8) dp_e (.a(fa_e), .b(fb_e), .sum(sum_a_e));
  ot_wide9 ow_a (.q(qa), .mu(mua), .f(wa));
  ot_wide9 ow_b (.q(qb), .mu(mub), .f(wb));
  dp_int #(9) dp_b (.a(wa), .b(wb), .sum(sum_b));
  dp_lateshift dp_c (.qa(qa), .mua(mua), .qb(qb), .mub(mub), .sum(sum_c));

  integer fd, n, errors, rc, k, i;
  reg [31:0] h [0:37];
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
          qa[8*i +: 8] = h[i][7:0];
          qb[8*i +: 8] = h[17 + i][7:0];
        end
        mua = h[16][7:0];
        mub = h[33][7:0];
        #1;
        // Sign-extend each result and its golden value to 32 bits.
        check({{12{sum_a_t[19]}}, sum_a_t}, {{13{h[34][18]}}, h[34][18:0]}, "a-trunc");
        check({{12{sum_a_n[19]}}, sum_a_n}, {{13{h[35][18]}}, h[35][18:0]}, "a-near");
        check({{12{sum_a_e[19]}}, sum_a_e}, {{13{h[36][18]}}, h[36][18:0]}, "a-even");
        check({{10{sum_b[21]}}, sum_b},     {{11{h[37][20]}}, h[37][20:0]}, "b");
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
