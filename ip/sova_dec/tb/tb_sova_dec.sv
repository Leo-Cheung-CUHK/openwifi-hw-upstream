// Directed bit-exact TB for sova_dec against uvm/scripts/gen_sova_vectors.py output.
// Plusargs: +VEC=<dir> (in.txt / exp.txt), +GAP=<percent of idle cycles, default 30>,
//           +SEED=<n>.  Exercises back-to-back input, random gaps, aclken=0 cycles and a
//           synchronous reset between frames.
`timescale 1ns/1ps
module tb_sova_dec;
  parameter int BR = 1;
  parameter int D  = 84;
  parameter int LR = 48;

  logic clk = 0, rstn = 0, ce = 1;
  logic [15:0] tdata;
  logic [7:0]  tuser;
  logic        tvalid = 0;
  wire         tready;
  wire  [7:0]  odata, ollr;
  wire         ovalid;

  always #5 clk = ~clk;

  sova_dec #(.BR(BR), .D(D), .LR(LR)) dut (
    .aclk(clk), .aresetn(rstn), .aclken(ce),
    .s_axis_data_tdata(tdata), .s_axis_data_tuser(tuser), .s_axis_data_tvalid(tvalid),
    .s_axis_data_tready(tready),
    .m_axis_data_tdata(odata), .m_axis_data_tvalid(ovalid), .m_axis_llr_tdata(ollr));

  int exp_bit[$], exp_llr[$];
  int errors = 0, checked = 0, frame = 0, got_in_frame = 0, exp_in_frame = 0;
  int gap = 30;

  // output checker: the output register only loads on edges with aclken=1, so count a
  // beat only if ce was 1 at the edge that produced it (ce_d)
  logic ce_d = 1;
  always @(posedge clk) begin : chk
    int b, l;
    ce_d <= ce;
    if (rstn && ce_d && ovalid) begin
    if (exp_bit.size() == 0) begin
      $display("ERROR frame %0d: unexpected output", frame); errors++;
    end else begin
      b = exp_bit.pop_front(); l = exp_llr.pop_front();
      if (int'(odata[0]) != b || int'($signed(ollr)) != l) begin
        if (errors < 20)
          $display("ERROR frame %0d out %0d: got bit=%0d llr=%0d exp bit=%0d llr=%0d",
                   frame, got_in_frame, odata[0], $signed(ollr), b, l);
        errors++;
      end
      checked++;
    end
    got_in_frame++;
    end
  end

  initial begin
    string dir, tag;
    int fi, fe, n, m, x, y, e, b, l, r;
    if (!$value$plusargs("VEC=%s", dir)) dir = "vec";
    void'($value$plusargs("GAP=%d", gap));
    if ($value$plusargs("SEED=%d", r)) void'($urandom(r));
    fi = $fopen({dir, "/in.txt"}, "r");
    fe = $fopen({dir, "/exp.txt"}, "r");
    if (fi == 0 || fe == 0) $fatal(1, "cannot open vectors in %s", dir);
    while ($fscanf(fi, "%s %d\n", tag, n) == 2) begin
      void'($fscanf(fe, "%s %d\n", tag, m));
      for (int i = 0; i < m; i++) begin
        void'($fscanf(fe, "%d %d\n", b, l)); exp_bit.push_back(b); exp_llr.push_back(l);
      end
      // reset between frames (as openofdm does per packet)
      rstn = 0; repeat (3) @(posedge clk); #1 rstn = 1;
      got_in_frame = 0; exp_in_frame = m;
      for (int i = 0; i < n; i++) begin
        void'($fscanf(fi, "%d %d %d\n", x, y, e));
        // random idle cycles and aclken=0 cycles
        while ($urandom_range(99) < gap) begin
          @(posedge clk); #1 tvalid = 0; ce = ($urandom_range(9) != 0);
        end
        @(posedge clk); #1;
        ce = 1; tvalid = 1;
        tdata = {5'b0, 3'(y), 5'b0, 3'(x)}; tuser = {6'b0, 2'(e)};
      end
      @(posedge clk); #1 tvalid = 0; ce = 1;
      repeat (20) @(posedge clk);
      if (got_in_frame != exp_in_frame) begin
        $display("ERROR frame %0d: %0d outputs, expected %0d", frame, got_in_frame, exp_in_frame);
        errors++;
      end
      frame++;
    end
    if (exp_bit.size() != 0) begin $display("ERROR: %0d expected outputs left", exp_bit.size()); errors++; end
    $display("%s  BR=%0d frames=%0d outputs_checked=%0d errors=%0d",
             errors == 0 ? "PASS" : "FAIL", BR, frame, checked, errors);
    $finish;
  end
endmodule
