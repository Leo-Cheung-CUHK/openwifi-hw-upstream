// Block TB top: side_ch. Single clock domain (AXI/core).
`timescale 1ns/1ps

module tb_side_ch;
  import uvm_pkg::*;
  import side_ch_tb_pkg::*;

  localparam real CLK_MHZ = `NUM_CLK_PER_US;
  logic clk = 0, rst_n = 0;
  always #(500.0 / CLK_MHZ) clk = ~clk;
  initial begin repeat (20) @(posedge clk); rst_n <= 1; end

  axil_if         axil (clk, rst_n);
  axis_if         dma  (clk, rst_n);
  initial dma.tlast_waive = 1;   // finding H: side_ch_m_axis TLAST follows TREADY (same template as rx_intf)
  final if (dma.n_tlast_unstable) $display("NOTE finding H: side_ch TLAST changed during %0d stalls (waived)", dma.n_tlast_unstable);
  phy_rx_if       prx  (clk, rst_n);
  side_ch_side_if side (clk, rst_n, prx.pkt_header_valid_strobe, prx.byte_out_strobe, prx.byte_out);
  assign prx.rssi_half_db = -11'sd100;

  side_ch dut (
    .gpio_status(8'h00), .rssi_half_db(prx.rssi_half_db), .tsf_runtime_val(side.tsf),
    .openofdm_tx_iq0(32'd0), .openofdm_tx_iq1(32'd0), .openofdm_tx_iq_valid(1'b0),
    .tx_intf_iq0(32'd0), .tx_intf_iq1(32'd0), .tx_intf_iq_valid(1'b0),
    .sample0_in(side.sample0), .sample1_in(32'd0), .sample_in_strobe(side.sample_strobe),
    .demod_is_ongoing(prx.demod_is_ongoing), .ofdm_symbol_eq_out_pulse(prx.ofdm_symbol_eq_out_pulse),
    .long_preamble_detected(prx.long_preamble_detected), .short_preamble_detected(prx.short_preamble_detected),
    .ht_unsupport(prx.ht_unsupport), .pkt_rate(prx.pkt_rate), .pkt_len(prx.pkt_len),
    .csi(prx.csi), .csi_valid(prx.csi_valid), .phase_offset_taken(prx.phase_offset_taken),
    .equalizer(prx.equalizer), .equalizer_valid(prx.equalizer_valid),
    .pkt_header_valid(prx.pkt_header_valid), .pkt_header_valid_strobe(prx.pkt_header_valid_strobe),
    .phy_type({1'b0, prx.pkt_rate[7]}),
    .tx_control_state(4'd0), .FC_DI(side.fc_di), .FC_DI_valid(side.fc_di_valid),
    .addr1(side.addr1), .addr1_valid(side.addr1_valid), .addr2(side.addr2), .addr2_valid(side.addr2_valid), .addr3(48'd0), .addr3_valid(1'b0),
    .pkt_for_me(1'b1), .fcs_in_strobe(prx.fcs_out_strobe), .fcs_ok(prx.fcs_ok),
    .block_rx_dma_to_ps(1'b0), .block_rx_dma_to_ps_valid(1'b0), .ch_idle_final(1'b1),
    .phy_tx_start(1'b0), .tx_pkt_need_ack(1'b0), .phy_tx_started(1'b0), .phy_tx_done(1'b0),
    .tx_bb_is_ongoing(1'b0), .tx_rf_is_ongoing(1'b0), .tx_pkt_iq_to_dac_ongoing(1'b0), .retrans_in_progress(1'b0),
    .m00_axis_aclk(clk), .m00_axis_aresetn(rst_n),
    .m00_axis_tvalid(dma.tvalid), .m00_axis_tdata(dma.tdata), .m00_axis_tstrb(dma.tstrb),
    .m00_axis_tlast(dma.tlast), .m00_axis_tready(dma.tready),
    .s00_axis_aclk(clk), .s00_axis_aresetn(rst_n), .s00_axis_tready(),
    .s00_axis_tdata(64'd0), .s00_axis_tstrb(8'd0), .s00_axis_tlast(1'b0), .s00_axis_tvalid(1'b0),
    .s00_axi_aclk(clk), .s00_axi_aresetn(rst_n),
    .s00_axi_awaddr(axil.awaddr[6:0]), .s00_axi_awprot(axil.awprot), .s00_axi_awvalid(axil.awvalid), .s00_axi_awready(axil.awready),
    .s00_axi_wdata(axil.wdata), .s00_axi_wstrb(axil.wstrb), .s00_axi_wvalid(axil.wvalid), .s00_axi_wready(axil.wready),
    .s00_axi_bresp(axil.bresp), .s00_axi_bvalid(axil.bvalid), .s00_axi_bready(axil.bready),
    .s00_axi_araddr(axil.araddr[6:0]), .s00_axi_arprot(axil.arprot), .s00_axi_arvalid(axil.arvalid), .s00_axi_arready(axil.arready),
    .s00_axi_rdata(axil.rdata), .s00_axi_rresp(axil.rresp), .s00_axi_rvalid(axil.rvalid), .s00_axi_rready(axil.rready));

  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.env.axil*", "vif", axil);
    uvm_config_db#(virtual axis_if)::set(null, "uvm_test_top.env.dma*", "vif", dma);
    uvm_config_db#(virtual phy_rx_if)::set(null, "uvm_test_top.env.prx*", "vif", prx);
    uvm_config_db#(virtual side_ch_side_if)::set(null, "uvm_test_top.env", "side", side);
    run_test("sch_csi_test");
  end
endmodule
