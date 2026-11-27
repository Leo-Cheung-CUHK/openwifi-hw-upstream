// xpu-side inputs of rx_intf, driven by the test: address-filter decision, the RSSI/AGC
// values xpu latches at SIGNAL-valid, TSF. block_rx_dma_to_ps_valid is pulsed when
// pkt_filter_ctl.v decides: in FILTER_ACTION, after the MAC header addresses are parsed. The stub
// pulses it after the 24th PSDU byte, or at the FCS strobe for shorter frames (ACK, CTS).
`timescale 1ns/1ps
interface rx_side_if (input logic clk, input logic rst_n, input logic hdr_strobe, input logic byte_strobe, input logic fcs_strobe);
  logic        block_rx_dma_to_ps = 0, block_rx_dma_to_ps_valid = 0, mute_adc_out_to_bb = 0;
  logic [10:0] rssi_half_db_lock_by_sig_valid = 0;
  logic [7:0]  gpio_status_lock_by_sig_valid = 0;
  logic [63:0] tsf = 0;
  logic        tsf_pulse_1M = 0;
  bit          nxt_block; bit [10:0] nxt_rssi; bit [7:0] nxt_gpio;
  int unsigned div = 0, n_byte = 0; bit armed = 0;

  function automatic void set_rx(bit block, bit [10:0] rssi, bit [7:0] gpio);
    nxt_block = block; nxt_rssi = rssi; nxt_gpio = gpio;
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin tsf <= 0; div <= 0; tsf_pulse_1M <= 0; block_rx_dma_to_ps_valid <= 0; end
    else begin
      tsf_pulse_1M <= (div == `NUM_CLK_PER_US - 1);
      if (div == `NUM_CLK_PER_US - 1) begin div <= 0; tsf <= tsf + 1; end else div <= div + 1;
      block_rx_dma_to_ps_valid <= 0;
      if (hdr_strobe) begin armed <= 1; n_byte <= 0; end
      else if (armed && (fcs_strobe || (byte_strobe && n_byte == 23))) begin
        armed <= 0; block_rx_dma_to_ps_valid <= 1;
      end else if (armed && byte_strobe) n_byte <= n_byte + 1;
      if (hdr_strobe) begin
        block_rx_dma_to_ps <= nxt_block;
        rssi_half_db_lock_by_sig_valid <= nxt_rssi;
        gpio_status_lock_by_sig_valid <= nxt_gpio;
      end
    end
  end
endinterface
