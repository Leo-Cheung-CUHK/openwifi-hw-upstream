# gen_xilinx_ip_sim.tcl - simulation models for the Xilinx IP inside openofdm_rx
#   (xfft_v9, viterbi_v7_0, complex_multiplier, div_gen*, atan_lut, rot_lut, deinter_lut,
#    div_for_rotafft, div_gen_csi_over_nova)
#
# vivado -mode batch -source gen_xilinx_ip_sim.tcl -tclargs <openwifi-hw> <out_dir> <part> <simulator> [lib_map_path]
#   part      : xczu48dr-ffvg1517-2-e (RFSoC4x2) / xczu9eg-ffvb1156-2-e (ZCU102) -> zynquplus xci
#               any xc7z* part                                             -> zynq xci
#   simulator : xsim | questa | vcs | xcelium | riviera
#   lib_map_path : compile_simlib output (required for 3rd-party simulators)
#
# Needs Vivado 2022.2 (the version openwifi-hw targets) and a Viterbi Decoder licence
# (evaluation licence is enough) -- the same prerequisites as building the FPGA.
# Output: <out_dir>/xip_sources.txt  "<library> <language> <file>" in compile order
#                                    (consumed by sim/Makefile, any simulator)
#         <out_dir>/export/<simulator>/ export_simulation scripts (reference / fallback)
#         <out_dir>/div_gen.v       plain wrapper used by dot11.v

set hw   [lindex $argv 0]
set out  [file normalize [lindex $argv 1]]
set part [lindex $argv 2]
set sim  [lindex $argv 3]
set libmap [expr {[llength $argv] > 4 ? [lindex $argv 4] : ""}]

set fam [expr {[string match "xc7z*" $part] ? "zynq" : "zynquplus"}]
set rx  [file normalize $hw/ip/openofdm_rx/verilog]
file mkdir $out
create_project -in_memory -part $part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

# the div_gen wrapper lives in a small IP-integrator style package
set dg $rx/coregen/div_gen_new_ip_core_$fam/src
file copy -force $dg/div_gen.v $out/div_gen.v

set xcis {}
foreach ip {atan_lut complex_multiplier deinter_lut rot_lut div_for_rotafft div_gen_csi_over_nova} {
  lappend xcis $rx/Xilinx/$fam/$ip/$ip.xci
}
lappend xcis $rx/Xilinx/$fam/viterbi/viterbi_v7_0.xci
lappend xcis $rx/Xilinx/$fam/xfft/xfft_v9.xci
lappend xcis $dg/div_gen_div_gen_0_0/div_gen_div_gen_0_0.xci
lappend xcis $dg/div_gen_xlslice_0_0/div_gen_xlslice_0_0.xci

# work on copies so the repository stays clean
foreach x $xcis {
  set n [file rootname [file tail $x]]
  file mkdir $out/ip/$n
  file copy -force $x $out/ip/$n/
  # LUT IPs reference .coe files next to the .xci
  foreach coe [glob -nocomplain [file dirname $x]/*.coe] { file copy -force $coe $out/ip/$n/ }
  read_ip $out/ip/$n/[file tail $x]
}
upgrade_ip [get_ips] -quiet
generate_target simulation [get_ips]

# simulator-agnostic compile list: "<library> <verilog|systemverilog|vhdl> <path>", in order
set fh [open $out/xip_sources.txt w]
foreach f [get_files -compile_order sources -used_in simulation -of_objects [get_ips]] {
  set t [string tolower [get_property FILE_TYPE $f]]
  if {[string match "*vhdl*" $t]} { set t vhdl } elseif {[string match "*systemverilog*" $t]} { set t systemverilog } else { set t verilog }
  puts $fh "[get_property LIBRARY $f] $t $f"
}
puts $fh "xil_defaultlib verilog $out/div_gen.v"
close $fh

set args [list -of_objects [get_ips] -simulator $sim -directory $out/export -force -use_ip_compiled_libs]
if {$libmap ne ""} { lappend args -lib_map_path $libmap }
export_simulation {*}$args
puts "Xilinx IP simulation models exported to $out/export/$sim"
