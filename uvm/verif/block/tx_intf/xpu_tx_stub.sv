// Minimal xpu stand-in for the tx_intf block TB: always grants the medium, ends a transmission
// when tx_intf's IQ FIFO has drained after phy_tx_done (as xpu tx_on_detection), reports "tx try
// complete" a fixed time after that, and provides TSF/1 MHz pulse.
// The real CSMA/ACK/retransmission behaviour is verified in the xpu block TB and at
// chip level; this stub only has to let tx_intf move packets.
`timescale 1ns/1ps
module xpu_tx_stub #(parameter int CLK_PER_US = 100) (
  input  logic        clk, rst_n,
  input  logic        phy_tx_start, phy_tx_done, tx_pkt_need_ack,
  input  logic [3:0]  slice_en_cfg,                 // from the test (xpu_stub_ctl_if)
  input  logic [47:0] mac_addr_cfg,
  input  logic        cts_toself_bb_is_ongoing,      // tx_intf: this phy_tx_done ends a CTS-to-self
  input  logic        tx_iq_fifo_empty,              // tx_intf: up to TX_HOLD_THRESHOLD samples still play after phy_tx_done
  output logic [3:0]  slice_en,
  output logic        backoff_done, tx_bb_is_ongoing, ack_tx_flag, wea, retrans_in_progress,
  output logic        start_retrans, start_tx_ack, tx_control_state_idle, tx_try_complete,
  output logic [9:0]  addra, num_slot_random,
  output logic [63:0] dina, tsf_runtime_val,
  output logic [3:0]  cw, band,
  output logic [7:0]  channel,
  output logic [79:0] tx_status,
  output logic [47:0] mac_addr,
  output logic        tsf_pulse_1M
);
  // stands in for the xpu's DIFS + backoff before the next medium grant (>= 34 us on air);
  // bursts closer than the DAC monitor's idle gap would merge into one  (+STUB_COMPLETE_US=<n>)
  int unsigned complete_delay_us = 20;
  initial void'($value$plusargs("STUB_COMPLETE_US=%d", complete_delay_us));

  assign slice_en = slice_en_cfg; assign backoff_done = 1'b1; assign ack_tx_flag = 0; assign wea = 0;
  assign addra = '0; assign dina = '0; assign retrans_in_progress = 0; assign start_retrans = 0;
  assign start_tx_ack = 0; assign num_slot_random = '0; assign cw = '0; assign band = 4'd4;
  assign channel = 8'd44; assign tx_status = '0; assign mac_addr = mac_addr_cfg;

  // TSF: 1 us tick
  int unsigned div;
  always_ff @(posedge clk) begin
    if (!rst_n) begin div <= 0; tsf_runtime_val <= 0; tsf_pulse_1M <= 0; end
    else begin
      tsf_pulse_1M <= (div == CLK_PER_US - 1);
      if (div == CLK_PER_US - 1) begin div <= 0; tsf_runtime_val <= tsf_runtime_val + 1; end
      else div <= div + 1;
    end
  end

  // tx_bb_is_ongoing from phy_tx_start until the IQ FIFO has drained after phy_tx_done;
  // tx_try_complete complete_delay_us after that (not for the CTS of a CTS-to-self)
  int unsigned cnt; bit armed, draining, drain_cts;
  always_ff @(posedge clk) begin
    if (!rst_n) begin tx_bb_is_ongoing <= 0; tx_try_complete <= 0; tx_control_state_idle <= 1; armed <= 0; cnt <= 0; draining <= 0; drain_cts <= 0; end
    else begin
      tx_try_complete <= 0;
      if (phy_tx_start) begin tx_bb_is_ongoing <= 1; tx_control_state_idle <= 0; end
      // like xpu tx_control.v: a phy_tx_done while cts_toself_bb_is_ongoing belongs to the CTS,
      // the try completes after the data frame that follows it
      if (phy_tx_done) begin draining <= 1; drain_cts <= cts_toself_bb_is_ongoing; end
      else if (draining && tx_iq_fifo_empty) begin
        draining <= 0; tx_bb_is_ongoing <= 0;
        if (!drain_cts) begin armed <= 1; cnt <= 0; end
      end
      if (armed) begin
        if (cnt == complete_delay_us * CLK_PER_US) begin tx_try_complete <= 1; armed <= 0; tx_control_state_idle <= 1; end
        else cnt <= cnt + 1;
      end
    end
  end
endmodule
