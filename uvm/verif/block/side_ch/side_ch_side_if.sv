// side_ch block TB sideband: TSF (xpu tsf_timer stand-in), the xpu phy_rx_parse outputs side_ch
// matches on (FC_DI/addr1/addr2 + valid, assembled from openofdm_rx's byte stream exactly as
// xpu/src/phy_rx_parse.v does), and a 20 Msps counter stream on sample0_in for IQ capture.
`timescale 1ns/1ps
interface side_ch_side_if (input logic clk, input logic rst_n,
                           input logic hdr_strobe, input logic byte_strobe, input logic [7:0] byte_in);
  logic [63:0] tsf = 0; int unsigned div = 0;
  logic [31:0] fc_di = 0; logic fc_di_valid = 0;
  logic [47:0] addr1 = 0, addr2 = 0; logic addr1_valid = 0, addr2_valid = 0;
  int unsigned byte_idx = 0;
  logic [31:0] sample0 = 0; logic sample_strobe = 0;
  int unsigned sample_n = 0, sdiv = 0;            // sample0 = {16'(n), 16'(~n)}
  always_ff @(posedge clk) if (!rst_n) begin tsf <= 0; div <= 0; end
    else if (div == `NUM_CLK_PER_US - 1) begin div <= 0; tsf <= tsf + 1; end else div <= div + 1;
  always_ff @(posedge clk) begin
    if (!rst_n || hdr_strobe) begin byte_idx <= 0; fc_di_valid <= 0; addr1_valid <= 0; addr2_valid <= 0; end
    else if (byte_strobe) begin
      byte_idx <= byte_idx + 1;
      if (byte_idx < 4)  fc_di[8*byte_idx +: 8] <= byte_in;
      if (byte_idx == 3) fc_di_valid <= 1;
      if (byte_idx == 4) fc_di_valid <= 0;
      if (byte_idx >= 4 && byte_idx < 10)  addr1[8*(byte_idx-4) +: 8] <= byte_in;
      if (byte_idx == 9)  addr1_valid <= 1;
      if (byte_idx == 10) addr1_valid <= 0;
      if (byte_idx >= 10 && byte_idx < 16) addr2[8*(byte_idx-10) +: 8] <= byte_in;
      if (byte_idx == 15) addr2_valid <= 1;
      if (byte_idx == 16) addr2_valid <= 0;
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin sdiv <= 0; sample_n <= 0; sample_strobe <= 0; end
    else begin
      sample_strobe <= (sdiv == `NUM_CLK_PER_US / 20 - 1);
      if (sdiv == `NUM_CLK_PER_US / 20 - 1) begin
        sdiv <= 0; sample_n <= sample_n + 1; sample0 <= {16'(sample_n + 1), ~16'(sample_n + 1)};
      end else sdiv <= sdiv + 1;
    end
  end
endinterface
