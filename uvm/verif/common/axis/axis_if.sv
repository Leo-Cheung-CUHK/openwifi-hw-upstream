// AXI4-Stream, 64-bit (matches every openwifi DMA stream). openwifi uses TSTRB, not TKEEP.
interface axis_if (input logic clk, input logic rst_n);
  logic [63:0] tdata;
  logic [7:0]  tstrb;
  logic        tlast;
  logic        tvalid;
  logic        tready;

  clocking m_cb @(posedge clk);   // used when the TB is the stream master
    default input #1step output #1;
    output tdata, tstrb, tlast, tvalid; input tready;
  endclocking
  clocking s_cb @(posedge clk);   // used when the TB is the stream slave
    default input #1step output #1;
    input tdata, tstrb, tlast, tvalid; output tready;
  endclocking
  clocking mon_cb @(posedge clk);
    default input #1step;
    input tdata, tstrb, tlast, tvalid, tready;
  endclocking

  // TLAST stability is checked apart: rx_intf_m_axis derives TLAST from TREADY (finding H),
  // which the DMA tolerates; a TB waives that one rule with tlast_waive = 1 and counts it.
  bit tlast_waive = 0; int unsigned n_tlast_unstable;
  // hold_waive: the master's own stream reset is active. rx_intf withdraws TVALID that way on a
  // TLAST timeout (finding I); the TB ties hold_waive to that reset and counts the withdrawals.
  logic hold_waive = 0; int unsigned n_valid_withdrawn;
  always @(posedge clk) if (rst_n && hold_waive && $past(tvalid && !tready) && !tvalid) n_valid_withdrawn++;
  a_hold: assert property (@(posedge clk) disable iff (!rst_n || hold_waive)
            (tvalid && !tready) |=> tvalid && $stable({tdata, tstrb}))
          else $error("AXIS: payload changed / valid dropped while stalled");
  a_hold_last: assert property (@(posedge clk) disable iff (!rst_n)
            (tvalid && !tready) |=> $stable(tlast))
          else if (tlast_waive) n_tlast_unstable++; else $error("AXIS: TLAST changed while stalled");
  a_no_x: assert property (@(posedge clk) disable iff (!rst_n) tvalid |-> !$isunknown({tdata, tlast}));
endinterface
