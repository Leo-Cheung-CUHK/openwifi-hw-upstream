// viterbi_v7_0_sova.sv: drop-in replacement for the Xilinx viterbi_v7_0 IP instance in
// openofdm_rx (ofdm_decoder.v), same module name and ports, built on sova_dec.
// Compile it instead of the Xilinx IP model (uvm/sim: VIT=sova). The extra port
// m_axis_llr_tdata carries the per-bit LLR (positive = bit 0); ofdm_decoder.v leaves it
// unconnected until a consumer is added.
// SOVA rule: BR-SOVA by default, HR-SOVA with +define+SOVA_HR.
`timescale 1ns/1ps
module viterbi_v7_0 (
    input  wire        aclk,
    input  wire        aresetn,
    input  wire        aclken,
    input  wire [15:0] s_axis_data_tdata,
    input  wire [7:0]  s_axis_data_tuser,
    input  wire        s_axis_data_tvalid,
    output wire        s_axis_data_tready,
    output wire [7:0]  m_axis_data_tdata,
    output wire        m_axis_data_tvalid,
    output wire [7:0]  m_axis_llr_tdata
);
`ifdef SOVA_HR
  localparam int BR = 0;
`else
  localparam int BR = 1;
`endif
  sova_dec #(.BR(BR), .D(84), .LR(48)) u_sova (
    .aclk(aclk), .aresetn(aresetn), .aclken(aclken),
    .s_axis_data_tdata(s_axis_data_tdata), .s_axis_data_tuser(s_axis_data_tuser),
    .s_axis_data_tvalid(s_axis_data_tvalid), .s_axis_data_tready(s_axis_data_tready),
    .m_axis_data_tdata(m_axis_data_tdata), .m_axis_data_tvalid(m_axis_data_tvalid),
    .m_axis_llr_tdata(m_axis_llr_tdata));
endmodule
