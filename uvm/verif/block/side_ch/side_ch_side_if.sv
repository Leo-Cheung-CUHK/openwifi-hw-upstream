// TSF source for the side_ch block TB (xpu tsf_timer stand-in)
`timescale 1ns/1ps
interface side_ch_side_if (input logic clk, input logic rst_n);
  logic [63:0] tsf = 0; int unsigned div = 0;
  always_ff @(posedge clk) if (!rst_n) begin tsf <= 0; div <= 0; end
    else if (div == `NUM_CLK_PER_US - 1) begin div <= 0; tsf <= tsf + 1; end else div <= div + 1;
endinterface
