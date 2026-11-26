// axil_decoder.sv - simulation stand-in for axi_interconnect_1 (PS M_AXI_GP -> 8 slaves).
// One outstanding read and one outstanding write at a time, which is all the openwifi
// AXI-lite slaves (Xilinx template s_axi) support anyway.
// Address map (same as system.bd): slot = addr[18:16]
//   0 axi_dma_0 (absent) 1 axi_dma_1 (absent) 2 openofdm_rx 3 openofdm_tx
//   4 rx_intf            5 side_ch            6 tx_intf     7 xpu
// Accesses to absent slots complete with DECERR so tests notice wrong addresses.
`timescale 1ns/1ps

interface axil_bus_if;
  logic [31:0] awaddr;  logic [2:0] awprot; logic awvalid; logic awready;
  logic [31:0] wdata;   logic [3:0] wstrb;  logic wvalid;  logic wready;
  logic [1:0]  bresp;   logic bvalid;       logic bready;
  logic [31:0] araddr;  logic [2:0] arprot; logic arvalid; logic arready;
  logic [31:0] rdata;   logic [1:0] rresp;  logic rvalid;  logic rready;
endinterface

module axil_decoder (
  input  logic        clk, aresetn,
  input  logic [31:0] s_awaddr, input logic [2:0] s_awprot, input logic s_awvalid, output logic s_awready,
  input  logic [31:0] s_wdata,  input logic [3:0] s_wstrb,  input logic s_wvalid,  output logic s_wready,
  output logic [1:0]  s_bresp,  output logic s_bvalid,      input logic s_bready,
  input  logic [31:0] s_araddr, input logic [2:0] s_arprot, input logic s_arvalid, output logic s_arready,
  output logic [31:0] s_rdata,  output logic [1:0] s_rresp, output logic s_rvalid,  input logic s_rready,
  axil_bus_if m_openofdm_rx, axil_bus_if m_openofdm_tx, axil_bus_if m_rx_intf,
  axil_bus_if m_side_ch,     axil_bus_if m_tx_intf,     axil_bus_if m_xpu
);
  localparam int NS = 8;
  // flatten slave-side signals into arrays (index = slot)
  logic        awready [NS], wready [NS], bvalid [NS], arready [NS], rvalid [NS];
  logic [1:0]  bresp   [NS], rresp  [NS];
  logic [31:0] rdata   [NS];
  logic [NS-1:0] sel_aw, sel_w, sel_b, sel_ar, sel_r;

  // ---------------- write channel: latch target slot on AW, hold until B handshake
  logic       w_busy; logic [2:0] w_slot; logic w_aw_done, w_w_done;
  logic [31:0] aw_q; logic [2:0] awprot_q; logic [31:0] wdata_q; logic [3:0] wstrb_q;
  logic       dec_bvalid;
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      w_busy <= 0; w_aw_done <= 0; w_w_done <= 0; dec_bvalid <= 0;
    end else begin
      if (!w_busy && s_awvalid && s_wvalid) begin
        w_busy <= 1; w_slot <= s_awaddr[18:16];
        aw_q <= {16'h0, s_awaddr[15:0]}; awprot_q <= s_awprot; wdata_q <= s_wdata; wstrb_q <= s_wstrb;
        w_aw_done <= 0; w_w_done <= 0;
      end else if (w_busy) begin
        if (sel_aw[w_slot] && awready[w_slot]) w_aw_done <= 1;
        if (sel_w[w_slot]  && wready[w_slot])  w_w_done  <= 1;
        if (w_slot < 2 && !dec_bvalid) dec_bvalid <= 1;            // absent slave -> DECERR
        if (s_bvalid && s_bready) begin w_busy <= 0; dec_bvalid <= 0; end
      end
    end
  end
  assign s_awready = !w_busy && s_awvalid && s_wvalid;   // accept AW+W together
  assign s_wready  = s_awready;
  always_comb begin
    sel_aw = '0; sel_w = '0; sel_b = '0;
    if (w_busy && w_slot >= 2) begin
      sel_aw[w_slot] = !w_aw_done; sel_w[w_slot] = !w_w_done; sel_b[w_slot] = 1;
    end
  end
  assign s_bvalid = w_busy && (w_slot < 2 ? dec_bvalid : bvalid[w_slot]);
  assign s_bresp  = (w_slot < 2) ? 2'b11 : bresp[w_slot];

  // ---------------- read channel
  logic r_busy; logic [2:0] r_slot; logic r_ar_done; logic [31:0] ar_q; logic [2:0] arprot_q; logic dec_rvalid;
  always_ff @(posedge clk) begin
    if (!aresetn) begin
      r_busy <= 0; r_ar_done <= 0; dec_rvalid <= 0;
    end else begin
      if (!r_busy && s_arvalid) begin
        r_busy <= 1; r_slot <= s_araddr[18:16]; ar_q <= {16'h0, s_araddr[15:0]}; arprot_q <= s_arprot; r_ar_done <= 0;
      end else if (r_busy) begin
        if (sel_ar[r_slot] && arready[r_slot]) r_ar_done <= 1;
        if (r_slot < 2 && !dec_rvalid) dec_rvalid <= 1;
        if (s_rvalid && s_rready) begin r_busy <= 0; dec_rvalid <= 0; end
      end
    end
  end
  assign s_arready = !r_busy && s_arvalid;
  always_comb begin
    sel_ar = '0; sel_r = '0;
    if (r_busy && r_slot >= 2) begin sel_ar[r_slot] = !r_ar_done; sel_r[r_slot] = 1; end
  end
  assign s_rvalid = r_busy && (r_slot < 2 ? dec_rvalid : rvalid[r_slot]);
  assign s_rdata  = (r_slot < 2) ? 32'hDEC0_DEC0 : rdata[r_slot];
  assign s_rresp  = (r_slot < 2) ? 2'b11 : rresp[r_slot];

  // ---------------- per-slave hookup
  `define AXIL_HOOK(IFC, IDX) \
    assign IFC.awaddr = aw_q;  assign IFC.awprot = awprot_q; assign IFC.awvalid = sel_aw[IDX]; \
    assign IFC.wdata  = wdata_q; assign IFC.wstrb = wstrb_q; assign IFC.wvalid  = sel_w[IDX]; \
    assign IFC.bready = sel_b[IDX] && s_bready; \
    assign IFC.araddr = ar_q;  assign IFC.arprot = arprot_q; assign IFC.arvalid = sel_ar[IDX]; \
    assign IFC.rready = sel_r[IDX] && s_rready; \
    assign awready[IDX] = IFC.awready; assign wready[IDX] = IFC.wready; \
    assign bvalid[IDX]  = IFC.bvalid;  assign bresp[IDX]  = IFC.bresp; \
    assign arready[IDX] = IFC.arready; assign rvalid[IDX] = IFC.rvalid; \
    assign rdata[IDX]   = IFC.rdata;   assign rresp[IDX]  = IFC.rresp;
  `AXIL_HOOK(m_openofdm_rx, 2)
  `AXIL_HOOK(m_openofdm_tx, 3)
  `AXIL_HOOK(m_rx_intf,     4)
  `AXIL_HOOK(m_side_ch,     5)
  `AXIL_HOOK(m_tx_intf,     6)
  `AXIL_HOOK(m_xpu,         7)
  `undef AXIL_HOOK
  for (genvar i = 0; i < 2; i++) begin : g_absent
    assign awready[i] = 0; assign wready[i] = 0; assign bvalid[i] = 0; assign bresp[i] = 2'b11;
    assign arready[i] = 0; assign rvalid[i] = 0; assign rdata[i]  = '0; assign rresp[i] = 2'b11;
  end
endmodule
