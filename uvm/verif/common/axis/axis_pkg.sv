// AXI4-Stream agent: master (TB drives DUT, stands in for axi_dma MM2S),
// slave (TB sinks DUT output, stands in for axi_dma S2MM) and passive monitor.
package axis_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  typedef enum {AXIS_MASTER, AXIS_SLAVE, AXIS_PASSIVE} axis_role_e;
  typedef enum {READY_ALWAYS, READY_RANDOM, READY_NEVER} axis_ready_e;

  // One AXIS packet (TVALID beats up to and including TLAST)
  class axis_item extends uvm_sequence_item;
    rand bit [63:0] data[];
    rand bit [7:0]  strb[];
    rand int unsigned gap_max = 0;       // master: max idle cycles inserted between beats
    time            t_first, t_last;     // monitor timestamps
    constraint c_sz   { data.size() inside {[1:1024]}; strb.size() == data.size(); }
    constraint c_strb { foreach (strb[i]) strb[i] == 8'hFF; }
    `uvm_object_utils_begin(axis_item)
      `uvm_field_array_int(data, UVM_ALL_ON | UVM_HEX)
      `uvm_field_array_int(strb, UVM_ALL_ON | UVM_HEX)
    `uvm_object_utils_end
    function new(string name = "axis_item"); super.new(name); endfunction

    // little-endian byte view (byte 0 = data[0][7:0]), honouring TSTRB
    function void to_bytes(ref byte unsigned b[$]);
      b.delete();
      foreach (data[i]) for (int k = 0; k < 8; k++) if (strb[i][k]) b.push_back(data[i][8*k +: 8]);
    endfunction
    function void from_bytes(const ref byte unsigned b[$]);
      int n = (b.size() + 7) / 8;
      data = new[n]; strb = new[n];
      foreach (data[i]) begin
        data[i] = '0; strb[i] = '0;
        for (int k = 0; k < 8; k++) if (8*i+k < b.size()) begin
          data[i][8*k +: 8] = b[8*i+k]; strb[i][k] = 1;
        end
      end
    endfunction
    // the DMA always moves whole 64-bit words; openwifi pads with zeros
    function void from_bytes_word_padded(const ref byte unsigned b[$]);
      from_bytes(b); foreach (strb[i]) strb[i] = 8'hFF;
    endfunction
  endclass

  class axis_cfg extends uvm_object;
    axis_role_e  role        = AXIS_PASSIVE;
    axis_ready_e ready_mode  = READY_ALWAYS;
    int unsigned ready_pct   = 70;     // READY_RANDOM
    bit          drive_tstrb = 1;
    `uvm_object_utils(axis_cfg)
    function new(string name = "axis_cfg"); super.new(name); endfunction
  endclass

  typedef uvm_sequencer #(axis_item) axis_sequencer;

  class axis_master_driver extends uvm_driver #(axis_item);
    `uvm_component_utils(axis_master_driver)
    virtual axis_if vif;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      vif.m_cb.tvalid <= 0; vif.m_cb.tlast <= 0;
      @(posedge vif.rst_n);
      forever begin
        seq_item_port.get_next_item(req);
        foreach (req.data[i]) begin
          repeat ($urandom_range(req.gap_max, 0)) begin vif.m_cb.tvalid <= 0; @(vif.m_cb); end
          vif.m_cb.tdata  <= req.data[i];
          vif.m_cb.tstrb  <= req.strb[i];
          vif.m_cb.tlast  <= (i == req.data.size() - 1);
          vif.m_cb.tvalid <= 1;
          do @(vif.m_cb); while (!vif.m_cb.tready);
        end
        vif.m_cb.tvalid <= 0; vif.m_cb.tlast <= 0;
        seq_item_port.item_done();
      end
    endtask
  endclass

  // Slave side has no sequence: it just applies a TREADY policy.
  class axis_slave_driver extends uvm_component;
    `uvm_component_utils(axis_slave_driver)
    virtual axis_if vif; axis_cfg cfg;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      vif.s_cb.tready <= 0;
      @(posedge vif.rst_n);
      forever begin
        case (cfg.ready_mode)
          READY_ALWAYS: vif.s_cb.tready <= 1;
          READY_NEVER:  vif.s_cb.tready <= 0;
          READY_RANDOM: vif.s_cb.tready <= ($urandom_range(99) < cfg.ready_pct);
        endcase
        @(vif.s_cb);
      end
    endtask
  endclass

  class axis_monitor extends uvm_monitor;
    `uvm_component_utils(axis_monitor)
    virtual axis_if vif;
    uvm_analysis_port #(axis_item) ap;
    function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
    task run_phase(uvm_phase phase);
      bit [63:0] d[$]; bit [7:0] s[$]; time t0;
      forever begin
        @(vif.mon_cb);
        if (!vif.rst_n) begin d.delete(); s.delete(); continue; end
        if (vif.mon_cb.tvalid && vif.mon_cb.tready) begin
          if (d.size() == 0) t0 = $time;
          d.push_back(vif.mon_cb.tdata); s.push_back(vif.mon_cb.tstrb);
          if (vif.mon_cb.tlast) begin
            axis_item t = axis_item::type_id::create("axis_pkt");
            t.data = d; t.strb = s; t.t_first = t0; t.t_last = $time;
            `uvm_info("AXIS_MON", $sformatf("packet %0d beats", d.size()), UVM_HIGH)
            ap.write(t); d.delete(); s.delete();
          end
        end
      end
    endtask
  endclass

  class axis_agent extends uvm_agent;
    `uvm_component_utils(axis_agent)
    axis_cfg cfg; virtual axis_if vif;
    axis_master_driver mdrv; axis_slave_driver sdrv; axis_sequencer sqr; axis_monitor mon;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);   // uvm_agent::build_phase reads is_active from the config DB
      if (!uvm_config_db#(axis_cfg)::get(this, "", "cfg", cfg)) cfg = axis_cfg::type_id::create("cfg");
      if (!uvm_config_db#(virtual axis_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", get_full_name())
      mon = axis_monitor::type_id::create("mon", this); mon.vif = vif;
      if (cfg.role == AXIS_MASTER) begin
        mdrv = axis_master_driver::type_id::create("mdrv", this); mdrv.vif = vif;
        sqr  = axis_sequencer::type_id::create("sqr", this);
      end else if (cfg.role == AXIS_SLAVE) begin
        sdrv = axis_slave_driver::type_id::create("sdrv", this); sdrv.vif = vif; sdrv.cfg = cfg;
      end
    endfunction
    function void connect_phase(uvm_phase phase);
      if (cfg.role == AXIS_MASTER) mdrv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass
endpackage
