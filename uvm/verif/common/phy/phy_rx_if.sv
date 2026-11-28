// openofdm_rx output bundle (+ the rssi input it takes from xpu).
// Used three ways:
//   * monitor on the real openofdm_rx (block TB of openofdm_rx, chip TB, peer receiver)
//   * driver emulating openofdm_rx for the block TBs of rx_intf, xpu and side_ch
interface phy_rx_if (input logic clk, input logic rst_n);
  logic        demod_is_ongoing;
  logic        short_preamble_detected, long_preamble_detected;
  logic        pkt_header_valid, pkt_header_valid_strobe, ht_unsupport;
  logic [7:0]  pkt_rate;          // legacy {4'b0, RATE[3:0]} ; HT {1'b1, MCS[6:0]}
  logic [15:0] pkt_len;           // SIGNAL LENGTH = PSDU incl. FCS
  logic        ht_aggr, ht_aggr_last, ht_sgi;
  logic        byte_out_strobe;
  logic [7:0]  byte_out;
  logic [15:0] byte_count;
  logic        fcs_out_strobe, fcs_ok;
  logic [31:0] csi;  logic csi_valid;
  logic [31:0] phase_offset_taken;
  logic [31:0] equalizer; logic equalizer_valid; logic ofdm_symbol_eq_out_pulse;
  logic [14:0] n_ofdm_sym; logic [9:0] n_bit_in_last_sym; logic phy_len_valid;
  logic signed [10:0] rssi_half_db;

  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output demod_is_ongoing, short_preamble_detected, long_preamble_detected, pkt_header_valid,
           pkt_header_valid_strobe, ht_unsupport, pkt_rate, pkt_len, ht_aggr, ht_aggr_last, ht_sgi,
           byte_out_strobe, byte_out, byte_count, fcs_out_strobe, fcs_ok, csi, csi_valid,
           phase_offset_taken, equalizer, equalizer_valid, ofdm_symbol_eq_out_pulse,
           n_ofdm_sym, n_bit_in_last_sym, phy_len_valid;
  endclocking
  clocking mon_cb @(posedge clk);
    default input #1step;
    input demod_is_ongoing, short_preamble_detected, long_preamble_detected, pkt_header_valid,
          pkt_header_valid_strobe, ht_unsupport, pkt_rate, pkt_len, ht_aggr, ht_aggr_last, ht_sgi,
          byte_out_strobe, byte_out, byte_count, fcs_out_strobe, fcs_ok, csi, csi_valid,
          phase_offset_taken, equalizer, equalizer_valid, ofdm_symbol_eq_out_pulse,
          n_ofdm_sym, n_bit_in_last_sym, phy_len_valid, rssi_half_db;
  endclocking

  // strobes are single-cycle pulses in openofdm_rx
  a_fcs_pulse: assert property (@(posedge clk) disable iff (!rst_n) fcs_out_strobe |=> !fcs_out_strobe)
               else $error("PHY_RX: fcs_out_strobe longer than one cycle");
  a_hdr_pulse: assert property (@(posedge clk) disable iff (!rst_n) pkt_header_valid_strobe |=> !pkt_header_valid_strobe)
               else $error("PHY_RX: pkt_header_valid_strobe longer than one cycle");
endinterface
