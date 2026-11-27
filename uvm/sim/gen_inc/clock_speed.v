// sim copy of boards/ip_repo_gen.tcl output -- set to match the FPGA build you verify.
// sim/Makefile passes +define+NUM_CLK_PER_US=$(NUM_CLK_PER_US); the guard keeps RTL and TB on
// the same value when a regression overrides it (CHP-14: make regress-clk).
`ifndef NUM_CLK_PER_US
`define NUM_CLK_PER_US 100
`endif
