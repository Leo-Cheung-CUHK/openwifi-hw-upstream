// sova_dec: soft-output Viterbi decoder for 802.11 BCC (K=7, 133/171), drop-in for the
// Xilinx Viterbi v9.1 instance in openofdm_rx (soft width 3, offset binary, external
// puncturing via erase, D=84) plus a per-bit LLR output.
//
// Bit-exact spec: uvm/scripts/sova_ref.py, SovaRef(D, LR, mode, rmax=2^RW-1, llr_w=LLRW,
// shift=1, init_penalty=INIT_PEN, arch="C").
//
// Pipeline (accepts one input per clock):
//   S  : branch metrics, 64 ACS, survivor bits (register exchange, depth D), Delta
//   R  : reliability register exchange over LR lags (HR or BR rule)
//   T  : 6-level registered best-state tree carrying (bit@D-1, bit@LR-1, R@LR-1)
//   O  : (D-LR)-deep delay line aligns R with the depth-D bit; LLR = 0 if they disagree
// Output: one bit per input once D inputs have been seen since reset.
// LLR sign convention: positive = bit 0, unit = channel LLR Lc = 7 - 2*sym.
`timescale 1ns/1ps
module sova_dec #(
    parameter int BR       = 1,   // 1: BR-SOVA (Battail/Fossorier), 0: HR-SOVA (Hagenauer)
    parameter int D        = 84,  // decision depth (Xilinx traceback length)
    parameter int LR       = 48,  // reliability window
    parameter int PMW      = 10,  // path metric width (modulo arithmetic)
    parameter int RW       = 6,   // reliability width, RMAX = 2^RW-1
    parameter int LLRW     = 6,   // output LLR width (signed)
    parameter int INIT_PEN = 64   // start-state penalty for states != 0
) (
    input  logic        aclk,
    input  logic        aresetn,
    input  logic        aclken,
    input  logic [15:0] s_axis_data_tdata,   // {5'b0, sym1, 5'b0, sym0}
    input  logic [7:0]  s_axis_data_tuser,   // {6'b0, erase1, erase0}
    input  logic        s_axis_data_tvalid,
    output logic        s_axis_data_tready,
    output logic [7:0]  m_axis_data_tdata,   // {7'b0, bit}
    output logic        m_axis_data_tvalid,
    output logic [7:0]  m_axis_llr_tdata     // sign-extended LLRW-bit LLR, same beat
);
  localparam int NS   = 64;
  localparam int RMAX = (1 << RW) - 1;
  localparam int DL   = D - LR;
  localparam int NW   = PMW + 2 + RW;   // tree node: {pm, bit_d, bit_lr, r}
  localparam int TL   = 6;              // log2(NS)

  initial begin
    if (!(LR >= 2 && DL >= 1)) $fatal(1, "sova_dec: need 2 <= LR < D");
  end

  // ---------------- code tables ----------------
  function automatic logic enc_a(input int p, input int u);
    logic [6:0] r; r = 7'((u << 6) | p); return ^(r & 7'o133);
  endfunction
  function automatic logic enc_b(input int p, input int u);
    logic [6:0] r; r = 7'((u << 6) | p); return ^(r & 7'o171);
  endfunction

  assign s_axis_data_tready = 1'b1;

  // ---------------- input / branch metrics ----------------
  wire        v  = s_axis_data_tvalid & aclken;
  wire [2:0]  s0 = s_axis_data_tdata[2:0];
  wire [2:0]  s1 = s_axis_data_tdata[10:8];
  wire signed [4:0] lc0 = s_axis_data_tuser[0] ? 5'sd0 : 5'sd7 - $signed({1'b0, s0, 1'b0});
  wire signed [4:0] lc1 = s_axis_data_tuser[1] ? 5'sd0 : 5'sd7 - $signed({1'b0, s1, 1'b0});
  // bm[{a,b}] for coded bits (a,b): (1-2a)*lc0 + (1-2b)*lc1
  wire signed [5:0] bm [4];
  assign bm[0] =  lc0 + lc1;
  assign bm[1] =  lc0 - lc1;
  assign bm[2] = -lc0 + lc1;
  assign bm[3] = -lc0 - lc1;

  // ---------------- per-state logic (stages S and R) ----------------
  function automatic logic [RW-1:0] umin(input logic [RW-1:0] a, input logic [RW-1:0] b);
    return (a < b) ? a : b;
  endfunction
  function automatic logic [RW-1:0] sat_add(input logic [RW-1:0] a, input logic [RW-1:0] b);
    logic [RW:0] t; t = a + b; return t[RW] ? RW'(RMAX) : t[RW-1:0];
  endfunction

  logic [$clog2(D)-1:0] cnt_q;
  logic v1_q, v2_q, en1_q, en2_q;
  logic [NW-1:0] leaf [NS];

  for (genvar n = 0; n < NS; n++) begin : g_st
    localparam int U  = n >> 5;
    localparam int P0 = (n & 31) << 1;
    localparam int P1 = P0 | 1;
    localparam logic [1:0] I0 = {enc_a(P0, U), enc_b(P0, U)};
    localparam logic [1:0] I1 = {enc_a(P1, U), enc_b(P1, U)};

    logic [PMW-1:0]   pm;      // stage S
    logic [D-1:0]     bits;    // bit j = lag j (0 = newest)
    logic             sel;
    logic [RW-1:0]    delta;
    logic [LR-1:0]    rb;      // stage R: path bits in the reliability window
    logic [LR*RW-1:0] relv;    // rel[j] = relv[j*RW +: RW]
    logic [PMW-1:0]   pmd;     // stage R: copies for the tree
    logic             bd;

    // ---- S: ACS ----
    wire [PMW-1:0] m0   = g_st[P0].pm + PMW'(bm[I0]);
    wire [PMW-1:0] m1   = g_st[P1].pm + PMW'(bm[I1]);
    wire [PMW-1:0] diff = m1 - m0;
    wire           s_n  = ~diff[PMW-1] & (|diff);
    wire [PMW-1:0] absd = diff[PMW-1] ? -diff : diff;
    wire [RW-1:0]  d_n  = (absd > PMW'(RMAX)) ? RW'(RMAX) : absd[RW-1:0];
    wire [D-1:0]   bits_n = s_n ? {g_st[P1].bits[D-2:0], 1'(U)} : {g_st[P0].bits[D-2:0], 1'(U)};

    always_ff @(posedge aclk) begin
      if (!aresetn) begin
        pm    <= (n == 0) ? '0 : PMW'(-INIT_PEN);
        bits  <= '0;
        sel   <= 1'b0;
        delta <= '0;
      end else if (aclken && v) begin
        pm    <= s_n ? m1 : m0;
        bits  <= bits_n;
        sel   <= s_n;
        delta <= d_n;
      end
    end

    // ---- R: reliability register exchange ----
    wire [LR-1:0]    rbs = sel ? g_st[P1].rb   : g_st[P0].rb;
    wire [LR-1:0]    rbc = sel ? g_st[P0].rb   : g_st[P1].rb;
    wire [LR*RW-1:0] rls = sel ? g_st[P1].relv : g_st[P0].relv;
    wire [LR*RW-1:0] rlc = sel ? g_st[P0].relv : g_st[P1].relv;
    logic [LR*RW-1:0] relv_n;
    always_comb begin
      relv_n[0 +: RW] = RW'(RMAX);
      for (int j = 0; j < LR - 1; j++) begin
        logic [RW-1:0] rs, rc;
        rs = rls[j*RW +: RW];
        rc = rlc[j*RW +: RW];
        if (rbs[j] != rbc[j])  relv_n[(j+1)*RW +: RW] = umin(rs, delta);
        else if (BR != 0)      relv_n[(j+1)*RW +: RW] = umin(rs, sat_add(delta, rc));
        else                   relv_n[(j+1)*RW +: RW] = rs;
      end
    end

    always_ff @(posedge aclk) begin
      if (!aresetn) begin
        rb   <= '0;
        relv <= {LR{RW'(RMAX)}};
        pmd  <= '0;
        bd   <= 1'b0;
      end else if (aclken && v1_q) begin
        rb   <= {rbs[LR-2:0], 1'(U)};
        relv <= relv_n;
        pmd  <= pm;
        bd   <= bits[D-1];
      end
    end

    assign leaf[n] = {pmd, bd, rb[LR-1], relv[(LR-1)*RW +: RW]};
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      cnt_q <= '0;
      v1_q  <= 1'b0;
      v2_q  <= 1'b0;
      en1_q <= 1'b0;
      en2_q <= 1'b0;
    end else if (aclken) begin
      v1_q <= v;
      v2_q <= v1_q;
      if (v) begin
        en1_q <= (int'(cnt_q) >= D - 1);
        if (int'(cnt_q) < D - 1) cnt_q <= cnt_q + 1'b1;
      end
      if (v1_q) en2_q <= en1_q;
    end
  end

  // ---------------- stage T: best-state tree (lowest index wins ties) ----------------
  function automatic logic [NW-1:0] better(input logic [NW-1:0] a, input logic [NW-1:0] b);
    logic [PMW-1:0] d;
    d = b[NW-1 -: PMW] - a[NW-1 -: PMW];
    return (~d[PMW-1] & (|d)) ? b : a;
  endfunction

  for (genvar l = 1; l <= TL; l++) begin : g_tree
    localparam int W = NS >> l;
    logic [NW-1:0] nq [W];
    logic          tv, ten;
    logic [NW-1:0] prev [2*W];
    logic          pv, pen;
    if (l == 1) begin : g_in
      for (genvar i = 0; i < 2 * W; i++) begin : g_c
        assign prev[i] = leaf[i];
      end
      assign pv  = v2_q;
      assign pen = en2_q;
    end else begin : g_in
      for (genvar i = 0; i < 2 * W; i++) begin : g_c
        assign prev[i] = g_tree[l-1].nq[i];
      end
      assign pv  = g_tree[l-1].tv;
      assign pen = g_tree[l-1].ten;
    end
    always_ff @(posedge aclk) begin
      if (!aresetn) begin
        tv  <= 1'b0;
        ten <= 1'b0;
      end else if (aclken) begin
        tv  <= pv;
        ten <= pen;
        for (int i = 0; i < W; i++) nq[i] <= better(prev[2*i], prev[2*i+1]);
      end
    end
  end

  // ---------------- stage O: delay line + output ----------------
  logic [RW:0] dline_q [DL];   // {bit_lr, r}
  wire  [NW-1:0] root   = g_tree[TL].nq[0];
  wire           root_v  = g_tree[TL].tv;
  wire           root_en = g_tree[TL].ten;
  wire           r_bd   = root[RW+1];
  wire  [RW:0]   r_push = root[RW:0];
  wire  [RW:0]   r_pop  = dline_q[DL-1];
  wire  [RW-2:0] mag_raw = (r_pop[RW] == r_bd) ? r_pop[RW-1:1] : '0;  // R >> 1
  localparam int LMAX = (1 << (LLRW - 1)) - 1;
  wire  [LLRW-1:0] mag  = (int'(mag_raw) > LMAX) ? LLRW'(LMAX) : LLRW'(mag_raw);
  wire  [LLRW-1:0] llr  = r_bd ? -mag : mag;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      for (int i = 0; i < DL; i++) dline_q[i] <= '0;
      m_axis_data_tvalid <= 1'b0;
      m_axis_data_tdata  <= '0;
      m_axis_llr_tdata   <= '0;
    end else if (aclken) begin
      m_axis_data_tvalid <= 1'b0;
      if (root_v) begin
        dline_q[0] <= r_push;
        for (int i = 1; i < DL; i++) dline_q[i] <= dline_q[i-1];
        if (root_en) begin
          m_axis_data_tvalid <= 1'b1;
          m_axis_data_tdata  <= {7'b0, r_bd};
          m_axis_llr_tdata   <= 8'($signed(llr));
        end
      end
    end
  end

`ifndef SYNTHESIS
  // LLR sign must agree with the decided bit (0 allowed for either)
  always @(posedge aclk) if (aresetn && aclken && m_axis_data_tvalid)
    assert (m_axis_data_tdata[0] ? ($signed(m_axis_llr_tdata) <= 0) : ($signed(m_axis_llr_tdata) >= 0))
      else $error("sova_dec: LLR sign %0d disagrees with bit %0d", $signed(m_axis_llr_tdata), m_axis_data_tdata[0]);
`endif
endmodule
