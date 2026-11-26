// Chip-level TB top.
//   DUT  : openwifi_core_top (generated from system.bd by scripts/gen_core_top.py)
//   peer : openofdm_tx + openofdm_rx instances acting as the other station
// Clocks: clk = PS FCLK / AXI / core (NUM_CLK_PER_US MHz), adc_clk = 40 MHz shared by
// ADC and DAC (as util_ad9361_divclk does on the AD9361 boards; on RFSoC the RF-DC adapter
// must present the same 40 MHz / 2 x 20 Msps interface -- see ARCHITECTURE.md).
`timescale 1ns/1ps
module tb_chip;
  import uvm_pkg::*;
  import chip_tb_pkg::*;

  localparam real CLK_MHZ = `NUM_CLK_PER_US;
  logic clk = 0, rst_n = 0, adc_clk = 0, adc_rst = 1, ps_clk = 0;
  always #(500.0 / CLK_MHZ) clk = ~clk;
  always #12.5 adc_clk = ~adc_clk;
  always #5 ps_clk = ~ps_clk;
  initial begin repeat (20) @(posedge clk); rst_n <= 1; end
  initial begin repeat (10) @(posedge adc_clk); adc_rst <= 0; end

  // ---------------- host side
  axil_if axil   (clk, rst_n);
  axis_if dma_tx (clk, rst_n);   // axi_dma_0 MM2S -> tx_intf
  axis_if dma_rx (clk, rst_n);   // rx_intf -> axi_dma_1 S2MM
  axis_if dma_sch(clk, rst_n);   // side_ch -> axi_dma_0 S2MM
  irq_if  irq    (clk, rst_n);
  // ---------------- RF side
  iq_if   adc    (adc_clk, !adc_rst);
  iq_if   dac    (adc_clk, !adc_rst);
  assign dac.valid = 1'b1;
  assign dac.ready = 1'b1;

  openwifi_core_top dut (
    .clk(clk), .aresetn(rst_n), .ps_clk(ps_clk),
    .adc_clk(adc_clk), .adc_rst(adc_rst), .adc_data(adc.data), .adc_valid(adc.valid),
    .dac_data(dac.data), .dac_valid(), .dac_ready(1'b1),
    .gpio_status(8'h00),
    .spi0_csn(1'b1), .spi0_mosi(1'b0), .spi0_sclk(1'b0), .spi_csn(), .spi_mosi(), .spi_sclk(),
    .rx_pkt_intr(irq.rx_pkt_intr), .tx_itrpt(irq.tx_itrpt), .dma1_s2mm_intr(1'b0),
    .led0(), .led1(), .led2(), .led3(), .gpio_pmod1_0(), .gpio_pmod1_1(), .gpio_pmod1_2(),
    .s_axis_tx_tready(dma_tx.tready), .s_axis_tx_tdata(dma_tx.tdata), .s_axis_tx_tstrb(dma_tx.tstrb),
    .s_axis_tx_tlast(dma_tx.tlast), .s_axis_tx_tvalid(dma_tx.tvalid),
    .m_axis_rx_tvalid(dma_rx.tvalid), .m_axis_rx_tdata(dma_rx.tdata), .m_axis_rx_tstrb(dma_rx.tstrb),
    .m_axis_rx_tlast(dma_rx.tlast), .m_axis_rx_tready(dma_rx.tready),
    .m_axis_sidech_tvalid(dma_sch.tvalid), .m_axis_sidech_tdata(dma_sch.tdata), .m_axis_sidech_tstrb(dma_sch.tstrb),
    .m_axis_sidech_tlast(dma_sch.tlast), .m_axis_sidech_tready(dma_sch.tready),
    .s_axis_sidech_tready(), .s_axis_sidech_tdata(64'd0), .s_axis_sidech_tstrb(8'd0),
    .s_axis_sidech_tlast(1'b0), .s_axis_sidech_tvalid(1'b0),
    .s_axil_awaddr(axil.awaddr), .s_axil_awprot(axil.awprot), .s_axil_awvalid(axil.awvalid), .s_axil_awready(axil.awready),
    .s_axil_wdata(axil.wdata), .s_axil_wstrb(axil.wstrb), .s_axil_wvalid(axil.wvalid), .s_axil_wready(axil.wready),
    .s_axil_bresp(axil.bresp), .s_axil_bvalid(axil.bvalid), .s_axil_bready(axil.bready),
    .s_axil_araddr(axil.araddr), .s_axil_arprot(axil.arprot), .s_axil_arvalid(axil.arvalid), .s_axil_arready(axil.arready),
    .s_axil_rdata(axil.rdata), .s_axil_rresp(axil.rresp), .s_axil_rvalid(axil.rvalid), .s_axil_rready(axil.rready));

  // ---------------- white-box taps (passive monitors only)
  phy_rx_if core_rx (clk, rst_n);
  phy_tx_if core_tx (clk, rst_n);
  assign core_rx.demod_is_ongoing        = dut.openofdm_rx_demod_is_ongoing;
  assign core_rx.short_preamble_detected = dut.openofdm_rx_short_preamble_detected;
  assign core_rx.long_preamble_detected  = dut.openofdm_rx_long_preamble_detected;
  assign core_rx.pkt_header_valid        = dut.openofdm_rx_pkt_header_valid;
  assign core_rx.pkt_header_valid_strobe = dut.openofdm_rx_pkt_header_valid_strobe;
  assign core_rx.ht_unsupport            = dut.openofdm_rx_ht_unsupport;
  assign core_rx.pkt_rate                = dut.openofdm_rx_pkt_rate;
  assign core_rx.pkt_len                 = dut.openofdm_rx_pkt_len;
  assign core_rx.ht_aggr                 = dut.openofdm_rx_ht_aggr;
  assign core_rx.ht_aggr_last            = dut.openofdm_rx_ht_aggr_last;
  assign core_rx.ht_sgi                  = dut.openofdm_rx_ht_sgi;
  assign core_rx.byte_out_strobe         = dut.openofdm_rx_byte_out_strobe;
  assign core_rx.byte_out                = dut.openofdm_rx_byte_out;
  assign core_rx.byte_count              = dut.openofdm_rx_byte_count;
  assign core_rx.fcs_out_strobe          = dut.openofdm_rx_fcs_out_strobe;
  assign core_rx.fcs_ok                  = dut.openofdm_rx_fcs_ok;
  assign core_rx.rssi_half_db            = dut.xpu_rssi_half_db;
  assign core_tx.phy_tx_start    = dut.tx_intf_phy_tx_start;
  assign core_tx.tx_hold         = dut.tx_intf_tx_hold;
  assign core_tx.bram_addr       = dut.openofdm_tx_bram_addr;
  assign core_tx.bram_din        = dut.tx_intf_data_to_acc;
  assign core_tx.result_i        = dut.openofdm_tx_result_i;
  assign core_tx.result_q        = dut.openofdm_tx_result_q;
  assign core_tx.result_iq_valid = dut.openofdm_tx_result_iq_valid;
  assign core_tx.phy_tx_started  = dut.openofdm_tx_phy_tx_started;
  assign core_tx.phy_tx_done     = dut.openofdm_tx_phy_tx_done;

  // ---------------- peer station
  axil_if   peer_tx_axil (clk, rst_n);
  axil_if   peer_rx_axil (clk, rst_n);
  phy_tx_if peer_ptx (clk, rst_n);
  iq_if     peer_tx_iq (clk, rst_n);
  phy_rx_if peer_prx (clk, rst_n);
  assign peer_tx_iq.data  = {32'h0, peer_ptx.result_i, peer_ptx.result_q};
  assign peer_tx_iq.valid = peer_ptx.result_iq_valid;
  assign peer_tx_iq.ready = ~peer_ptx.tx_hold;

  openofdm_tx peer_tx (
    .clk(clk), .phy_tx_arestn(rst_n),
    .phy_tx_start(peer_ptx.phy_tx_start), .phy_tx_done(peer_ptx.phy_tx_done), .phy_tx_started(peer_ptx.phy_tx_started),
    .bram_din(peer_ptx.bram_din), .bram_addr(peer_ptx.bram_addr),
    .result_iq_hold(peer_ptx.tx_hold), .result_iq_valid(peer_ptx.result_iq_valid),
    .result_i(peer_ptx.result_i), .result_q(peer_ptx.result_q),
    .s00_axi_aclk(clk), .s00_axi_aresetn(rst_n),
    .s00_axi_awaddr(peer_tx_axil.awaddr[6:0]), .s00_axi_awprot(peer_tx_axil.awprot), .s00_axi_awvalid(peer_tx_axil.awvalid), .s00_axi_awready(peer_tx_axil.awready),
    .s00_axi_wdata(peer_tx_axil.wdata), .s00_axi_wstrb(peer_tx_axil.wstrb), .s00_axi_wvalid(peer_tx_axil.wvalid), .s00_axi_wready(peer_tx_axil.wready),
    .s00_axi_bresp(peer_tx_axil.bresp), .s00_axi_bvalid(peer_tx_axil.bvalid), .s00_axi_bready(peer_tx_axil.bready),
    .s00_axi_araddr(peer_tx_axil.araddr[6:0]), .s00_axi_arprot(peer_tx_axil.arprot), .s00_axi_arvalid(peer_tx_axil.arvalid), .s00_axi_arready(peer_tx_axil.arready),
    .s00_axi_rdata(peer_tx_axil.rdata), .s00_axi_rresp(peer_tx_axil.rresp), .s00_axi_rvalid(peer_tx_axil.rvalid), .s00_axi_rready(peer_tx_axil.rready));

  logic [31:0] peer_rx_sample; logic peer_rx_strobe;
  dac_to_peer_rx u_dac2peer (.dac_clk(adc_clk), .dac_rst(adc_rst), .dac_data(dac.data),
                             .clk(clk), .rst_n(rst_n), .sample(peer_rx_sample), .strobe(peer_rx_strobe));
  assign peer_prx.rssi_half_db = 11'sd0;

  openofdm_rx peer_rx (
    .trigger_mode_setting_en(1'b0), .para_valid(1'b0), .para_rx_sensitivity_th('0),
    .rssi_half_db(11'sd0), .sample_in(peer_rx_sample), .sample_in_strobe(peer_rx_strobe), .Fc_in_MHz(16'd5220),
    .demod_is_ongoing(peer_prx.demod_is_ongoing),
    .short_preamble_detected(peer_prx.short_preamble_detected), .long_preamble_detected(peer_prx.long_preamble_detected),
    .pkt_header_valid(peer_prx.pkt_header_valid), .pkt_header_valid_strobe(peer_prx.pkt_header_valid_strobe),
    .ht_unsupport(peer_prx.ht_unsupport), .pkt_rate(peer_prx.pkt_rate), .pkt_len(peer_prx.pkt_len),
    .ht_aggr(peer_prx.ht_aggr), .ht_aggr_last(peer_prx.ht_aggr_last), .ht_sgi(peer_prx.ht_sgi),
    .byte_out_strobe(peer_prx.byte_out_strobe), .byte_out(peer_prx.byte_out), .byte_count(peer_prx.byte_count),
    .fcs_out_strobe(peer_prx.fcs_out_strobe), .fcs_ok(peer_prx.fcs_ok),
    .csi(), .csi_valid(), .phase_offset_taken(), .equalizer(), .equalizer_valid(), .ofdm_symbol_eq_out_pulse(),
    .n_ofdm_sym(), .n_bit_in_last_sym(), .phy_len_valid(),
    .s00_axi_aclk(clk), .s00_axi_aresetn(rst_n),
    .s00_axi_awaddr(peer_rx_axil.awaddr[6:0]), .s00_axi_awprot(peer_rx_axil.awprot), .s00_axi_awvalid(peer_rx_axil.awvalid), .s00_axi_awready(peer_rx_axil.awready),
    .s00_axi_wdata(peer_rx_axil.wdata), .s00_axi_wstrb(peer_rx_axil.wstrb), .s00_axi_wvalid(peer_rx_axil.wvalid), .s00_axi_wready(peer_rx_axil.wready),
    .s00_axi_bresp(peer_rx_axil.bresp), .s00_axi_bvalid(peer_rx_axil.bvalid), .s00_axi_bready(peer_rx_axil.bready),
    .s00_axi_araddr(peer_rx_axil.araddr[6:0]), .s00_axi_arprot(peer_rx_axil.arprot), .s00_axi_arvalid(peer_rx_axil.arvalid), .s00_axi_arready(peer_rx_axil.arready),
    .s00_axi_rdata(peer_rx_axil.rdata), .s00_axi_rresp(peer_rx_axil.rresp), .s00_axi_rvalid(peer_rx_axil.rvalid), .s00_axi_rready(peer_rx_axil.rready));

  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.env.axil*", "vif", axil);
    uvm_config_db#(virtual axis_if)::set(null, "uvm_test_top.env.dma_tx*", "vif", dma_tx);
    uvm_config_db#(virtual axis_if)::set(null, "uvm_test_top.env.dma_rx*", "vif", dma_rx);
    uvm_config_db#(virtual axis_if)::set(null, "uvm_test_top.env.dma_sch*", "vif", dma_sch);
    uvm_config_db#(virtual iq_if)::set(null, "uvm_test_top.env.adc*", "vif", adc);
    uvm_config_db#(virtual iq_if)::set(null, "uvm_test_top.env.dac*", "vif", dac);
    uvm_config_db#(virtual phy_rx_if)::set(null, "uvm_test_top.env.core_rx*", "vif", core_rx);
    uvm_config_db#(virtual phy_tx_if)::set(null, "uvm_test_top.env.core_tx*", "vif", core_tx);
    uvm_config_db#(virtual irq_if)::set(null, "uvm_test_top.env", "irq", irq);
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.env.peer.tx_axil*", "vif", peer_tx_axil);
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.env.peer.rx_axil*", "vif", peer_rx_axil);
    uvm_config_db#(virtual phy_tx_if)::set(null, "uvm_test_top.env.peer.ptx*", "vif", peer_ptx);
    uvm_config_db#(virtual iq_if)::set(null, "uvm_test_top.env.peer.tx_iq*", "vif", peer_tx_iq);
    uvm_config_db#(virtual phy_rx_if)::set(null, "uvm_test_top.env.peer.prx*", "vif", peer_prx);
    run_test("chip_tx_test");
  end
endmodule
