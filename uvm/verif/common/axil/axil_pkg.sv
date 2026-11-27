// AXI4-Lite master agent + RAL adapter.
// The openwifi slaves are Xilinx s_axi templates: they only accept a write when AWVALID
// and WVALID are high together, so the driver always presents AW and W in the same cycle.
package axil_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  typedef enum bit {AXIL_READ = 0, AXIL_WRITE = 1} axil_dir_e;

  class axil_item extends uvm_sequence_item;
    rand axil_dir_e   dir;
    rand bit [31:0]   addr;
    rand bit [31:0]   data;
    rand bit [3:0]    strb = 4'hF;
    bit      [1:0]    resp;
    constraint c_align { addr[1:0] == 0; }
    `uvm_object_utils_begin(axil_item)
      `uvm_field_enum(axil_dir_e, dir, UVM_ALL_ON)
      `uvm_field_int(addr, UVM_ALL_ON | UVM_HEX)
      `uvm_field_int(data, UVM_ALL_ON | UVM_HEX)
      `uvm_field_int(strb, UVM_ALL_ON | UVM_HEX)
      `uvm_field_int(resp, UVM_ALL_ON)
    `uvm_object_utils_end
    function new(string name = "axil_item"); super.new(name); endfunction
  endclass

  class axil_cfg extends uvm_object;
    uvm_active_passive_enum is_active = UVM_ACTIVE;
    int unsigned timeout_cycles = 1000;   // per channel handshake
    `uvm_object_utils(axil_cfg)
    function new(string name = "axil_cfg"); super.new(name); endfunction
  endclass

  typedef uvm_sequencer #(axil_item) axil_sequencer;

  class axil_driver extends uvm_driver #(axil_item);
    `uvm_component_utils(axil_driver)
    virtual axil_if vif;
    axil_cfg cfg;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "axil_if not set")
    endfunction

    task run_phase(uvm_phase phase);
      idle();
      @(posedge vif.rst_n);
      forever begin
        seq_item_port.get_next_item(req);
        if (req.dir == AXIL_WRITE) do_write(req); else do_read(req);
        seq_item_port.item_done();
      end
    endtask

    task idle();
      vif.drv_cb.awvalid <= 0; vif.drv_cb.wvalid <= 0; vif.drv_cb.bready <= 0;
      vif.drv_cb.arvalid <= 0; vif.drv_cb.rready <= 0;
      vif.drv_cb.awprot  <= 0; vif.drv_cb.arprot <= 0;
    endtask

    task do_write(axil_item t);
      int n = 0;
      bit aw_done = 0, w_done = 0;
      vif.drv_cb.awaddr <= t.addr; vif.drv_cb.awvalid <= 1;
      vif.drv_cb.wdata  <= t.data; vif.drv_cb.wstrb   <= t.strb; vif.drv_cb.wvalid <= 1;
      vif.drv_cb.bready <= 1;
      while (!(aw_done && w_done)) begin
        @(vif.drv_cb);
        if (vif.drv_cb.awready) begin aw_done = 1; vif.drv_cb.awvalid <= 0; end
        if (vif.drv_cb.wready)  begin w_done  = 1; vif.drv_cb.wvalid  <= 0; end
        if (++n > cfg.timeout_cycles) `uvm_fatal("AXIL_TO", $sformatf("AW/W timeout @%h", t.addr))
      end
      n = 0;
      do begin
        @(vif.drv_cb);
        if (++n > cfg.timeout_cycles) `uvm_fatal("AXIL_TO", $sformatf("B timeout @%h", t.addr))
      end while (!vif.drv_cb.bvalid);
      t.resp = vif.drv_cb.bresp;
      vif.drv_cb.bready <= 0;
    endtask

    task do_read(axil_item t);
      int n = 0;
      vif.drv_cb.araddr <= t.addr; vif.drv_cb.arvalid <= 1; vif.drv_cb.rready <= 1;
      do begin
        @(vif.drv_cb);
        if (++n > cfg.timeout_cycles) `uvm_fatal("AXIL_TO", $sformatf("AR timeout @%h", t.addr))
      end while (!vif.drv_cb.arready);
      vif.drv_cb.arvalid <= 0;
      n = 0;
      while (!vif.drv_cb.rvalid) begin
        @(vif.drv_cb);
        if (++n > cfg.timeout_cycles) `uvm_fatal("AXIL_TO", $sformatf("R timeout @%h", t.addr))
      end
      t.data = vif.drv_cb.rdata; t.resp = vif.drv_cb.rresp;
      @(vif.drv_cb);
      vif.drv_cb.rready <= 0;
    endtask
  endclass

  class axil_monitor extends uvm_monitor;
    `uvm_component_utils(axil_monitor)
    virtual axil_if vif;
    uvm_analysis_port #(axil_item) ap;
    function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual axil_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "axil_if not set")
    endfunction
    task run_phase(uvm_phase phase);
      fork mon_wr(); mon_rd(); join
    endtask
    task mon_wr();
      bit [31:0] a, d; bit [3:0] s; bit have_a, have_d;
      forever begin
        @(vif.mon_cb);
        if (vif.mon_cb.awvalid && vif.mon_cb.awready) begin a = vif.mon_cb.awaddr; have_a = 1; end
        if (vif.mon_cb.wvalid  && vif.mon_cb.wready)  begin d = vif.mon_cb.wdata; s = vif.mon_cb.wstrb; have_d = 1; end
        if (vif.mon_cb.bvalid  && vif.mon_cb.bready && have_a && have_d) begin
          axil_item t = axil_item::type_id::create("wr");
          t.dir = AXIL_WRITE; t.addr = a; t.data = d; t.strb = s; t.resp = vif.mon_cb.bresp;
          ap.write(t); have_a = 0; have_d = 0;
        end
      end
    endtask
    task mon_rd();
      bit [31:0] a; bit have_a;
      forever begin
        @(vif.mon_cb);
        if (vif.mon_cb.arvalid && vif.mon_cb.arready) begin a = vif.mon_cb.araddr; have_a = 1; end
        if (vif.mon_cb.rvalid && vif.mon_cb.rready && have_a) begin
          axil_item t = axil_item::type_id::create("rd");
          t.dir = AXIL_READ; t.addr = a; t.data = vif.mon_cb.rdata; t.resp = vif.mon_cb.rresp;
          ap.write(t); have_a = 0;
        end
      end
    endtask
  endclass

  class axil_agent extends uvm_agent;
    `uvm_component_utils(axil_agent)
    axil_cfg cfg; axil_driver drv; axil_sequencer sqr; axil_monitor mon;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);   // uvm_agent::build_phase reads is_active from the config DB
      if (!uvm_config_db#(axil_cfg)::get(this, "", "cfg", cfg)) cfg = axil_cfg::type_id::create("cfg");
      mon = axil_monitor::type_id::create("mon", this);
      if (cfg.is_active == UVM_ACTIVE) begin
        drv = axil_driver::type_id::create("drv", this);
        sqr = axil_sequencer::type_id::create("sqr", this);
        drv.cfg = cfg;
      end
    endfunction
    function void connect_phase(uvm_phase phase);
      if (cfg.is_active == UVM_ACTIVE) drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  // ---- RAL adapter
  class axil_reg_adapter extends uvm_reg_adapter;
    `uvm_object_utils(axil_reg_adapter)
    function new(string name = "axil_reg_adapter"); super.new(name); provides_responses = 0; endfunction
    virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
      axil_item t = axil_item::type_id::create("t");
      t.dir  = (rw.kind == UVM_WRITE) ? AXIL_WRITE : AXIL_READ;
      t.addr = rw.addr; t.data = rw.data; t.strb = 4'hF;
      return t;
    endfunction
    virtual function void bus2reg(uvm_sequence_item bus_item, ref uvm_reg_bus_op rw);
      axil_item t;
      if (!$cast(t, bus_item)) `uvm_fatal("ADAPT", "not an axil_item")
      rw.kind   = (t.dir == AXIL_WRITE) ? UVM_WRITE : UVM_READ;
      rw.addr   = t.addr; rw.data = t.data;
      rw.status = (t.resp == 2'b00) ? UVM_IS_OK : UVM_NOT_OK;
    endfunction
  endclass

  // ---- raw access sequences (for tests that bypass RAL, e.g. driver-replay)
  class axil_write_seq extends uvm_sequence #(axil_item);
    `uvm_object_utils(axil_write_seq)
    bit [31:0] addr, data;
    function new(string name = "axil_write_seq"); super.new(name); endfunction
    task body();
      req = axil_item::type_id::create("req");
      start_item(req); req.dir = AXIL_WRITE; req.addr = addr; req.data = data; req.strb = 4'hF; finish_item(req);
    endtask
  endclass
endpackage
