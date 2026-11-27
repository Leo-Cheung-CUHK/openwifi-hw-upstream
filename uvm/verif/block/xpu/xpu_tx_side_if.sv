// xpu <-> tx_intf/openofdm_tx/rx_intf signals that the xpu block TB has to answer or observe.
interface xpu_tx_side_if (input logic clk, input logic rst_n);
  // from xpu
  logic        start_tx_ack, start_retrans, ack_tx_flag, wea, tx_try_complete, retrans_in_progress;
  logic        backoff_done, tx_bb_is_ongoing, tx_rf_is_ongoing, tx_control_state_idle;
  logic [3:0]  slice_en, cw, tx_control_state;
  logic [9:0]  addra, num_slot_random;
  logic [63:0] dina;
  logic [79:0] tx_status;
  // to xpu (driven by xpu_phy_model / tb defaults)
  logic        phy_tx_start, phy_tx_started, phy_tx_done;
  logic [9:0]  bram_addr;
  logic        tx_iq_fifo_empty = 1;   // tx_intf IQ FIFO: xpu tx_on_detection keys on its edges
  // tx_intf -> xpu: the host frame being sent (tx_bit_intf outputs in the FPGA)
  logic        high_trigger = 0, tx_pkt_need_ack = 0, quit_retrans = 0, reset_backoff = 0;
  logic [3:0]  tx_pkt_retrans_limit = 0;
  logic [1:0]  tx_queue_idx = 0;
  // xpu -> rx_intf / observation
  logic        block_rx_dma_to_ps, block_rx_dma_to_ps_valid, pkt_for_me, ch_idle_final;
  logic [10:0] rssi_half_db_lock_by_sig_valid;
endinterface
