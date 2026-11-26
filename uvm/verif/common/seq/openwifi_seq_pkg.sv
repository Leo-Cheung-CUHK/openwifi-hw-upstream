// Register-level bring-up sequences that replay the Linux driver (openwifi/driver):
// each <ip>_init_seq is that IP's hw_init() in NORMAL mode, and openwifi_start_seq is
// sdr.c openwifi_start().  Block TBs run one <ip>_init_seq; the chip TB runs
// openwifi_start_seq.  Driver constants are kept as named fields so tests can
// override them (e.g. a different RSSI threshold) without editing the sequence.
package openwifi_seq_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import openwifi_ral_pkg::*;
  import wifi_pkg::*;

  virtual class ow_reg_seq_base extends uvm_reg_sequence #(uvm_sequence #(uvm_reg_item));
    function new(string name); super.new(name); endfunction
    task wr(ow_block_base b, string reg_name, bit [31:0] v);
      uvm_status_e st;
      b.r(reg_name).write(st, v, .parent(this));
      if (st != UVM_IS_OK) `uvm_error("REGWR", $sformatf("%s.%s <= 0x%08h failed", b.get_name(), reg_name, v))
    endtask
    task rd(ow_block_base b, string reg_name, output bit [31:0] v);
      uvm_status_e st; uvm_reg_data_t d;
      b.r(reg_name).read(st, d, .parent(this)); v = d;
      if (st != UVM_IS_OK) `uvm_error("REGRD", $sformatf("%s.%s read failed", b.get_name(), reg_name))
    endtask
    task pulse_rst(ow_block_base b);       // MULTI_RST 0 -> all-ones -> 0
      wr(b, "MULTI_RST", 0); wr(b, "MULTI_RST", 32'hFFFF_FFFF); wr(b, "MULTI_RST", 0);
    endtask
    task rx_m_axis_rst(ow_block_base b, bit hold);   // RX_INTF_REG_M_AXIS_RST_write: RMW of MULTI_RST bit4
      bit [31:0] v; rd(b, "MULTI_RST", v);
      wr(b, "MULTI_RST", hold ? (v | 32'h10) : (v & ~32'h10));
    endtask
    task xpu_tsf_load(ow_block_base b, bit [63:0] t);  // rising edge of TSF_LOAD_VAL_HIGH[31] loads
      wr(b, "TSF_LOAD_VAL_LOW", t[31:0]);
      wr(b, "TSF_LOAD_VAL_HIGH", t[63:32] | 32'h8000_0000);
      wr(b, "TSF_LOAD_VAL_HIGH", t[63:32] & 32'h7FFF_FFFF);
    endtask
  endclass

  // openofdm_rx.c hw_init(OPENOFDM_RX_NORMAL)
  class openofdm_rx_init_seq extends ow_reg_seq_base;
    `uvm_object_utils(openofdm_rx_init_seq)
    openofdm_rx_regs rb;
    int unsigned min_plateau = 100, max_len_th = 1700, min_len_th = 14;
    int unsigned small_eq_out_counter_th = 48, fft_win_shift = 4, phase_offset_abs_th = 11;
    bit [31:0]   power_thres = 0;       // driver sets it later from RSSI calibration; 0 = always trigger
    function new(string name = "openofdm_rx_init_seq"); super.new(name); endfunction
    task body();
      wr(rb, "ENABLE", 1);
      wr(rb, "POWER_THRES", power_thres);
      wr(rb, "MIN_PLATEAU", min_plateau);
      wr(rb, "SOFT_DECODING", (max_len_th << 16) | (min_len_th << 12) | 1);
      wr(rb, "FFT_WIN_SHIFT", (small_eq_out_counter_th << 4) | fft_win_shift);
      wr(rb, "PHASE_OFFSET_ABS_TH", phase_offset_abs_th);
      pulse_rst(rb);
    endtask
  endclass

  // openofdm_tx.c hw_init(OPENOFDM_TX_NORMAL)
  class openofdm_tx_init_seq extends ow_reg_seq_base;
    `uvm_object_utils(openofdm_tx_init_seq)
    openofdm_tx_regs rb;
    bit [6:0] pilot_state = 7'h7F, data_state = 7'h7F;
    // Driver order (reset, then seeds) leaves the FIRST packet with the pilot seed latched
    // at reset (0): dot11_tx.v loads pilot_scram_state only on reset_int. +OTX_SEEDS_FIRST
    // writes the seeds before the reset pulse (the driver-side workaround).
    bit seeds_first = 0;
    function new(string name = "openofdm_tx_init_seq"); super.new(name); endfunction
    task body();
      if ($test$plusargs("OTX_SEEDS_FIRST")) seeds_first = 1;
      if (seeds_first) begin wr(rb, "INIT_PILOT_STATE", pilot_state); wr(rb, "INIT_DATA_STATE", data_state); end
      pulse_rst(rb);
      wr(rb, "INIT_PILOT_STATE", pilot_state);
      wr(rb, "INIT_DATA_STATE",  data_state);
    endtask
  endclass

  // tx_intf.c hw_init(TX_INTF_BW_20MHZ_AT_0MHZ_ANT0, ..., num_dma_symbol_to_ps=8)
  class tx_intf_init_seq extends ow_reg_seq_base;
    `uvm_object_utils(tx_intf_init_seq)
    tx_intf_regs rb;
    bit small_fpga = 0;
    int unsigned num_dma_symbol_to_ps = 8, bb_gain = 250, tx_hold_th = 420;
    function new(string name = "tx_intf_init_seq"); super.new(name); endfunction
    task body();
      pulse_rst(rb);
      wr(rb, "S_AXIS_FIFO_TH", small_fpga ? (4096 - 210*2) : (8192 - 210*2));
      wr(rb, "MULTI_RST", 0);
      wr(rb, "CSI_FUZZER", 0);
      wr(rb, "CTS_TOSELF_WAIT_SIFS_TOP", ((16*10) << 16) | (16*10));
      wr(rb, "NUM_DMA_SYMBOL_TO_PS", num_dma_symbol_to_ps);
      wr(rb, "CFG_DATA_TO_ANT", 0);
      wr(rb, "TX_HOLD_THRESHOLD", tx_hold_th);
      wr(rb, "INTERRUPT_SEL", 32'h4);
      wr(rb, "INTERRUPT_SEL", 32'h3_0004);
      wr(rb, "BB_GAIN", bb_gain);
      wr(rb, "WIFI_TX_MODE", (1 << 3) | (2 << 4));
      wr(rb, "MULTI_RST", 32'h434);
      wr(rb, "MULTI_RST", 0);
    endtask
  endclass

  // rx_intf.c hw_init(RX_INTF_BW_20MHZ_AT_0MHZ_ANT0, 8, 8)
  class rx_intf_init_seq extends ow_reg_seq_base;
    `uvm_object_utils(rx_intf_init_seq)
    rx_intf_regs rb;
    function new(string name = "rx_intf_init_seq"); super.new(name); endfunction
    task body();
      wr(rb, "TLAST_TIMEOUT_TOP", 7000);
      pulse_rst(rb);
      rx_m_axis_rst(rb, 1);
      wr(rb, "MULTI_RST", 0);
      rx_m_axis_rst(rb, 1);
      wr(rb, "INTERRUPT_TEST", 32'h100);
      wr(rb, "S2MM_INTR_DELAY_COUNT", 30*10);
      wr(rb, "IQ_CTRL", 0);
      wr(rb, "START_TRANS_TO_PS_MODE", 32'h1_0025);
    endtask
  endclass

  // xpu.c hw_init(XPU_NORMAL)
  class xpu_init_seq extends ow_reg_seq_base;
    `uvm_object_utils(xpu_init_seq)
    xpu_regs rb;
    int unsigned agc_gain_delay = 39, rssi_half_db_offset = 75 << 1, rssi_half_db_th = 87 << 1;
    int unsigned max_len_th = 1700;
    function new(string name = "xpu_init_seq"); super.new(name); endfunction
    task body();
      pulse_rst(rb);
      wr(rb, "CTS_TO_RTS_CONFIG", 32'hB << 16);
      wr(rb, "BB_RF_DELAY", (16 << 24) | (0 << 16) | (26 << 8) | 9);
      for (int i = 0; i < 4; i++) begin
        wr(rb, "SLICE_COUNT_TOTAL", (i << 20) | 16);
        wr(rb, "SLICE_COUNT_START", (i << 20) | 0);
        wr(rb, "SLICE_COUNT_END",   (i << 20) | 16);
      end
      wr(rb, "MULTI_RST", 1 << 7); wr(rb, "MULTI_RST", 0);
      wr(rb, "RSSI_DB_CFG", 32'h8000_0000 | (rssi_half_db_offset << 16) | agc_gain_delay);
      wr(rb, "RSSI_DB_CFG", ~32'h8000_0000 & ((rssi_half_db_offset << 16) | agc_gain_delay));
      wr(rb, "LBT_TH", rssi_half_db_th);
      wr(rb, "FORCE_IDLE_MISC", (1 << 26) | 75);
      wr(rb, "CSMA_DEBUG", 0);
      wr(rb, "SEND_ACK_WAIT_TOP", ((16+25+7-3+8-2) << 16) | (16+25+7-3+8-2));
      wr(rb, "RECV_ACK_COUNT_TOP0", (1 << 31) | ((((51+2+2)*10) + 15) << 16) | (10+3));
      wr(rb, "RECV_ACK_COUNT_TOP1", (1 << 31) | ((((51+2+2)*10) + 15) << 16) | (10+3));
      wr(rb, "DIFS_ADVANCE", (max_len_th << 16) | 2);
      xpu_tsf_load(rb, 0);
    endtask
  endclass

  // sdr.c openwifi_start() register sequence (RF/AD9361 parts omitted: not in the PL)
  class openwifi_start_seq extends ow_reg_seq_base;
    `uvm_object_utils(openwifi_start_seq)
    openwifi_regmodel rm;
    bit [47:0] mac_addr = 48'h66_55_44_33_22_11;  // byte0 = 0x11 (little-endian as in sdr.c)
    bit [3:0]  band = 4;                         // BAND_5_8GHZ
    int unsigned channel_mhz = 5220;             // actual_rx_lo
    bit        use_short_slot = 1;
    // xpu pkt_filter_ctl.v: MONITOR_ALL=0x2000 UNICAST_FOR_US=0x200 BROADCAST_ALL_ONE=0x400
    bit [31:0] filter_flag = 32'h0000_2000;      // pass everything to the host by default
    function new(string name = "openwifi_start_seq"); super.new(name); endfunction
    task body();
      rx_intf_init_seq    s_rx  = rx_intf_init_seq::type_id::create("s_rx");
      tx_intf_init_seq    s_tx  = tx_intf_init_seq::type_id::create("s_tx");
      openofdm_tx_init_seq s_otx = openofdm_tx_init_seq::type_id::create("s_otx");
      openofdm_rx_init_seq s_orx = openofdm_rx_init_seq::type_id::create("s_orx");
      xpu_init_seq        s_xpu = xpu_init_seq::type_id::create("s_xpu");
      s_rx.rb = rm.rx_intf; s_tx.rb = rm.tx_intf; s_otx.rb = rm.openofdm_tx; s_orx.rb = rm.openofdm_rx; s_xpu.rb = rm.xpu;
      s_rx.start(m_sequencer, this);  s_tx.start(m_sequencer, this);
      s_otx.start(m_sequencer, this); s_orx.start(m_sequencer, this);
      s_xpu.start(m_sequencer, this);
      wr(rm.xpu, "MAC_ADDR_LOW",  mac_addr[31:0]);
      wr(rm.xpu, "MAC_ADDR_HIGH", {16'h0, mac_addr[47:32]});
      wr(rm.xpu, "BAND_CHANNEL",  (use_short_slot << 24) | (band << 16) | channel_mhz[15:0]);
      wr(rm.xpu, "FILTER_FLAG",   filter_flag);
      wr(rm.tx_intf, "INTERRUPT_SEL", 32'h3_0004);
      wr(rm.rx_intf, "INTERRUPT_TEST", 32'h100);
      rx_m_axis_rst(rm.rx_intf, 1);
      wr(rm.rx_intf, "INTERRUPT_TEST", 32'h000);
      wr(rm.tx_intf, "INTERRUPT_SEL", 32'h4);
      rx_m_axis_rst(rm.rx_intf, 0);
      xpu_tsf_load(rm.xpu, 0);
      wr(rm.xpu, "SPI_DISABLE", 0);
      wr(rm.xpu, "SPI_DISABLE", 1);
    endtask
  endclass

  // driver openwifi_tx(): program TX_CONFIG/PHY_HDR_CONFIG, then the frame goes on the
  // TX DMA (the AXIS part is done by the caller on the AXIS sequencer)
  class tx_kick_seq extends ow_reg_seq_base;
    `uvm_object_utils(tx_kick_seq)
    tx_intf_regs rb; wifi_frame f; bit [5:0] bd_wr_idx;
    function new(string name = "tx_kick_seq"); super.new(name); endfunction
    task body();
      wr(rb, "CTS_TOSELF_CONFIG", 0);
      wr(rb, "TX_CONFIG", f.tx_config(bd_wr_idx));
      wr(rb, "PHY_HDR_CONFIG", f.phy_hdr_config());
    endtask
  endclass
endpackage
