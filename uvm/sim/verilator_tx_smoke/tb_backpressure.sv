// dot11_tx under tx_intf-like back-pressure (Verilator, no UVM).
// ready = ~tx_hold, tx_hold = FIFO occupancy > TH, FIFO drained at 20 Msps (1 per 5 clk @100 MHz)
// -- the same rule as tx_iq_intf.v (tx_hold = data_count > tx_hold_threshold).
// Runs 2000 clocks past phy_tx_done so a late last sample would still be counted.
`timescale 1ns/1ps
module tb;
  reg clk = 0; always #5 clk = ~clk;
  reg rst = 1, start = 0, rdy = 1;
  reg [63:0] din; wire [9:0] addr; wire v, done, started; wire signed [15:0] i, q;
  reg [63:0] mem [0:1023];
  integer n = 0, cyc = 0, fo, occ = 0, TH = 420, tdone = 0; string f;
  initial begin
    if (!$value$plusargs("MEM=%s", f)) f = "x.mem";
    void'($value$plusargs("TH=%d", TH));
    for (int k = 0; k < 1024; k++) mem[k] = 0;
    $readmemh(f, mem); fo = $fopen("tx_iq.txt", "w");
    repeat (5) @(posedge clk); rst = 0; @(posedge clk); start = 1; @(posedge clk); start = 0;
  end
  always @(posedge clk) begin
    din <= mem[addr]; cyc++;
    if (v && rdy) begin n++; occ = occ + 1; $fdisplay(fo, "%0d %0d", i, q); end
    if (cyc % 5 == 0 && occ > 0) occ = occ - 1;
    rdy <= !(occ > TH);
    if (done && tdone == 0) tdone = cyc;
    if (tdone != 0 && cyc == tdone + 2000) begin $display("RESULT samples=%0d done_at=%0d", n, tdone); $finish; end
    if (cyc > 2000000) begin $display("TIMEOUT samples=%0d", n); $finish; end
  end
  dot11_tx dut(.clk(clk), .phy_tx_arest(rst), .phy_tx_start(start), .phy_tx_done(done), .phy_tx_started(started),
    .init_pilot_scram_state(7'h7f), .init_data_scram_state(7'h7f), .bram_din(din), .bram_addr(addr),
    .result_iq_ready(rdy), .result_iq_valid(v), .result_i(i), .result_q(q));
endmodule
