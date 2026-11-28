// ow_cov_pkg - simulator-independent functional coverage (FLOW.md §3 closure targets).
// Each coverage space declares its bins up front and counts hits; at the end of a run every
// TB top calls ow_cov::dump(), which prints one line per bin:
//     OWCOV <space> <bin> <hits>
// uvm/scripts/cov_report.py merges those lines over all runs (xsim or Verilator) and checks the
// targets. Plain associative arrays: works where covergroup support is partial (Verilator).
package ow_cov_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axil_pkg::*;

  class ow_cov;
    static int unsigned hits[string][string];
    static function void declare(string space, string bin);
      if (!hits.exists(space) || !hits[space].exists(bin)) hits[space][bin] = 0;
    endfunction
    static function void hit(string space, string bin);
      if (hits.exists(space) && hits[space].exists(bin)) hits[space][bin]++;
      else hits[space][bin] = 1;
    endfunction
    static function void dump();
      foreach (hits[s]) foreach (hits[s][b]) $display("OWCOV %s %s %0d", s, b, hits[s][b]);
    endfunction
  endclass

  // RAL access coverage of one register block: every named register read, every writable one
  // also written, seen on the AXI-Lite bus (space "ral_<block>")
  class ral_access_cov extends uvm_subscriber #(axil_item);
    `uvm_component_utils(ral_access_cov)
    uvm_reg_block blk; string space;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void start_of_simulation_phase(uvm_phase phase);
      uvm_reg rl[$];
      space = {"ral_", blk.get_name()};
      blk.get_registers(rl);
      foreach (rl[i]) begin
        string n = rl[i].get_name();
        if (n.substr(0, 4) == "RSVD_") continue;
        ow_cov::declare(space, {n, ".R"});
        if (rl[i].get_rights() != "RO") ow_cov::declare(space, {n, ".W"});
      end
    endfunction
    function void write(axil_item t);
      uvm_reg r = blk.default_map.get_reg_by_offset(t.addr & 32'hFFFF, t.dir == AXIL_READ);
      string n;
      if (r == null) return;
      n = r.get_name();
      if (n.substr(0, 4) == "RSVD_") return;
      ow_cov::hit(space, {n, t.dir == AXIL_READ ? ".R" : ".W"});
    endfunction
  endclass
endpackage
