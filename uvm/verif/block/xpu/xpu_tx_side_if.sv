// xpu <-> tx_intf/openofdm_tx signals that the xpu block TB has to answer.
interface xpu_tx_side_if (input logic clk, input logic rst_n);
  // from xpu
  logic        start_tx_ack, start_retrans, ack_tx_flag, wea, tx_try_complete, retrans_in_progress;
  logic        backoff_done, tx_bb_is_ongoing, tx_rf_is_ongoing, tx_control_state_idle;
  logic [3:0]  slice_en, cw, tx_control_state;
  logic [9:0]  addra, num_slot_random;
  logic [63:0] dina;
  logic [79:0] tx_status;
  // to xpu (driven by xpu_phy_responder / tb defaults)
  logic        phy_tx_start, phy_tx_started, phy_tx_done;
  logic [9:0]  bram_addr;
endinterface
