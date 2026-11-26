// tx_intf <-> openofdm_tx bundle ("ACC" interface in the RTL comments).
// BRAM read latency is 1 cycle (xpm_memory_tdpram READ_LATENCY=1 in tx_bit_intf.v).
interface phy_tx_if (input logic clk, input logic rst_n);
  logic        phy_tx_start;       // tx_intf -> openofdm_tx
  logic        tx_hold;            // tx_intf -> openofdm_tx (result_iq_hold)
  logic [9:0]  bram_addr;          // openofdm_tx -> tx_intf
  logic [63:0] bram_din;           // tx_intf -> openofdm_tx (data_to_acc)
  logic signed [15:0] result_i, result_q;
  logic        result_iq_valid;
  logic        phy_tx_started, phy_tx_done;

  clocking srv_cb @(posedge clk);   // TB = tx_intf side (BRAM server)
    default input #1step output #1;
    output phy_tx_start, tx_hold, bram_din;
    input  bram_addr, result_i, result_q, result_iq_valid, phy_tx_started, phy_tx_done;
  endclocking
  clocking acc_cb @(posedge clk);   // TB = openofdm_tx side (ACC model)
    default input #1step output #1;
    output bram_addr, result_i, result_q, result_iq_valid, phy_tx_started, phy_tx_done;
    input  phy_tx_start, tx_hold, bram_din;
  endclocking
  clocking mon_cb @(posedge clk);
    default input #1step;
    input phy_tx_start, tx_hold, bram_addr, bram_din, result_i, result_q, result_iq_valid, phy_tx_started, phy_tx_done;
  endclocking

  // I/Q is a valid/ready handshake with ready = ~tx_hold: tx_iq_intf.v writes its FIFO with
  // (~tx_hold & rf_iq_valid), dot11_tx.v keeps result_iq_valid up until ready. So a sample
  // offered during hold must stay on the bus unchanged until it is taken.
  a_iq_stable_in_hold: assert property (@(posedge clk) disable iff (!rst_n)
                         (result_iq_valid && tx_hold) |=> result_iq_valid && $stable({result_i, result_q}))
                       else $error("I/Q sample changed or withdrawn while tx_hold=1 (sample lost)");
  // every offered sample must be taken before the PHY declares the packet done
  a_no_pending_at_done: assert property (@(posedge clk) disable iff (!rst_n)
                          phy_tx_done |-> !(result_iq_valid && tx_hold))
                        else $error("phy_tx_done while the last I/Q sample is still waiting for ~tx_hold");
  a_done_after_start: assert property (@(posedge clk) disable iff (!rst_n)
                        $rose(phy_tx_start) |-> ##[1:$] phy_tx_done) else $error("phy_tx_done never followed phy_tx_start");
endinterface
