// Interrupt / event lines towards the PS, with counters and wait helpers for sequences.
interface irq_if (input logic clk, input logic rst_n);
  logic tx_itrpt;       // tx_intf
  logic rx_pkt_intr;    // rx_intf
  int unsigned n_tx_itrpt, n_rx_pkt_intr;
  logic tx_d, rx_d;
  always_ff @(posedge clk) begin
    tx_d <= tx_itrpt; rx_d <= rx_pkt_intr;
    if (!rst_n) begin n_tx_itrpt <= 0; n_rx_pkt_intr <= 0; end
    else begin
      if (tx_itrpt && !tx_d) n_tx_itrpt <= n_tx_itrpt + 1;
      if (rx_pkt_intr && !rx_d) n_rx_pkt_intr <= n_rx_pkt_intr + 1;
    end
  end
  // block until the next rising edge (or timeout in clocks -> $error)
  task automatic wait_tx_itrpt(int unsigned timeout_clks);
    int unsigned n0 = n_tx_itrpt;
    repeat (timeout_clks) begin @(posedge clk); if (n_tx_itrpt != n0) return; end
    $error("irq_if: tx_itrpt timeout");
  endtask
  task automatic wait_rx_pkt_intr(int unsigned timeout_clks);
    int unsigned n0 = n_rx_pkt_intr;
    repeat (timeout_clks) begin @(posedge clk); if (n_rx_pkt_intr != n0) return; end
    $error("irq_if: rx_pkt_intr timeout");
  endtask
endinterface
