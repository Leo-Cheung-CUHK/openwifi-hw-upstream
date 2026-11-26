`timescale 1ns/1ps
module tb;
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1, start = 0; reg [63:0] din; wire [9:0] addr; wire v, done, started; wire signed [15:0] i, q;
  reg [63:0] mem [0:1023];
  integer n = 0, cyc = 0, fo; string f;
  initial begin
    if (!$value$plusargs("MEM=%s", f)) f = "x.mem";
    for (int k = 0; k < 1024; k++) mem[k] = 0;
    $readmemh(f, mem); fo = $fopen("tx_iq.txt","w");
    repeat (5) @(posedge clk); rst = 0; @(posedge clk); start = 1; @(posedge clk); start = 0;
  end
  always @(posedge clk) begin
    din <= mem[addr]; cyc++;
    if (v) begin n++; $fdisplay(fo, "%0d %0d", i, q); end
    if (done) begin $display("RESULT samples=%0d cycles=%0d", n, cyc); $finish; end
    if (cyc > 2000000) begin $display("TIMEOUT n=%0d", n); $finish; end
  end
  dot11_tx dut(.clk(clk), .phy_tx_arest(rst), .phy_tx_start(start), .phy_tx_done(done), .phy_tx_started(started),
    .init_pilot_scram_state(7'h7f), .init_data_scram_state(7'h7f), .bram_din(din), .bram_addr(addr),
    .result_iq_ready(1'b1), .result_iq_valid(v), .result_i(i), .result_q(q));
endmodule
