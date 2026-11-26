// Register model for the six openwifi AXI-lite slaves.
// Names/offsets: openwifi/driver/hw_def.h + side_ch/side_ch.h.  Access policy: the
// Xilinx s_axi template makes every slv_reg RW unless the IP top drives it with an
// 'assign slv_regN = ...' (then RO).  tx_intf PKT_INFO1..4 pop tx_status_fifo on read
// (see tx_status_fifo.v), so they are RO + volatile and excluded from the built-in
// register tests.  Registers that are not named by the driver are still modelled
// (RSVD_n) so uvm_reg_hw_reset / bit-bash cover the whole slot.
// Slots whose write case is commented out in <ip>_s_axi.v are RO (is_writable()):
// found by running otx_reg_reset_test -- openofdm_tx only implements slv_reg0..2.
package openwifi_ral_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  class ow_reg extends uvm_reg;
    `uvm_object_utils(ow_reg)
    rand uvm_reg_field val;
    function new(string name = "ow_reg"); super.new(name, 32, UVM_NO_COVERAGE); endfunction
    function void configure_field(string access, bit volatile_ = 0);
      val = uvm_reg_field::type_id::create("val");
      val.configure(this, 32, 0, access, volatile_, 32'h0, 1, (access != "RO"), 1);
    endfunction
  endclass

  typedef struct { int idx; string name; string acc; bit vol; bit no_test; } reg_def_t;

  // Base: builds N slots, names from a table, RSVD for the rest
  virtual class ow_block_base extends uvm_reg_block;
    ow_reg regs[int];
    function new(string name); super.new(name, UVM_NO_COVERAGE); endfunction
    pure virtual function void get_defs(ref reg_def_t d[$], output int n_slots);
    // slv_regs that the IP's *_s_axi.v really lets you write (write cases not commented
    // out); every other slot is modelled RO + volatile (value may come from the design)
    pure virtual function bit is_writable(int i);

    virtual function void build();
      reg_def_t d[$]; int n; string nm[int]; reg_def_t byidx[int];
      get_defs(d, n);
      foreach (d[i]) byidx[d[i].idx] = d[i];
      default_map = create_map("map", 0, 4, UVM_LITTLE_ENDIAN, 1);
      for (int i = 0; i < n; i++) begin
        reg_def_t e;
        if (byidx.exists(i)) e = byidx[i];
        else begin e.idx = i; e.name = $sformatf("RSVD_%0d", i); e.acc = "RW"; e.vol = 0; e.no_test = 0; end
        if (!is_writable(i)) begin e.acc = "RO"; e.vol = 1; e.no_test = 1; end
        regs[i] = ow_reg::type_id::create(e.name);
        regs[i].configure(this, null, "");
        regs[i].configure_field(e.acc, e.vol);
        default_map.add_reg(regs[i], i * 4, e.acc);
        if (e.no_test || e.vol) begin
          uvm_resource_db#(bit)::set({"REG::", regs[i].get_full_name()}, "NO_REG_TESTS", 1, this);
        end
        // reset/RW-pulse registers (MULTI_RST etc.) must not be bit-bashed on a live design
        if (e.idx == 0) uvm_resource_db#(bit)::set({"REG::", regs[i].get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
      end
      if (get_parent() == null) lock_model();   // stand-alone (block-level) use
    endfunction

    function ow_reg r(string name);
      uvm_reg x = get_reg_by_name(name); ow_reg o;
      if (x == null || !$cast(o, x)) `uvm_fatal("RAL", {"no register ", name, " in ", get_name()})
      return o;
    endfunction
  endclass

  `define OW_REG(I, N, A)      '{I, N, A, 0, 0}
  `define OW_REG_V(I, N, A)    '{I, N, A, 1, 1}

  class tx_intf_regs extends ow_block_base;
    `uvm_object_utils(tx_intf_regs)
    function new(string name = "tx_intf_regs"); super.new(name); endfunction
    virtual function bit is_writable(int i); return i inside {0, 1, 2, [4:17]}; endfunction   // tx_intf_s_axi.v
    virtual function void get_defs(ref reg_def_t d[$], output int n_slots);
      n_slots = 32;
      d = '{`OW_REG(0,"MULTI_RST","RW"), `OW_REG(1,"ARBITRARY_IQ","RW"), `OW_REG(2,"WIFI_TX_MODE","RW"),
            `OW_REG(4,"CTS_TOSELF_CONFIG","RW"), `OW_REG(5,"CSI_FUZZER","RW"), `OW_REG(6,"CTS_TOSELF_WAIT_SIFS_TOP","RW"),
            `OW_REG(7,"ARBITRARY_IQ_CTL","RW"), `OW_REG(8,"TX_CONFIG","RW"), `OW_REG(9,"NUM_DMA_SYMBOL_TO_PS","RW"),
            `OW_REG(10,"CFG_DATA_TO_ANT","RW"), `OW_REG(11,"S_AXIS_FIFO_TH","RW"), `OW_REG(12,"TX_HOLD_THRESHOLD","RW"),
            `OW_REG(13,"BB_GAIN","RW"), `OW_REG(14,"INTERRUPT_SEL","RW"), `OW_REG(15,"AMPDU_ACTION_CONFIG","RW"),
            `OW_REG(16,"ANT_SEL","RW"), `OW_REG(17,"PHY_HDR_CONFIG","RW"),
            `OW_REG_V(21,"S_AXIS_FIFO_NO_ROOM","RO"),
            `OW_REG_V(22,"PKT_INFO1","RO"), `OW_REG_V(23,"PKT_INFO2","RO"), `OW_REG_V(24,"PKT_INFO3","RO"),
            `OW_REG_V(25,"PKT_INFO4","RO"), `OW_REG_V(26,"QUEUE_FIFO_DATA_COUNT","RO"),
            `OW_REG_V(31,"VERSION","RO")};
    endfunction
  endclass

  class rx_intf_regs extends ow_block_base;
    `uvm_object_utils(rx_intf_regs)
    function new(string name = "rx_intf_regs"); super.new(name); endfunction
    virtual function bit is_writable(int i); return i inside {[0:13], 16}; endfunction   // rx_intf_s_axi.v
    virtual function void get_defs(ref reg_def_t d[$], output int n_slots);
      n_slots = 32;
      d = '{`OW_REG(0,"MULTI_RST","RW"), `OW_REG(1,"MIXER_CFG","RW"), `OW_REG(2,"INTERRUPT_TEST","RW"),
            `OW_REG(3,"IQ_SRC_SEL","RW"), `OW_REG(4,"IQ_CTRL","RW"), `OW_REG(5,"START_TRANS_TO_PS_MODE","RW"),
            `OW_REG(6,"START_TRANS_TO_PS","RW"), `OW_REG(7,"START_TRANS_TO_PS_SRC_SEL","RW"),
            `OW_REG(8,"NUM_DMA_SYMBOL_TO_PL","RW"), `OW_REG(9,"NUM_DMA_SYMBOL_TO_PS","RW"),
            `OW_REG(10,"CFG_DATA_TO_ANT","RW"), `OW_REG(11,"BB_GAIN","RW"), `OW_REG(12,"TLAST_TIMEOUT_TOP","RW"),
            `OW_REG(13,"S2MM_INTR_DELAY_COUNT","RW"), `OW_REG(16,"ANT_SEL","RW"),
            `OW_REG_V(31,"VERSION","RO")};
    endfunction
  endclass

  class openofdm_rx_regs extends ow_block_base;
    `uvm_object_utils(openofdm_rx_regs)
    function new(string name = "openofdm_rx_regs"); super.new(name); endfunction
    virtual function bit is_writable(int i); return i inside {[0:5], [17:19]}; endfunction   // openofdm_rx_s_axi.v
    virtual function void get_defs(ref reg_def_t d[$], output int n_slots);
      n_slots = 32;
      d = '{`OW_REG(0,"MULTI_RST","RW"), `OW_REG(1,"ENABLE","RW"), `OW_REG(2,"POWER_THRES","RW"),
            `OW_REG(3,"MIN_PLATEAU","RW"), `OW_REG(4,"SOFT_DECODING","RW"), `OW_REG(5,"FFT_WIN_SHIFT","RW"),
            `OW_REG(18,"PHASE_OFFSET_ABS_TH","RW"), `OW_REG(20,"STATE_HISTORY","RW"),
            `OW_REG_V(21,"STATUS21","RO"), `OW_REG_V(31,"GIT_REV","RO")};
    endfunction
  endclass

  class openofdm_tx_regs extends ow_block_base;
    `uvm_object_utils(openofdm_tx_regs)
    function new(string name = "openofdm_tx_regs"); super.new(name); endfunction
    virtual function bit is_writable(int i); return i inside {[0:2]}; endfunction   // openofdm_tx_s_axi.v
    virtual function void get_defs(ref reg_def_t d[$], output int n_slots);
      n_slots = 32;
      d = '{`OW_REG(0,"MULTI_RST","RW"), `OW_REG(1,"INIT_PILOT_STATE","RW"), `OW_REG(2,"INIT_DATA_STATE","RW")};
    endfunction
  endclass

  class xpu_regs extends ow_block_base;
    `uvm_object_utils(xpu_regs)
    function new(string name = "xpu_regs"); super.new(name); endfunction
    virtual function bit is_writable(int i); return i inside {[0:13], [16:22], [26:31]}; endfunction   // xpu_s_axi.v
    virtual function void get_defs(ref reg_def_t d[$], output int n_slots);
      n_slots = 64;
      d = '{`OW_REG(0,"MULTI_RST","RW"), `OW_REG(1,"SRC_SEL","RW"), `OW_REG(2,"TSF_LOAD_VAL_LOW","RW"),
            `OW_REG(3,"TSF_LOAD_VAL_HIGH","RW"), `OW_REG(4,"BAND_CHANNEL","RW"), `OW_REG(5,"DIFS_ADVANCE","RW"),
            `OW_REG(6,"FORCE_IDLE_MISC","RW"), `OW_REG(7,"RSSI_DB_CFG","RW"), `OW_REG(8,"LBT_TH","RW"),
            `OW_REG(9,"CSMA_DEBUG","RW"), `OW_REG(10,"BB_RF_DELAY","RW"), `OW_REG(11,"ACK_CTL_MAX_NUM_RETRANS","RW"),
            `OW_REG(12,"AMPDU_ACTION","RW"), `OW_REG(13,"SPI_DISABLE","RW"),
            `OW_REG(16,"RECV_ACK_COUNT_TOP0","RW"), `OW_REG(17,"RECV_ACK_COUNT_TOP1","RW"),
            `OW_REG(18,"SEND_ACK_WAIT_TOP","RW"), `OW_REG(19,"CSMA_CFG","RW"),
            `OW_REG(20,"SLICE_COUNT_TOTAL","RW"), `OW_REG(21,"SLICE_COUNT_START","RW"), `OW_REG(22,"SLICE_COUNT_END","RW"),
            `OW_REG(26,"CTS_TO_RTS_CONFIG","RW"), `OW_REG(27,"FILTER_FLAG","RW"),
            `OW_REG(28,"BSSID_FILTER_LOW","RW"), `OW_REG(29,"BSSID_FILTER_HIGH","RW"),
            `OW_REG(30,"MAC_ADDR_LOW","RW"), `OW_REG(31,"MAC_ADDR_HIGH","RW"),
            `OW_REG_V(57,"RSSI_IDLE_STATUS","RO"),
            `OW_REG_V(58,"TSF_RUNTIME_VAL_LOW","RO"), `OW_REG_V(59,"TSF_RUNTIME_VAL_HIGH","RO"),
            `OW_REG_V(62,"MAC_ADDR_READ_BACK","RO"), `OW_REG_V(63,"FPGA_GIT_REV","RO")};
    endfunction
  endclass

  class side_ch_regs extends ow_block_base;
    `uvm_object_utils(side_ch_regs)
    function new(string name = "side_ch_regs"); super.new(name); endfunction
    virtual function bit is_writable(int i); return i inside {[0:12], 19}; endfunction   // side_ch_s_axi.v
    virtual function void get_defs(ref reg_def_t d[$], output int n_slots);
      n_slots = 32;
      d = '{`OW_REG(0,"MULTI_RST","RW"), `OW_REG(1,"CONFIG","RW"), `OW_REG(2,"NUM_DMA_SYMBOL","RW"),
            `OW_REG(3,"IQ_CAPTURE","RW"), `OW_REG(4,"NUM_EQ","RW"), `OW_REG(5,"FC_TARGET","RW"),
            `OW_REG(6,"ADDR1_TARGET","RW"), `OW_REG(7,"ADDR2_TARGET","RW"), `OW_REG(8,"IQ_TRIGGER","RW"),
            `OW_REG(9,"RSSI_TH","RW"), `OW_REG(10,"GAIN_TH","RW"), `OW_REG(11,"PRE_TRIGGER_LEN","RW"),
            `OW_REG(12,"IQ_LEN","RW"), `OW_REG_V(20,"M_AXIS_DATA_COUNT","RO")};
    endfunction
  endclass

  // Chip-level map: same offsets as system.bd (slot * 0x1_0000)
  class openwifi_regmodel extends uvm_reg_block;
    `uvm_object_utils(openwifi_regmodel)
    rand openofdm_rx_regs openofdm_rx;
    rand openofdm_tx_regs openofdm_tx;
    rand rx_intf_regs     rx_intf;
    rand side_ch_regs     side_ch;
    rand tx_intf_regs     tx_intf;
    rand xpu_regs         xpu;
    function new(string name = "openwifi_regmodel"); super.new(name, UVM_NO_COVERAGE); endfunction
    virtual function void build(uvm_reg_addr_t base = 'hA000_0000);
      default_map = create_map("map", base, 4, UVM_LITTLE_ENDIAN, 1);
      openofdm_rx = openofdm_rx_regs::type_id::create("openofdm_rx"); openofdm_rx.configure(this); openofdm_rx.build();
      openofdm_tx = openofdm_tx_regs::type_id::create("openofdm_tx"); openofdm_tx.configure(this); openofdm_tx.build();
      rx_intf     = rx_intf_regs::type_id::create("rx_intf");         rx_intf.configure(this);     rx_intf.build();
      side_ch     = side_ch_regs::type_id::create("side_ch");         side_ch.configure(this);     side_ch.build();
      tx_intf     = tx_intf_regs::type_id::create("tx_intf");         tx_intf.configure(this);     tx_intf.build();
      xpu         = xpu_regs::type_id::create("xpu");                 xpu.configure(this);         xpu.build();
      default_map.add_submap(openofdm_rx.default_map, 'h2_0000);
      default_map.add_submap(openofdm_tx.default_map, 'h3_0000);
      default_map.add_submap(rx_intf.default_map,     'h4_0000);
      default_map.add_submap(side_ch.default_map,     'h5_0000);
      default_map.add_submap(tx_intf.default_map,     'h6_0000);
      default_map.add_submap(xpu.default_map,         'h7_0000);
      lock_model();
    endfunction
  endclass
endpackage
