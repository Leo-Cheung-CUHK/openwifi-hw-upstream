// DAC (40 Msps, every other sample zero -- dac_intf.v) -> 20 Msps strobe stream for the
// peer receiver in the core clock domain.
// Any two consecutive DAC samples contain exactly one real sample and one zero, so their
// sum is the 20 Msps sample regardless of which phase dac_intf is in. The pair is handed
// to the core clock with a toggle + 2-FF synchroniser (data is held for 2 dac clocks,
// longer than the synchroniser latency, so this is safe with ideal TB clocks).
`timescale 1ns/1ps
module dac_to_peer_rx (
  input  logic        dac_clk, dac_rst,
  input  logic [63:0] dac_data,          // {Q1,I1,Q0,I0}
  input  logic        clk, rst_n,
  output logic [31:0] sample,            // {I,Q} ant0
  output logic        strobe
);
  logic [15:0] i_d, q_d; logic ph, tgl; logic [31:0] held;
  always_ff @(posedge dac_clk) begin
    if (dac_rst) begin ph <= 0; tgl <= 0; i_d <= 0; q_d <= 0; held <= 0; end
    else begin
      i_d <= dac_data[15:0]; q_d <= dac_data[31:16]; ph <= ~ph;
      if (ph) begin
        held <= {16'(dac_data[15:0] + i_d), 16'(dac_data[31:16] + q_d)};
        tgl  <= ~tgl;
      end
    end
  end
  logic [2:0] s;
  always_ff @(posedge clk) begin
    if (!rst_n) begin s <= 0; strobe <= 0; sample <= 0; end
    else begin
      s <= {s[1:0], tgl};
      strobe <= s[2] ^ s[1];
      if (s[2] ^ s[1]) sample <= held;
    end
  end
endmodule
