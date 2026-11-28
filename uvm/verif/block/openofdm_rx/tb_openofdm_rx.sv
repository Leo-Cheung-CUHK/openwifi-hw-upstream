// Block TB top: openofdm_rx. Core clock = AXI clock (NUM_CLK_PER_US MHz).
// Needs the Xilinx IP simulation models used by dot11 (xfft_v9, viterbi_v7_0,
// complex_multiplier, div_gen*, atan_lut, rot_lut, deinter_lut): see docs/ARCHITECTURE.md
// "Xilinx IP models". Use the zynquplus .xci set for RFSoC.
`timescale 1ns/1ps
module tb_openofdm_rx;
  import uvm_pkg::*;
  import openofdm_rx_tb_pkg::*;

  localparam real CLK_MHZ = `NUM_CLK_PER_US;
  logic clk = 0, rst_n = 0;
  always #(500.0 / CLK_MHZ) clk = ~clk;
  initial begin repeat (20) @(posedge clk); rst_n <= 1; end

  axil_if   axil (clk, rst_n);
  iq_if     iq   (clk, rst_n);
  phy_rx_if prx  (clk, rst_n);

  // RSSI normally comes from xpu (iq_rssi_to_db); a constant strong level here.
  // +RSSI_HALF_DB=<n> to test the sensitivity threshold (SOFT_DECODING / POWER_THRES).
  logic signed [10:0] rssi = 11'sd0;     // same as openofdm_rx/verilog/dot11_tb.v
  initial void'($value$plusargs("RSSI_HALF_DB=%d", rssi));
  assign prx.rssi_half_db = rssi;

  openofdm_rx dut (
    .trigger_mode_setting_en(1'b0), .para_valid(1'b0), .para_rx_sensitivity_th('0),
    .rssi_half_db(rssi), .sample_in(iq.data[31:0]), .sample_in_strobe(iq.valid), .Fc_in_MHz(16'd5220),
    .demod_is_ongoing(prx.demod_is_ongoing),
    .short_preamble_detected(prx.short_preamble_detected), .long_preamble_detected(prx.long_preamble_detected),
    .pkt_header_valid(prx.pkt_header_valid), .pkt_header_valid_strobe(prx.pkt_header_valid_strobe),
    .ht_unsupport(prx.ht_unsupport), .pkt_rate(prx.pkt_rate), .pkt_len(prx.pkt_len),
    .ht_aggr(prx.ht_aggr), .ht_aggr_last(prx.ht_aggr_last), .ht_sgi(prx.ht_sgi),
    .byte_out_strobe(prx.byte_out_strobe), .byte_out(prx.byte_out), .byte_count(prx.byte_count),
    .fcs_out_strobe(prx.fcs_out_strobe), .fcs_ok(prx.fcs_ok),
    .csi(prx.csi), .csi_valid(prx.csi_valid), .phase_offset_taken(prx.phase_offset_taken),
    .equalizer(prx.equalizer), .equalizer_valid(prx.equalizer_valid), .ofdm_symbol_eq_out_pulse(prx.ofdm_symbol_eq_out_pulse),
    .n_ofdm_sym(prx.n_ofdm_sym), .n_bit_in_last_sym(prx.n_bit_in_last_sym), .phy_len_valid(prx.phy_len_valid),
    .s00_axi_aclk(clk), .s00_axi_aresetn(rst_n),
    .s00_axi_awaddr(axil.awaddr[6:0]), .s00_axi_awprot(axil.awprot), .s00_axi_awvalid(axil.awvalid), .s00_axi_awready(axil.awready),
    .s00_axi_wdata(axil.wdata), .s00_axi_wstrb(axil.wstrb), .s00_axi_wvalid(axil.wvalid), .s00_axi_wready(axil.wready),
    .s00_axi_bresp(axil.bresp), .s00_axi_bvalid(axil.bvalid), .s00_axi_bready(axil.bready),
    .s00_axi_araddr(axil.araddr[6:0]), .s00_axi_arprot(axil.arprot), .s00_axi_arvalid(axil.arvalid), .s00_axi_arready(axil.arready),
    .s00_axi_rdata(axil.rdata), .s00_axi_rresp(axil.rresp), .s00_axi_rvalid(axil.rvalid), .s00_axi_rready(axil.rready));

  // +VIT_TRACE: one line per Viterbi run (between two decoder resets): inputs, outputs, latency
  // of the first output, a hash of the inputs and the first 256 decoded bits. Compares the
  // Xilinx viterbi_v7_0 model with ip/sova_dec (VIT=sova) on the same stimulus.
  bit vit_trace;
  initial vit_trace = $test$plusargs("VIT_TRACE");
  int unsigned vt_seg, vt_in, vt_out, vt_cyc, vt_lat; bit [31:0] vt_hash; bit [255:0] vt_bits;
  always @(posedge clk) if (vit_trace) begin
    if (dut.dot11_i.ofdm_decoder_inst.vit_clr) begin
      if (vt_in) $display("VIT seg %0d @%0t: in=%0d out=%0d lat=%0d inhash=%08h bits=%064h", vt_seg, $time,
                          vt_in, vt_out, vt_lat, vt_hash, vt_bits);
      if (vt_in) vt_seg++;
      vt_in = 0; vt_out = 0; vt_cyc = 0; vt_lat = 0; vt_hash = 32'h811c9dc5; vt_bits = '0;
    end else begin
      vt_cyc++;
      if (dut.dot11_i.ofdm_decoder_inst.conv_in_stb_dly) begin
        vt_hash = (vt_hash ^ {24'b0, dut.dot11_i.ofdm_decoder_inst.conv_erase_dly,
                   dut.dot11_i.ofdm_decoder_inst.conv_in1_dly, dut.dot11_i.ofdm_decoder_inst.conv_in0_dly}) * 32'h01000193;
        vt_in++;
      end
      if (dut.dot11_i.ofdm_decoder_inst.m_axis_data_tvalid) begin
        if (vt_out == 0) vt_lat = vt_cyc;
        if (vt_out < 256) vt_bits[255 - vt_out] = dut.dot11_i.ofdm_decoder_inst.conv_decoder_out;
        vt_out++;
      end
    end
  end

  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.env.axil*", "vif", axil);
    uvm_config_db#(virtual iq_if)::set(null, "uvm_test_top.env.iq*", "vif", iq);
    uvm_config_db#(virtual phy_rx_if)::set(null, "uvm_test_top.env.prx*", "vif", prx);
    run_test("orx_vectors_test");
  end
  final ow_cov_pkg::ow_cov::dump();   // functional coverage lines for cov_report.py
endmodule
