// Block TB top: rx_intf. Clocks: AXI/core (NUM_CLK_PER_US MHz) and adc_clk (40 MHz).
`timescale 1ns/1ps
module tb_rx_intf;
  import uvm_pkg::*;
  import rx_intf_tb_pkg::*;

  localparam real CLK_MHZ = `NUM_CLK_PER_US;
  logic clk = 0, rst_n = 0, adc_clk = 0, adc_rst = 1;
  always #(500.0 / CLK_MHZ) clk = ~clk;
  always #12.5 adc_clk = ~adc_clk;                 // 40 MHz
  initial begin repeat (20) @(posedge clk); rst_n <= 1; end
  initial begin repeat (10) @(posedge adc_clk); adc_rst <= 0; end

  axil_if    axil (clk, rst_n);
  axis_if    dma  (clk, rst_n);
  // AXI DMA S2MM IOC interrupt: rises after each TLAST handshake on the RX stream and stays
  // high a few clocks (the driver's ISR clears it); rx_intf delays rx_pkt_intr from its edge
  logic s2mm_intr = 0; int unsigned s2mm_hold = 0;
  always @(posedge clk) begin
    if (dma.tvalid && dma.tready && dma.tlast) s2mm_hold <= 20;
    else if (s2mm_hold) s2mm_hold <= s2mm_hold - 1;
    s2mm_intr <= (s2mm_hold != 0);
  end
  assign dma.hold_waive = !dut.rx_intf_m_axis_i.M_AXIS_ARESETN;   // finding I
  final if (dma.n_valid_withdrawn) $display("NOTE finding I: rx_intf withdrew TVALID under a stalled DMA %0d time(s) (TLAST timeout / M_AXIS reset)", dma.n_valid_withdrawn);
  initial dma.tlast_waive = 1;   // finding H: rx_intf_m_axis TLAST follows TREADY
  final if (dma.n_tlast_unstable) $display("NOTE finding H: rx_intf TLAST changed during %0d stalls (waived)", dma.n_tlast_unstable);
  iq_if      adc  (adc_clk, !adc_rst);
  iq_if      bb   (clk, rst_n);
  iq_if      txl  (clk, rst_n);       // tx_intf I/Q for the internal loopback (IQ_SRC_SEL[8])
  phy_rx_if  prx  (clk, rst_n);
  irq_if     irq  (clk, rst_n);
  rx_side_if side (clk, rst_n, prx.pkt_header_valid_strobe, prx.byte_out_strobe, prx.fcs_out_strobe);

  logic [31:0] sample0;
  assign bb.data = {32'h0, sample0};
  assign bb.ready = 1'b1;
  assign txl.ready = 1'b1;

  rx_intf dut (
    .trigger_out0(), .trigger_out1(), .trigger_out2(), .trigger_out3(),
    .trigger_out4(), .trigger_out5(), .trigger_out6(), .trigger_out7(),
    .gpio_status_rf(8'h00), .gpio_status_bb(), .gpio_status_bb_raw(),
    .adc_clk(adc_clk), .adc_rst(adc_rst), .adc_data(adc.data), .adc_valid(adc.valid),
    .iq0_from_tx_intf(txl.data[31:0]), .iq1_from_tx_intf(txl.data[63:32]), .iq_valid_from_tx_intf(txl.valid),
    .sample0(sample0), .sample1(), .sample_strobe(bb.valid),
    .pkt_header_valid(prx.pkt_header_valid), .pkt_header_valid_strobe(prx.pkt_header_valid_strobe),
    .ht_unsupport(prx.ht_unsupport), .pkt_rate(prx.pkt_rate), .pkt_len(prx.pkt_len),
    .ht_aggr(prx.ht_aggr), .ht_aggr_last(prx.ht_aggr_last), .ht_sgi(prx.ht_sgi),
    .byte_in_strobe(prx.byte_out_strobe), .byte_in(prx.byte_out), .byte_count(prx.byte_count),
    .fcs_in_strobe(prx.fcs_out_strobe), .fcs_ok(prx.fcs_ok), .phase_offset_taken(32'sd0),
    .fcs_ok_led(), .rx_pkt_intr(irq.rx_pkt_intr), .s2mm_intr(s2mm_intr),
    .mute_adc_out_to_bb(side.mute_adc_out_to_bb),
    .block_rx_dma_to_ps(side.block_rx_dma_to_ps), .block_rx_dma_to_ps_valid(side.block_rx_dma_to_ps_valid),
    .rssi_half_db_lock_by_sig_valid(side.rssi_half_db_lock_by_sig_valid),
    .gpio_status_lock_by_sig_valid(side.gpio_status_lock_by_sig_valid),
    .tsf_runtime_val(side.tsf), .tsf_pulse_1M(side.tsf_pulse_1M),
    .s00_axi_aclk(clk), .s00_axi_aresetn(rst_n),
    .s00_axi_awaddr(axil.awaddr[6:0]), .s00_axi_awprot(axil.awprot), .s00_axi_awvalid(axil.awvalid), .s00_axi_awready(axil.awready),
    .s00_axi_wdata(axil.wdata), .s00_axi_wstrb(axil.wstrb), .s00_axi_wvalid(axil.wvalid), .s00_axi_wready(axil.wready),
    .s00_axi_bresp(axil.bresp), .s00_axi_bvalid(axil.bvalid), .s00_axi_bready(axil.bready),
    .s00_axi_araddr(axil.araddr[6:0]), .s00_axi_arprot(axil.arprot), .s00_axi_arvalid(axil.arvalid), .s00_axi_arready(axil.arready),
    .s00_axi_rdata(axil.rdata), .s00_axi_rresp(axil.rresp), .s00_axi_rvalid(axil.rvalid), .s00_axi_rready(axil.rready),
    .m00_axis_aclk(clk), .m00_axis_aresetn(rst_n),
    .m00_axis_tvalid(dma.tvalid), .m00_axis_tdata(dma.tdata), .m00_axis_tstrb(dma.tstrb),
    .m00_axis_tlast(dma.tlast), .m00_axis_tready(dma.tready));

  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.env.axil*", "vif", axil);
    uvm_config_db#(virtual axis_if)::set(null, "uvm_test_top.env.dma*", "vif", dma);
    uvm_config_db#(virtual iq_if)::set(null, "uvm_test_top.env.adc*", "vif", adc);
    uvm_config_db#(virtual iq_if)::set(null, "uvm_test_top.env.bb*", "vif", bb);
    uvm_config_db#(virtual iq_if)::set(null, "uvm_test_top.env.txl*", "vif", txl);
    uvm_config_db#(virtual phy_rx_if)::set(null, "uvm_test_top.env.prx*", "vif", prx);
    uvm_config_db#(virtual rx_side_if)::set(null, "uvm_test_top.env", "side", side);
    uvm_config_db#(virtual irq_if)::set(null, "uvm_test_top.env", "irq", irq);
    run_test("rxi_frames_test");
  end
  // +RXI_TRACE: DMA state machine and its inputs, for debugging the TB
  initial if ($test$plusargs("RXI_TRACE")) forever begin
    @(dut.rx_intf_pl_to_m_axis_i.rx_state or dut.rx_intf_pl_to_m_axis_i.start_1trans_to_m_axis
      or dut.rx_intf_pl_to_m_axis_i.block_rx_dma_to_ps_valid);
    #0 $display("%t RXI_TRACE state %0d start %b blk_valid %b blk %b mode %0d tvalid %b tready %b", $time,
      dut.rx_intf_pl_to_m_axis_i.rx_state, dut.rx_intf_pl_to_m_axis_i.start_1trans_to_m_axis,
      dut.rx_intf_pl_to_m_axis_i.block_rx_dma_to_ps_valid, dut.rx_intf_pl_to_m_axis_i.block_rx_dma_to_ps,
      dut.rx_intf_pl_to_m_axis_i.start_1trans_mode, dut.m00_axis_tvalid, dut.m00_axis_tready);
  end
endmodule
