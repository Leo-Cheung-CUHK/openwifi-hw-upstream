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
  a_aw_stable: assert property (@(posedge clk) disable iff (!rst_n) (awvalid && !awready) |=> $stable(awaddr) && awvalid)
               else $error("AXIL: AW channel changed or withdrawn while stalled");
  a_w_stable:  assert property (@(posedge clk) disable iff (!rst_n) (wvalid  && !wready)  |=> $stable(wdata)  && wvalid)
               else $error("AXIL: W channel changed or withdrawn while stalled");
  a_ar_stable: assert property (@(posedge clk) disable iff (!rst_n) (arvalid && !arready) |=> $stable(araddr) && arvalid)
               else $error("AXIL: AR channel changed or withdrawn while stalled");
  a_b_stable:  assert property (@(posedge clk) disable iff (!rst_n) (bvalid  && !bready)  |=> $stable(bresp)  && bvalid)
               else $error("AXIL: B channel changed or withdrawn while stalled");
  a_r_stable:  assert property (@(posedge clk) disable iff (!rst_n) (rvalid  && !rready)  |=> $stable(rdata)  && rvalid)
               else $error("AXIL: R channel changed or withdrawn while stalled");
  a_no_x_valid: assert property (@(posedge clk) disable iff (!rst_n)
                  !$isunknown({awvalid, wvalid, bvalid, arvalid, rvalid}))
                else $error("AXIL: X/Z on a VALID");
  // protocol covers (FLOW.md §3); plain counters, xsim 2022.2 ignores `cover property`
  int unsigned n_c_wr, n_c_rd, n_c_aw_wait, n_c_b_wait;
  always @(posedge clk) if (rst_n) begin
    if (awvalid && awready && wvalid && wready) n_c_wr++;
    if (rvalid && rready)                       n_c_rd++;
    if (awvalid && !awready)                    n_c_aw_wait++;
    if (arvalid && !arready)                    n_c_b_wait++;
  end
  final $display("OWCOV sva axil.wr %0d\nOWCOV sva axil.rd %0d\nOWCOV sva axil.aw_wait %0d\nOWCOV sva axil.ar_wait %0d",
                 n_c_wr, n_c_rd, n_c_aw_wait, n_c_b_wait);
endinterface
