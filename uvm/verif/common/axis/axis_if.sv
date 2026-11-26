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

  a_hold: assert property (@(posedge clk) disable iff (!rst_n)
            (tvalid && !tready) |=> tvalid && $stable({tdata, tstrb, tlast}))
          else $error("AXIS: payload changed / valid dropped while stalled");
  a_no_x: assert property (@(posedge clk) disable iff (!rst_n) tvalid |-> !$isunknown({tdata, tlast}));
endinterface
