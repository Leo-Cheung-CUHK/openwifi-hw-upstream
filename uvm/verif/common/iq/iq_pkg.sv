// I/Q stimulus and capture.
//  * iq_driver streams samples continuously (the openofdm receiver needs a live stream):
//    when no sequence item is pending it sends the idle floor (zeros or low-level noise).
//  * iq_monitor cuts the captured stream into bursts (one per packet) and publishes them.
//  * iq_file_util reads/writes the "I Q" text format used by openofdm_rx/testing_inputs.
package iq_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  typedef enum {PACK_ADC64, PACK_IQ32} iq_pack_e;
  typedef enum {VALID_PULSE, VALID_LEVEL} iq_valid_e;

  class iq_item extends uvm_sequence_item;
    // complex baseband at 20 Msps, ant0 (and optional ant1)
    shortint i0[$], q0[$], i1[$], q1[$];
    int unsigned idle_before = 0;    // samples of idle floor before the burst
    string       src_file;           // provenance, for reports
    time         t_start, t_end;
    `uvm_object_utils_begin(iq_item)
      `uvm_field_string(src_file, UVM_ALL_ON)
      `uvm_field_int(idle_before, UVM_ALL_ON)
    `uvm_object_utils_end
    function new(string name = "iq_item"); super.new(name); endfunction
    function int unsigned size(); return i0.size(); endfunction
    function real energy();
      real e = 0; foreach (i0[k]) e += real'(i0[k])**2 + real'(q0[k])**2; return e;
    endfunction
  endclass

  class iq_cfg extends uvm_object;
    iq_pack_e    pack            = PACK_IQ32;
    iq_valid_e   valid_style     = VALID_PULSE;
    int unsigned clk_per_sample  = 5;    // e.g. 100 MHz / 20 Msps
    int unsigned repeat_n        = 1;    // ADC path: 40 MHz adc_clk, each 20 Msps sample sent twice
    int unsigned noise_amp       = 0;    // idle floor: uniform +/- noise_amp (0 = exact zeros)
    bit          dup_ant1        = 1;    // drive ant1 = ant0 when item has no ant1 data
    // monitor
    int unsigned decim           = 1;    // DAC path: 40 Msps zero-stuffed -> 2
    int unsigned end_gap_samples = 64;   // burst closes after this many idle samples
    int unsigned idle_thresh     = 0;    // |I|,|Q| <= thresh counts as idle
    int unsigned end_gap_clks    = 2000; // ...or after this many clocks without 'valid'
    bit          use_ready       = 0;    // valid/ready handshake bus: sample only on valid && ready
    `uvm_object_utils(iq_cfg)
    function new(string name = "iq_cfg"); super.new(name); endfunction
  endclass

  function automatic bit [63:0] pack_iq(iq_pack_e p, shortint i0, shortint q0, shortint i1, shortint q1);
    if (p == PACK_ADC64) return {q1, i1, q0, i0};
    return {32'h0, i0, q0};
  endfunction
  function automatic void unpack_iq(iq_pack_e p, bit [63:0] d, output shortint i0, q0, i1, q1);
    if (p == PACK_ADC64) begin i0 = d[15:0]; q0 = d[31:16]; i1 = d[47:32]; q1 = d[63:48]; end
    else begin i0 = d[31:16]; q0 = d[15:0]; i1 = 0; q1 = 0; end
  endfunction

  typedef uvm_sequencer #(iq_item) iq_sequencer;

  class iq_driver extends uvm_driver #(iq_item);
    `uvm_component_utils(iq_driver)
    virtual iq_if vif; iq_cfg cfg;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    function shortint noise();
      return (cfg.noise_amp == 0) ? 0 : shortint'($urandom_range(2*cfg.noise_amp) - cfg.noise_amp);
    endfunction

    // one 20 Msps sample slot on the bus
    task send(shortint i0, shortint q0, shortint i1, shortint q1);
      repeat (cfg.repeat_n) begin
        for (int c = 0; c < cfg.clk_per_sample; c++) begin
          vif.drv_cb.data  <= pack_iq(cfg.pack, i0, q0, i1, q1);
          vif.drv_cb.valid <= (cfg.valid_style == VALID_LEVEL) ? 1'b1 : (c == 0);
          @(vif.drv_cb);
        end
      end
    endtask

    task run_phase(uvm_phase phase);
      vif.drv_cb.data <= '0; vif.drv_cb.valid <= 0;
      @(posedge vif.rst_n);
      forever begin
        seq_item_port.try_next_item(req);
        if (req == null) begin
          shortint n0 = noise(), n1 = noise();
          send(n0, noise(), n1, noise());
          continue;
        end
        repeat (req.idle_before) send(noise(), noise(), noise(), noise());
        req.t_start = $time;
        foreach (req.i0[k]) begin
          bit has1 = (req.i1.size() == req.i0.size());
          send(req.i0[k], req.q0[k],
               has1 ? req.i1[k] : (cfg.dup_ant1 ? req.i0[k] : 0),
               has1 ? req.q1[k] : (cfg.dup_ant1 ? req.q0[k] : 0));
        end
        req.t_end = $time;
        seq_item_port.item_done();
      end
    endtask
  endclass

  class iq_monitor extends uvm_monitor;
    `uvm_component_utils(iq_monitor)
    virtual iq_if vif; iq_cfg cfg;
    uvm_analysis_port #(iq_item) ap;
    function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction

    function bit is_idle(shortint i, shortint q);
      return ($signed(i) <= int'(cfg.idle_thresh) && $signed(i) >= -int'(cfg.idle_thresh) &&
              $signed(q) <= int'(cfg.idle_thresh) && $signed(q) >= -int'(cfg.idle_thresh));
    endfunction

    task run_phase(uvm_phase phase);
      // raw capture at bus rate, decimated when the burst closes
      shortint ri0[$], rq0[$], ri1[$], rq1[$];
      int unsigned idle_run, no_valid_clks; bit in_burst; time t0;
      forever begin
        shortint i0, q0, i1, q1;
        @(vif.mon_cb);
        if (!vif.rst_n) continue;
        if (!vif.mon_cb.valid || (cfg.use_ready && !vif.mon_cb.ready)) begin
          // strobe-style sources (openofdm_tx) simply stop strobing after the packet
          if (in_burst && ++no_valid_clks >= cfg.end_gap_clks) begin
            publish(ri0, rq0, ri1, rq1, idle_run, t0);
            ri0.delete(); rq0.delete(); ri1.delete(); rq1.delete(); in_burst = 0;
          end
          continue;
        end
        no_valid_clks = 0;
        unpack_iq(cfg.pack, vif.mon_cb.data, i0, q0, i1, q1);
        if (!in_burst) begin
          if (is_idle(i0, q0) && is_idle(i1, q1)) continue;
          in_burst = 1; idle_run = 0; t0 = $time;
        end
        ri0.push_back(i0); rq0.push_back(q0); ri1.push_back(i1); rq1.push_back(q1);
        idle_run = (is_idle(i0, q0) && is_idle(i1, q1)) ? idle_run + 1 : 0;
        if (idle_run >= cfg.end_gap_samples * cfg.decim) begin
          publish(ri0, rq0, ri1, rq1, idle_run, t0);
          ri0.delete(); rq0.delete(); ri1.delete(); rq1.delete(); in_burst = 0;
        end
      end
    endtask

    // drop the trailing idle run; for decim>1 pick the phase that carries energy
    function void publish(ref shortint ri0[$], rq0[$], ri1[$], rq1[$], input int unsigned tail, time t0);
      iq_item t = iq_item::type_id::create("iq_burst");
      int unsigned n = ri0.size() - tail;
      int unsigned best = 0; real e_best = -1;
      for (int ph = 0; ph < cfg.decim; ph++) begin
        real e = 0;
        for (int k = ph; k < n; k += cfg.decim) e += real'(ri0[k])**2 + real'(rq0[k])**2 + real'(ri1[k])**2 + real'(rq1[k])**2;
        if (e > e_best) begin e_best = e; best = ph; end
      end
      for (int k = best; k < n; k += cfg.decim) begin
        t.i0.push_back(ri0[k]); t.q0.push_back(rq0[k]); t.i1.push_back(ri1[k]); t.q1.push_back(rq1[k]);
      end
      t.t_start = t0; t.t_end = $time;
      `uvm_info("IQ_MON", $sformatf("burst: %0d samples @20Msps (phase %0d/%0d)", t.size(), best, cfg.decim), UVM_MEDIUM)
      ap.write(t);
    endfunction
  endclass

  class iq_agent extends uvm_agent;
    `uvm_component_utils(iq_agent)
    iq_cfg cfg; virtual iq_if vif;
    iq_driver drv; iq_sequencer sqr; iq_monitor mon;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);   // uvm_agent::build_phase reads is_active from the config DB
      if (!uvm_config_db#(iq_cfg)::get(this, "", "cfg", cfg)) cfg = iq_cfg::type_id::create("cfg");
      if (!uvm_config_db#(virtual iq_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", get_full_name())
      mon = iq_monitor::type_id::create("mon", this); mon.vif = vif; mon.cfg = cfg;
      if (get_is_active() == UVM_ACTIVE) begin
        drv = iq_driver::type_id::create("drv", this); drv.vif = vif; drv.cfg = cfg;
        sqr = iq_sequencer::type_id::create("sqr", this);
      end
    endfunction
    function void connect_phase(uvm_phase phase);
      if (get_is_active() == UVM_ACTIVE) drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  // ---- file helpers: "I Q" per line, 20 Msps (openofdm_rx/testing_inputs/*)
  class iq_file_util;
    static function bit read(string fname, iq_item t);
      int fd, n; int i, q;
      fd = $fopen(fname, "r");
      if (fd == 0) return 0;
      while (!$feof(fd)) begin
        n = $fscanf(fd, "%d %d\n", i, q);
        if (n == 2) begin t.i0.push_back(shortint'(i)); t.q0.push_back(shortint'(q)); end
      end
      $fclose(fd); t.src_file = fname;
      return 1;
    endfunction
    static function void write(string fname, iq_item t);
      int fd = $fopen(fname, "w");
      foreach (t.i0[k]) $fwrite(fd, "%0d %0d\n", t.i0[k], t.q0[k]);
      $fclose(fd);
    endfunction
  endclass

  // ---- simple impairments applied in sequences (not in the driver)
  class iq_impair;
    // scale by linear gain (saturating to int16)
    static function void scale(iq_item t, real g);
      foreach (t.i0[k]) begin t.i0[k] = sat(real'(t.i0[k]) * g); t.q0[k] = sat(real'(t.q0[k]) * g); end
    endfunction
    // carrier frequency offset, f_hz at 20 Msps
    static function void cfo(iq_item t, real f_hz);
      real ph, c, s, i, q;
      foreach (t.i0[k]) begin
        ph = 2.0 * 3.14159265358979 * f_hz * k / 20.0e6; c = $cos(ph); s = $sin(ph);
        i = t.i0[k]; q = t.q0[k];
        t.i0[k] = sat(i * c - q * s); t.q0[k] = sat(i * s + q * c);
      end
    endfunction
    // complex AWGN at snr_db relative to the mean power of the non-idle samples
    // (Box-Muller on $urandom, so the noise follows the simulator seed)
    static function void awgn(iq_item t, real snr_db);
      real p = 0, sig, u1, u2, r; int unsigned n = 0;
      foreach (t.i0[k]) if (t.i0[k] != 0 || t.q0[k] != 0) begin p += real'(t.i0[k])**2 + real'(t.q0[k])**2; n++; end
      if (n == 0) return;
      sig = $sqrt(p / n / (10.0 ** (snr_db / 10.0)) / 2.0);
      foreach (t.i0[k]) begin
        u1 = (real'($urandom) + 1.0) / 4294967297.0; u2 = real'($urandom) / 4294967296.0;
        r = sig * $sqrt(-2.0 * $ln(u1));
        t.i0[k] = sat(real'(t.i0[k]) + r * $cos(2.0 * 3.14159265358979 * u2));
        t.q0[k] = sat(real'(t.q0[k]) + r * $sin(2.0 * 3.14159265358979 * u2));
      end
    endfunction
    // n samples of complex Gaussian noise with the given rms (per complex sample)
    static function iq_item noise(int unsigned n, real rms);
      iq_item t = new("noise"); real u1, u2, r;
      repeat (n) begin
        u1 = (real'($urandom) + 1.0) / 4294967297.0; u2 = real'($urandom) / 4294967296.0;
        r = rms / $sqrt(2.0) * $sqrt(-2.0 * $ln(u1));
        t.i0.push_back(sat(r * $cos(2.0 * 3.14159265358979 * u2))); t.q0.push_back(sat(r * $sin(2.0 * 3.14159265358979 * u2)));
        t.i1.push_back(0); t.q1.push_back(0);
      end
      return t;
    endfunction
    // append b after a, separated by gap zero samples (back-to-back bursts in one item)
    static function void concat(iq_item a, iq_item b, int unsigned gap);
      repeat (gap) begin a.i0.push_back(0); a.q0.push_back(0); a.i1.push_back(0); a.q1.push_back(0); end
      foreach (b.i0[k]) begin
        a.i0.push_back(b.i0[k]); a.q0.push_back(b.q0[k]);
        a.i1.push_back(k < b.i1.size() ? b.i1[k] : 0); a.q1.push_back(k < b.q1.size() ? b.q1[k] : 0);
      end
    endfunction
    static function shortint sat(real x);
      if (x > 32767.0) return 32767; if (x < -32768.0) return -32768; return shortint'($rtoi(x));
    endfunction
  endclass
endpackage
