// AXI4-Lite interface (32-bit address/data). Block-level TBs connect only the low
// C_S00_AXI_ADDR_WIDTH address bits to the DUT.
interface axil_if (input logic clk, input logic rst_n);
  logic [31:0] awaddr;  logic [2:0] awprot; logic awvalid; logic awready;
  logic [31:0] wdata;   logic [3:0] wstrb;  logic wvalid;  logic wready;
  logic [1:0]  bresp;   logic bvalid;       logic bready;
  logic [31:0] araddr;  logic [2:0] arprot; logic arvalid; logic arready;
  logic [31:0] rdata;   logic [1:0] rresp;  logic rvalid;  logic rready;

  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output awaddr, awprot, awvalid, wdata, wstrb, wvalid, bready, araddr, arprot, arvalid, rready;
    input  awready, wready, bresp, bvalid, arready, rdata, rresp, rvalid;
  endclocking

  clocking mon_cb @(posedge clk);
    default input #1step;
    input awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bresp, bvalid, bready,
          araddr, arvalid, arready, rdata, rresp, rvalid, rready;
  endclocking

  // ---- protocol assertions (AXI4-Lite subset)
  // Written out per channel on purpose: a parameterised named property
  // (property p_stable(valid, ready, sig)) crashes xelab in Vivado 2022.2 xsim
  // (EXCEPTION_ACCESS_VIOLATION in "Compiling module work.axil_if"; with typed formals it hangs).
  a_aw_stable: assert property (@(posedge clk) disable iff (!rst_n) (awvalid && !awready) |=> $stable(awaddr) && awvalid);
  a_w_stable:  assert property (@(posedge clk) disable iff (!rst_n) (wvalid  && !wready)  |=> $stable(wdata)  && wvalid);
  a_ar_stable: assert property (@(posedge clk) disable iff (!rst_n) (arvalid && !arready) |=> $stable(araddr) && arvalid);
  a_b_stable:  assert property (@(posedge clk) disable iff (!rst_n) (bvalid  && !bready)  |=> $stable(bresp)  && bvalid);
  a_r_stable:  assert property (@(posedge clk) disable iff (!rst_n) (rvalid  && !rready)  |=> $stable(rdata)  && rvalid);
  a_no_x_valid: assert property (@(posedge clk) disable iff (!rst_n)
                  !$isunknown({awvalid, wvalid, bvalid, arvalid, rvalid}));
endinterface
