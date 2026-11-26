// Block TB top: tx_intf. Two clocks: AXI/core clock (NUM_CLK_PER_US MHz) and the
// RF-side dac_clk (40 MHz, 2 x 20 Msps as the AD9361 / RFSoC adapter delivers it).
`timescale 1ns/1ps
module tb_tx_intf;
  import uvm_pkg::*;
  import tx_intf_tb_pkg::*;

  localparam real CLK_MHZ = `NUM_CLK_PER_US;
  logic clk = 0, rst_n = 0, dac_clk = 0, dac_rst = 1;
  always #(500.0 / CLK_MHZ) clk = ~clk;
  always #12.5 dac_clk = ~dac_clk;                 // 40 MHz
  initial begin repeat (20) @(posedge clk); rst_n <= 1; end
  initial begin repeat (10) @(posedge dac_clk); dac_rst <= 0; end

  axil_if   axil (clk, rst_n);
  axis_if   dma  (clk, rst_n);
  phy_tx_if acc  (clk, rst_n);
  iq_if     dac  (dac_clk, !dac_rst);
  irq_if    irq  (clk, rst_n);

  // xpu side
  logic [3:0] slice_en, cw, band; logic [7:0] channel; logic [9:0] addra, num_slot_random;
  logic backoff_done, tx_bb_is_ongoing, ack_tx_flag, wea, retrans_in_progress, start_retrans, start_tx_ack;
  logic tx_control_state_idle, tx_try_complete, tsf_pulse_1M, tx_pkt_need_ack;
  logic [63:0] dina, tsf_runtime_val; logic [79:0] tx_status; logic [47:0] mac_addr;

  xpu_tx_stub #(.CLK_PER_US(`NUM_CLK_PER_US)) u_xpu (
    .clk(clk), .rst_n(rst_n), .phy_tx_start(acc.phy_tx_start), .phy_tx_done(acc.phy_tx_done),
    .tx_pkt_need_ack(tx_pkt_need_ack), .slice_en(slice_en), .backoff_done(backoff_done),
    .tx_bb_is_ongoing(tx_bb_is_ongoing), .ack_tx_flag(ack_tx_flag), .wea(wea),
    .retrans_in_progress(retrans_in_progress), .start_retrans(start_retrans), .start_tx_ack(start_tx_ack),
    .tx_control_state_idle(tx_control_state_idle), .tx_try_complete(tx_try_complete), .addra(addra),
    .num_slot_random(num_slot_random), .dina(dina), .tsf_runtime_val(tsf_runtime_val), .cw(cw),
    .band(band), .channel(channel), .tx_status(tx_status), .mac_addr(mac_addr), .tsf_pulse_1M(tsf_pulse_1M));

  assign dac.valid = 1'b1;     // dac_valid is tied 1 in dac_intf.v; monitor samples every dac_clk

  tx_intf dut (
    .dac_rst(dac_rst), .dac_clk(dac_clk),
    .dma_valid(1'b0), .dma_data(64'd0), .dma_ready(),
    .dac_valid(), .dac_data(dac.data), .dac_ready(1'b1),
    .iq0_for_check(), .iq1_for_check(), .iq_valid_for_check(), .tx_pkt_iq_to_dac_ongoing(),
    .fcs_in_strobe(1'b0),
    .phy_tx_start(acc.phy_tx_start), .tx_hold(acc.tx_hold), .bram_addr(acc.bram_addr),
    .rf_i_from_acc(acc.result_i), .rf_q_from_acc(acc.result_q), .rf_iq_valid_from_acc(acc.result_iq_valid),
    .data_to_acc(acc.bram_din), .bram_addr_to_xpu(),
    .tx_start_from_acc(acc.phy_tx_started), .tx_end_from_acc(acc.phy_tx_done),
    .tx_itrpt(irq.tx_itrpt), .tx_itrpt_led(), .tx_end_led(),
    .tx_status(tx_status), .mac_addr(mac_addr), .douta(), .tx_iq_fifo_empty(),
    .slice_en(slice_en), .backoff_done(backoff_done), .tx_bb_is_ongoing(tx_bb_is_ongoing),
    .ack_tx_flag(ack_tx_flag), .wea_from_xpu(wea), .addra_from_xpu(addra), .dina_from_xpu(dina),
    .tx_pkt_need_ack(tx_pkt_need_ack), .tx_pkt_retrans_limit(), .use_ht_aggr(),
    .tx_try_complete(tx_try_complete), .num_slot_random(num_slot_random), .cw(cw),
    .retrans_in_progress(retrans_in_progress), .start_retrans(start_retrans), .start_tx_ack(start_tx_ack),
    .tx_control_state_idle(tx_control_state_idle),
    .cts_toself_bb_is_ongoing(), .cts_toself_rf_is_ongoing(),
    .tsf_pulse_1M(tsf_pulse_1M), .band(band), .channel(channel),
    .quit_retrans(), .reset_backoff(), .high_trigger(), .tx_queue_idx_to_xpu(),
    .s00_axi_aclk(clk), .s00_axi_aresetn(rst_n),
    .s00_axi_awaddr(axil.awaddr[6:0]), .s00_axi_awprot(axil.awprot), .s00_axi_awvalid(axil.awvalid), .s00_axi_awready(axil.awready),
    .s00_axi_wdata(axil.wdata), .s00_axi_wstrb(axil.wstrb), .s00_axi_wvalid(axil.wvalid), .s00_axi_wready(axil.wready),
    .s00_axi_bresp(axil.bresp), .s00_axi_bvalid(axil.bvalid), .s00_axi_bready(axil.bready),
    .s00_axi_araddr(axil.araddr[6:0]), .s00_axi_arprot(axil.arprot), .s00_axi_arvalid(axil.arvalid), .s00_axi_arready(axil.arready),
    .s00_axi_rdata(axil.rdata), .s00_axi_rresp(axil.rresp), .s00_axi_rvalid(axil.rvalid), .s00_axi_rready(axil.rready),
    .s00_axis_aclk(clk), .s00_axis_aresetn(rst_n),
    .s00_axis_tready(dma.tready), .s00_axis_tdata(dma.tdata), .s00_axis_tstrb(dma.tstrb),
    .s00_axis_tlast(dma.tlast), .s00_axis_tvalid(dma.tvalid),
    .tsf_runtime_val(tsf_runtime_val));

  initial begin
    uvm_config_db#(virtual axil_if)::set(null, "uvm_test_top.env.axil*", "vif", axil);
    uvm_config_db#(virtual axis_if)::set(null, "uvm_test_top.env.dma*", "vif", dma);
    uvm_config_db#(virtual phy_tx_if)::set(null, "uvm_test_top.env.acc*", "vif", acc);
    uvm_config_db#(virtual iq_if)::set(null, "uvm_test_top.env.dac*", "vif", dac);
    uvm_config_db#(virtual irq_if)::set(null, "uvm_test_top.env", "irq", irq);
    run_test("txi_basic_test");
  end
endmodule
