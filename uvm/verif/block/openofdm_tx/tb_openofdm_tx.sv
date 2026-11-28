// Block TB top: openofdm_tx. Single clock (= AXI clock in the chip, NUM_CLK_PER_US MHz).
// NOTE: run from a directory containing icmem_{8,16,32,64}.mem (ifftmain.v $readmemh's
// them by relative path) -- the Makefile links them.
`timescale 1ns/1ps
module tb_openofdm_tx;
  import uvm_pkg::*;
  import openofdm_tx_tb_pkg::*;

  localparam real CLK_MHZ = `NUM_CLK_PER_US;
  logic clk = 0, rst_n = 0;
  always #(500.0 / CLK_MHZ) clk = ~clk;
  initial begin repeat (20) @(posedge clk); rst_n <= 1; end

  axil_if   axil (clk, rst_n);
  phy_tx_if ptx  (clk, rst_n);
  iq_if     iqo  (clk, rst_n);

  // I/Q output -> monitor bus ({I,Q} in [31:0], strobe = result_iq_valid)
  assign iqo.data  = {32'h0, ptx.result_i, ptx.result_q};
  assign iqo.valid = ptx.result_iq_valid;
  assign iqo.ready = ~ptx.tx_hold;

  openofdm_tx dut (
    .clk(clk), .phy_tx_arestn(rst_n),
    .phy_tx_start(ptx.phy_tx_start), .phy_tx_done(ptx.phy_tx_done), .phy_tx_started(ptx.phy_tx_started),
    .bram_din(ptx.bram_din), .bram_addr(ptx.bram_addr),
    .result_iq_hold(ptx.tx_hold), .result_iq_valid(ptx.result_iq_valid),
    .result_i(ptx.result_i), .result_q(ptx.result_q),
    .s00_axi_aclk(clk), .s00_axi_aresetn(rst_n),
    .s00_axi_awaddr(axil.awaddr[6:0]), .s00_axi_awprot(axil.awprot), .s00_axi_awvalid(axil.awvalid), .s00_axi_awready(axil.awready),
    .s00_axi_wdata(axil.wdata), .s00_axi_wstrb(axil.wstrb), .s00_axi_wvalid(axil.wvalid), .s00_axi_wready(axil.wready),
    .s00_axi_bresp(axil.bresp), .s00_axi_bvalid(axil.bvalid), .s00_axi_bready(axil.bready),
    .s00_axi_araddr(axil.araddr[6:0]), .s00_axi_arprot(axil.arprot), .s00_axi_arvalid(axil.arvalid), .s00_axi_arready(axil.arready),
    .s00_axi_rdata(axil.rdata), .s00_axi_rresp(axil.rresp), .s00_axi_rvalid(axil.rvalid), .s00_axi_rready(axil.rready));

  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.env.axil*", "vif", axil);
    uvm_config_db#(virtual phy_tx_if)::set(null, "uvm_test_top.env.ptx*", "vif", ptx);
    uvm_config_db#(virtual iq_if)::set(null, "uvm_test_top.env.iqm*", "vif", iqo);
    run_test("otx_random_test");
  end
  final ow_cov_pkg::ow_cov::dump();   // functional coverage lines for cov_report.py
endmodule
