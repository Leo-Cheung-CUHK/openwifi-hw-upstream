// Block TB top: xpu. Clocks: AXI/core (NUM_CLK_PER_US MHz) and ps_clk (SPI to AD9361).
`timescale 1ns/1ps
module tb_xpu;
  import uvm_pkg::*;
  import xpu_tb_pkg::*;

  localparam real CLK_MHZ = `NUM_CLK_PER_US;
  logic clk = 0, rst_n = 0, ps_clk = 0;
  always #(500.0 / CLK_MHZ) clk = ~clk;
  always #5 ps_clk = ~ps_clk;
  initial begin repeat (20) @(posedge clk); rst_n <= 1; end

  axil_if        axil (clk, rst_n);
  phy_rx_if      prx  (clk, rst_n);
  iq_if          ddc  (clk, rst_n);
  xpu_tx_side_if txs  (clk, rst_n);

  xpu dut (
    .gpio_status(8'h00),
    .ddc_i(ddc.data[31:16]), .ddc_q(ddc.data[15:0]), .ddc_iq_valid(ddc.valid),
    .mute_adc_out_to_bb(), .block_rx_dma_to_ps(txs.block_rx_dma_to_ps), .block_rx_dma_to_ps_valid(txs.block_rx_dma_to_ps_valid),
    .rssi_half_db_lock_by_sig_valid(txs.rssi_half_db_lock_by_sig_valid), .gpio_status_lock_by_sig_valid(),
    .tsf_runtime_val(), .tsf_pulse_1M(),
    .rssi_half_db(prx.rssi_half_db), .demod_is_ongoing(prx.demod_is_ongoing),
    .pkt_header_valid(prx.pkt_header_valid), .pkt_header_valid_strobe(prx.pkt_header_valid_strobe),
    .ht_unsupport(prx.ht_unsupport), .pkt_rate(prx.pkt_rate), .pkt_len(prx.pkt_len),
    .byte_in_strobe(prx.byte_out_strobe), .byte_in(prx.byte_out), .byte_count(prx.byte_count),
    .fcs_in_strobe(prx.fcs_out_strobe), .fcs_ok(prx.fcs_ok),
    .n_ofdm_sym(prx.n_ofdm_sym), .n_bit_in_last_sym(prx.n_bit_in_last_sym), .phy_len_valid(prx.phy_len_valid),
    .rx_ht_aggr(prx.ht_aggr), .rx_ht_aggr_last(prx.ht_aggr_last),
    .demod_is_ongoing_led(), .cycle_start0_led(), .phy_tx_started_led(), .sig_valid_led(),
    .phy_tx_start(txs.phy_tx_start), .phy_tx_started(txs.phy_tx_started), .phy_tx_done(txs.phy_tx_done),
    .tx_status(txs.tx_status), .mac_addr(), .retrans_in_progress(txs.retrans_in_progress),
    .start_retrans(txs.start_retrans), .start_tx_ack(txs.start_tx_ack), .tx_try_complete(txs.tx_try_complete),
    .tx_iq_fifo_empty(txs.tx_iq_fifo_empty), .slice_en(txs.slice_en), .backoff_done(txs.backoff_done),
    .tx_bb_is_ongoing(txs.tx_bb_is_ongoing), .tx_rf_is_ongoing(txs.tx_rf_is_ongoing),
    .ack_tx_flag(txs.ack_tx_flag), .wea(txs.wea), .addra(txs.addra), .dina(txs.dina),
    .tx_pkt_need_ack(txs.tx_pkt_need_ack), .tx_pkt_retrans_limit(txs.tx_pkt_retrans_limit), .tx_ht_aggr(1'b0), .douta(64'd0),
    .cts_toself_bb_is_ongoing(1'b0), .cts_toself_rf_is_ongoing(1'b0), .bram_addr(txs.bram_addr),
    .band(), .channel(), .quit_retrans(txs.quit_retrans), .reset_backoff(txs.reset_backoff),
    .tx_control_state(txs.tx_control_state), .tx_control_state_idle(txs.tx_control_state_idle),
    .num_slot_random(txs.num_slot_random), .cw(txs.cw), .high_trigger(txs.high_trigger), .tx_queue_idx(txs.tx_queue_idx),
    .FC_DI(), .FC_DI_valid(), .addr1(), .addr1_valid(), .addr2(), .addr2_valid(), .addr3(), .addr3_valid(),
    .pkt_for_me(txs.pkt_for_me), .ch_idle_final(txs.ch_idle_final),
    .ps_clk(ps_clk), .spi0_sclk(1'b0), .spi0_mosi(1'b0), .spi0_csn(1'b1), .spi_sclk(), .spi_csn(), .spi_mosi(),
    .s00_axi_aclk(clk), .s00_axi_aresetn(rst_n),
    .s00_axi_awaddr(axil.awaddr[7:0]), .s00_axi_awprot(axil.awprot), .s00_axi_awvalid(axil.awvalid), .s00_axi_awready(axil.awready),
    .s00_axi_wdata(axil.wdata), .s00_axi_wstrb(axil.wstrb), .s00_axi_wvalid(axil.wvalid), .s00_axi_wready(axil.wready),
    .s00_axi_bresp(axil.bresp), .s00_axi_bvalid(axil.bvalid), .s00_axi_bready(axil.bready),
    .s00_axi_araddr(axil.araddr[7:0]), .s00_axi_arprot(axil.arprot), .s00_axi_arvalid(axil.arvalid), .s00_axi_arready(axil.arready),
    .s00_axi_rdata(axil.rdata), .s00_axi_rresp(axil.rresp), .s00_axi_rvalid(axil.rvalid), .s00_axi_rready(axil.rready));

  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.env.axil*", "vif", axil);
    uvm_config_db#(virtual phy_rx_if)::set(null, "uvm_test_top.env.prx*", "vif", prx);
    uvm_config_db#(virtual iq_if)::set(null, "uvm_test_top.env.ddc*", "vif", ddc);
    uvm_config_db#(virtual xpu_tx_side_if)::set(null, "uvm_test_top.env", "txside", txs);
    run_test("xpu_ack_test");
  end
  // +XPU_TRACE: csma_ca state and channel-idle terms, for debugging the TB
  initial if ($test$plusargs("XPU_TRACE")) forever begin
    @(dut.csma_ca_i.backoff_state or dut.csma_ca_i.ch_idle_final or dut.tx_rf_is_ongoing or dut.tx_bb_is_ongoing
      or txs.phy_tx_done or txs.phy_tx_started or txs.tx_iq_fifo_empty or dut.tx_on_detection_i.search_indication or txs.tx_try_complete or txs.high_trigger);
    #0 $display("%t XPU_TRACE bo_state %0d ch_idle_final %b ch_idle %b nav %0d rssi %0d th %0d demod %b tx_rf %b tx_bb %b ack_cts %b wait %0d",
      $time, dut.csma_ca_i.backoff_state, dut.csma_ca_i.ch_idle_final, dut.ch_idle, dut.csma_ca_i.nav_for_mac,
      dut.cca_i.rssi_half_db, dut.cca_i.rssi_half_db_th, dut.cca_i.demod_is_ongoing, dut.tx_rf_is_ongoing, dut.tx_bb_is_ongoing,
      dut.cca_i.ack_cts_is_ongoing, dut.csma_ca_i.backoff_wait_timer);
    if ($test$plusargs("XPU_TRACE")) $display("%t XPU_TRACE2 started %b done %b fifo_empty %b search %b try_complete %b high_trigger %b", $time,
      txs.phy_tx_started, txs.phy_tx_done, txs.tx_iq_fifo_empty, dut.tx_on_detection_i.search_indication, txs.tx_try_complete, txs.high_trigger);
  end
  // ---- functional coverage (FLOW.md §3, merged by cov_report.py) ----
  // CSMA/CA backoff states, packet-filter rules that let a frame through, queue x need_ack
  localparam string CSMA_ST[7] = '{"IDLE", "CH_BUSY", "WAIT_1", "WAIT_2", "RUN", "SUSPEND", "WAIT_FOR_OWN"};
  localparam int    FLT_BIT[10] = '{1, 4, 5, 6, 7, 8, 9, 10, 11, 13};
  localparam string FLT_NAME[10] = '{"ALLMULTI", "BCN_PRBRESP_PROMISC", "CONTROL", "OTHER_BSS", "PSPOLL", "PROBE_REQ",
                                     "UNICAST_FOR_US", "BROADCAST_ALL_ONE", "BROADCAST_ALL_ZERO", "MONITOR_ALL"};
  initial begin
    foreach (CSMA_ST[i]) ow_cov_pkg::ow_cov::declare("xpu_csma_state", CSMA_ST[i]);
    foreach (FLT_NAME[i]) ow_cov_pkg::ow_cov::declare("xpu_filter", {FLT_NAME[i], ".pass"});
    ow_cov_pkg::ow_cov::declare("xpu_filter", "blocked");
    for (int q = 0; q < 4; q++) for (int a = 0; a < 2; a++) ow_cov_pkg::ow_cov::declare("xpu_tx_queue", $sformatf("q%0d_ack%0d", q, a));
  end
  logic [2:0] cov_st_d = 7; logic cov_flt_d = 0, cov_trig_d = 0;
  always @(posedge clk) if (rst_n) begin
    cov_st_d <= dut.csma_ca_i.backoff_state; cov_flt_d <= dut.block_rx_dma_to_ps_valid; cov_trig_d <= txs.high_trigger;
    if (dut.csma_ca_i.backoff_state != cov_st_d && dut.csma_ca_i.backoff_state < 7)
      ow_cov_pkg::ow_cov::hit("xpu_csma_state", CSMA_ST[dut.csma_ca_i.backoff_state]);
    if (dut.block_rx_dma_to_ps_valid && !cov_flt_d) begin
      if (dut.block_rx_dma_to_ps) ow_cov_pkg::ow_cov::hit("xpu_filter", "blocked");
      else foreach (FLT_BIT[i])
        if (FLT_BIT[i] == 13 ? dut.pkt_filter_ctl_i.filter_cfg[13] : dut.pkt_filter_ctl_i.allow_rx_dma_to_ps_reg[FLT_BIT[i]])
          ow_cov_pkg::ow_cov::hit("xpu_filter", {FLT_NAME[i], ".pass"});
    end
    if (txs.high_trigger && !cov_trig_d)
      ow_cov_pkg::ow_cov::hit("xpu_tx_queue", $sformatf("q%0d_ack%0d", txs.tx_queue_idx, txs.tx_pkt_need_ack));
  end
  final ow_cov_pkg::ow_cov::dump();
endmodule
