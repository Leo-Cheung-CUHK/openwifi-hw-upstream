// 802.11a/g/n (20 MHz, 1SS, BCC) frame model and the openwifi-specific encodings
// that sit around it: driver register words (tx_config / phy_hdr_config), the
// TX DMA buffer, the openofdm_tx BRAM words, and the rx_intf DMA descriptor.
// Every encoding here is taken from openwifi-hw RTL or openwifi/driver/sdr.c and
// carries a pointer to its source so it can be re-checked when the design moves.
package wifi_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // ---------------------------------------------------------------- PHY tables
  // rate_hw_value as used by the driver / tx_bit_intf.v:
  //   legacy 4..11 -> 6,9,12,18,24,36,48,54 Mbps ; HT 0..7 -> MCS0..7 (use_ht_rate=1)
  function automatic int unsigned legacy_mbps(int unsigned hw);
    int unsigned t[8] = '{6, 9, 12, 18, 24, 36, 48, 54}; return t[hw - 4];
  endfunction
  // L-SIG RATE field R1..R4 (tx_bit_intf.v case(rate_hw_value), sdr.h wifi_mcs_table_11b_force_up)
  function automatic bit [3:0] legacy_rate_code(int unsigned hw);
    bit [3:0] t[8] = '{4'd11, 4'd15, 4'd10, 4'd14, 4'd9, 4'd13, 4'd8, 4'd12}; return t[hw - 4];
  endfunction
  function automatic int unsigned n_dbps(bit ht, int unsigned hw);
    int unsigned lg[8] = '{24, 36, 48, 72, 96, 144, 192, 216};
    int unsigned hn[8] = '{26, 52, 78, 104, 156, 208, 234, 260};
    return ht ? hn[hw] : lg[hw - 4];
  endfunction

  // ---------------------------------------------------------------- FCS
  function automatic bit [31:0] crc32(const ref byte unsigned b[$], input int unsigned n);
    bit [31:0] c = 32'hFFFF_FFFF;
    for (int i = 0; i < n; i++) begin
      c ^= b[i];
      repeat (8) c = c[0] ? (c >> 1) ^ 32'hEDB8_8320 : (c >> 1);
    end
    return ~c;
  endfunction

  // CRC-8 x^8+x^2+x+1, init all ones, complemented, over n bits LSB first
  // (802.11 HT-SIG CRC and the A-MPDU delimiter CRC use the same generator)
  function automatic bit [7:0] crc8_bits(bit [63:0] d, int unsigned n);
    bit [7:0] c = 8'hFF; bit t;
    for (int i = 0; i < n; i++) begin
      t = c[7] ^ d[i];
      c = {c[6:3], c[2], c[1] ^ t, c[0] ^ t, t};
    end
    return ~{c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]};
  endfunction

  // A-MPDU (802.11-2020 9.7): per subframe a 4-byte delimiter {EOF/rsvd[3:0], length[15:4],
  // CRC-8[23:16], signature 0x4E}, the MPDU with its FCS, then 0-3 pad bytes to a 4-byte
  // boundary (no pad after the last subframe). mpdus = concatenated MPDUs without FCS,
  // lens = their lengths. Returns the PSDU bytes the PHY transmits unchanged.
  function automatic void ampdu_pack(const ref byte unsigned mpdus[$], input int unsigned lens[$],
                                     ref byte unsigned out[$]);
    int unsigned pos = 0;
    out.delete();
    foreach (lens[s]) begin
      byte unsigned m[$]; bit [31:0] f; bit [15:0] d16; int unsigned l = lens[s] + 4;
      for (int k = 0; k < lens[s]; k++) m.push_back(mpdus[pos + k]);
      pos += lens[s];
      f = crc32(m, m.size());
      d16 = {12'(l), 4'h0};
      out.push_back(d16[7:0]); out.push_back(d16[15:8]);
      out.push_back(crc8_bits(64'(d16), 16)); out.push_back(8'h4E);
      foreach (m[k]) out.push_back(m[k]);
      for (int k = 0; k < 4; k++) out.push_back(f[8*k +: 8]);
      if (s != lens.size() - 1) while (out.size() % 4) out.push_back(8'h00);
    end
  endfunction

  // ---------------------------------------------------------------- frame item
  class wifi_frame extends uvm_sequence_item;
    // PHY
    rand bit          ht;          // 0: 11a/g legacy, 1: 11n HT-mixed
    rand int unsigned rate_hw;     // see legacy_mbps()/MCS mapping above
    rand bit          sgi;         // HT only
    rand bit          ht_aggr;     // A-MPDU single-subframe (driver adds delimiter+CRC+pad)
    // MAC
    rand int unsigned mpdu_len;    // bytes without FCS (= skb->len in the driver)
    byte unsigned mpdu[];          // filled in post_randomize() (portable: no array-size constraints)
    bit          keep_mpdu = 0;    // set to keep a caller-supplied payload across randomize()
    // TX-path control (driver tx_config)
    rand bit          need_ack;
    rand bit [1:0]    queue_idx;
    rand bit [3:0]    retry_limit;
    // filled by monitors / scoreboards
    bit               fcs_ok;
    bit [63:0]        tsf;
    shortint          rssi_half_db;

    constraint c_rate  { if (ht) rate_hw inside {[0:7]}; else rate_hw inside {[4:11]}; }
    constraint c_sgi   { if (!ht) sgi == 0; if (!ht) ht_aggr == 0; }
    constraint c_len   { mpdu_len inside {[14:1532]}; }
    constraint c_aggr  { ht_aggr == 0; }   // enable explicitly in A-MPDU tests
    constraint c_retry { retry_limit inside {[0:7]}; }
    // default: unicast QoS-less data-ish header; tests override via set_header()

    `uvm_object_utils_begin(wifi_frame)
      `uvm_field_int(ht, UVM_ALL_ON)
      `uvm_field_int(rate_hw, UVM_ALL_ON)
      `uvm_field_int(sgi, UVM_ALL_ON)
      `uvm_field_int(ht_aggr, UVM_ALL_ON)
      `uvm_field_int(mpdu_len, UVM_ALL_ON)
      `uvm_field_array_int(mpdu, UVM_ALL_ON | UVM_NOPRINT)
      `uvm_field_int(need_ack, UVM_ALL_ON)
      `uvm_field_int(queue_idx, UVM_ALL_ON)
      `uvm_field_int(fcs_ok, UVM_ALL_ON | UVM_NOCOMPARE)
    `uvm_object_utils_end
    function new(string name = "wifi_frame"); super.new(name); endfunction

    function void post_randomize();
      if (keep_mpdu && mpdu.size() == mpdu_len) return;
      mpdu = new[mpdu_len];
      foreach (mpdu[k]) mpdu[k] = 8'($urandom);
    endfunction

    // new length with a fresh random payload (for callers that fix the length after randomize())
    function void set_len(int unsigned n);
      mpdu_len = n; mpdu = new[n];
      foreach (mpdu[k]) mpdu[k] = 8'($urandom);
    endfunction

    function string rate_str();
      return ht ? $sformatf("HT-MCS%0d%s", rate_hw, sgi ? "-SGI" : "") : $sformatf("%0dMbps", legacy_mbps(rate_hw));
    endfunction
    virtual function string convert2string();
      return $sformatf("%s len=%0d ack=%0b q=%0d", rate_str(), mpdu_len, need_ack, queue_idx);
    endfunction

    // 24-byte data header: FC, duration, addr1(RA), addr2(TA), addr3, seq
    function void set_header(bit [15:0] fc, bit [15:0] dur, bit [47:0] a1, bit [47:0] a2, bit [47:0] a3, bit [11:0] seq);
      byte unsigned h[24];
      h[0] = fc[7:0]; h[1] = fc[15:8]; h[2] = dur[7:0]; h[3] = dur[15:8];
      for (int k = 0; k < 6; k++) begin h[4+k] = a1[8*k +: 8]; h[10+k] = a2[8*k +: 8]; h[16+k] = a3[8*k +: 8]; end
      h[22] = {seq[3:0], 4'h0}; h[23] = seq[11:4];
      if (mpdu.size() < 24) begin mpdu = new[24](mpdu); mpdu_len = 24; end
      foreach (h[k]) mpdu[k] = h[k];
    endfunction
    function bit [47:0] addr(int n);  // n = 1..3, needs >= 10/16/22 bytes
      bit [47:0] a; for (int k = 0; k < 6; k++) a[8*k +: 8] = mpdu[4 + 6*(n-1) + k]; return a;
    endfunction

    // PSDU as transmitted over the air: MPDU + FCS (little-endian FCS).
    // ht_aggr: mpdu[] already holds the whole A-MPDU (delimiters, MPDUs with their FCS,
    // padding; see ampdu_pack()) and the PHY appends nothing (dot11_tx HT_AGGR path).
    function void psdu(ref byte unsigned p[$]);
      bit [31:0] f;
      p.delete(); foreach (mpdu[k]) p.push_back(mpdu[k]);
      if (ht_aggr) return;
      f = crc32(p, p.size());
      for (int k = 0; k < 4; k++) p.push_back(f[8*k +: 8]);
    endfunction
    function int unsigned sig_len();       // L-SIG / HT-SIG LENGTH (tx_bit_intf: len_psdu + 4; A-MPDU: sum of subframes)
      return ht_aggr ? mpdu_len : mpdu_len + 4;
    endfunction
    function int unsigned n_sym();
      int unsigned nd = n_dbps(ht, rate_hw), nb = 16 + 8 * sig_len() + 6;
      return (nb + nd - 1) / nd;
    endfunction
    // expected burst length at 20 Msps out of openofdm_tx
    function int unsigned tx_samples();
      if (!ht) return 320 + 80 + 80 * n_sym();
      return 320 + 80 + 160 + 80 + 80 + n_sym() * (sgi ? 72 : 80);
    endfunction
    function real airtime_us(); return tx_samples() / 20.0; endfunction

    // ---------------- driver encodings (openwifi/driver/sdr.c openwifi_tx)
    function int unsigned len_psdu_drv(); return mpdu_len; endfunction   // non-aggregated
    function int unsigned num_dma_symbol(); return (len_psdu_drv() + 7) / 8; endfunction
    function bit [31:0] phy_hdr_config(bit ht_aggr_start = 0);
      return {11'd0, ht_aggr_start, 4'(rate_hw), ht, sgi, ht_aggr, 13'(len_psdu_drv())};
    endfunction
    function bit [31:0] tx_config(bit [5:0] bd_wr_idx, bit [5:0] prio = 0);
      return {prio, bd_wr_idx, queue_idx, retry_limit, need_ack, 13'(num_dma_symbol())};
    endfunction
    // TX DMA buffer (MM2S -> tx_intf s00_axis): MPDU, zero padded to 64-bit words
    function void tx_dma_bytes(ref byte unsigned b[$]);
      b.delete(); foreach (mpdu[k]) b.push_back(mpdu[k]);
      while (b.size() % 8) b.push_back(8'h00);
    endfunction

    // ---------------- openofdm_tx BRAM image, exactly as tx_bit_intf.v writes it
    // dot11_tx.v shifts these bits out raw (bram_din[plcp_bit_cnt]), so parity, CRC and
    // tail must already be in place:
    //   word0 = {32'h0, 7'd0, use_ht_rate[24], 6'd0, parity[17], LENGTH[16:5], 1'b0, RATE[3:0]}
    //   word1 = {16'd0, 6'd0, HT_SIG_CRC[41:34], ht_sig_data[33:0]}            (HT only)
    //           ht_sig_data = {2'd0, sgi, 3'd0, aggr, 3'b111, len_ht[15:0], 1'd0, 3'd0, mcs[3:0]}
    //   word2.. PSDU without FCS (crc32_tx appends it), 8 bytes per word, little-endian.
    //   The PSDU starts at word2 for legacy frames too (tx_bit_intf wr_counter<=2,
    //   dot11_tx bram_addr<=2); word1 is simply not written for legacy, so it holds stale
    //   data -> bram_words() puts 0 there and phy_tx_obs::check() skips it.
    // HT L-SIG LENGTH spoof: 3*(4+N) - 3, N = HT data symbols (LGI) or ceil(72*N/80) (SGI)
    function bit [7:0] ht_sig_crc(bit [33:0] d);      // = tx_intf/src/ht_sig_crc_calc.v
      bit [7:0] c = 8'hFF; bit t;
      for (int i = 0; i < 34; i++) begin
        t = c[7] ^ d[i];
        c = {c[6:3], c[2], c[1] ^ t, c[0] ^ t, t};
      end
      return ~{c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7]};
    endfunction
    function int unsigned ht_lsig_len();
      int unsigned n = n_sym();
      if (sgi) n = (72 * n + 79) / 80;
      return 3 * (4 + n) - 3;
    endfunction
    function void bram_words(ref bit [63:0] w[$]);
      byte unsigned b[$];
      bit [16:0] l_sig_data; bit [33:0] hsd; bit [63:0] x;
      w.delete();
      l_sig_data = {12'(ht ? ht_lsig_len() : sig_len()), 1'b0, (ht ? 4'd11 : legacy_rate_code(rate_hw))};
      w.push_back({32'h0, 7'd0, ht, 6'd0, ^l_sig_data, l_sig_data});
      if (ht) begin
        hsd = {2'd0, sgi, 3'd0, ht_aggr, 3'b111, 16'(sig_len()), 1'd0, 3'd0, 4'(rate_hw)};
        w.push_back({16'd0, 6'd0, ht_sig_crc(hsd), hsd});
      end else w.push_back('0);   // unused for legacy
      foreach (mpdu[k]) b.push_back(mpdu[k]);
      for (int i = 0; i < (b.size() + 7) / 8; i++) begin
        x = '0;
        for (int k = 0; k < 8; k++) if (8*i+k < b.size()) x[8*k +: 8] = b[8*i+k];
        w.push_back(x);
      end
    endfunction

    // rx_intf rate_idx field (sdr.c openwifi_rx_interrupt): legacy = L-SIG R code, HT = 0x10|mcs
    function bit [4:0] rx_rate_idx();
      return ht ? {1'b1, 4'(rate_hw)} : {1'b0, legacy_rate_code(rate_hw)};
    endfunction
  endclass

  // ---------------------------------------------------------------- functional coverage
  // PHY format space; connect to whatever publishes the frames a test actually used
  class wifi_frame_cov extends uvm_subscriber #(wifi_frame);
    `uvm_component_utils(wifi_frame_cov)
    wifi_frame f;
    covergroup cg;
      cp_fmt : coverpoint f.ht { bins legacy = {0}; bins ht = {1}; }
      cp_rate: coverpoint f.rate_hw { bins r[] = {[0:11]}; }
      cp_sgi : coverpoint f.sgi;
      cp_len : coverpoint f.mpdu_len { bins l_min = {[14:24]}; bins l_short = {[25:100]}; bins l_mid = {[101:600]};
                                       bins l_long = {[601:1500]}; bins l_jumbo = {[1501:8000]}; }
      // n_sym edge: PSDU ends exactly on / one bit past a symbol boundary
      cp_pad : coverpoint ((16 + 8 * f.sig_len() + 6) % n_dbps(f.ht, f.rate_hw)) { bins exact = {0}; bins other = default; }
      x_rate_len: cross cp_fmt, cp_rate, cp_len {
        ignore_bins bad_leg = binsof(cp_fmt.legacy) && binsof(cp_rate) intersect {[0:3]};
        ignore_bins bad_ht  = binsof(cp_fmt.ht) && binsof(cp_rate) intersect {[8:11]}; }
      x_ht_sgi: cross cp_rate, cp_sgi iff (f.ht);
    endgroup
    static function string LEN_BIN(int i);
      case (i) 0: return "min"; 1: return "short"; 2: return "mid"; 3: return "long"; default: return "jumbo"; endcase
    endfunction
    static function string len_bin(int unsigned n);
      return n <= 24 ? "min" : n <= 100 ? "short" : n <= 600 ? "mid" : n <= 1500 ? "long" : "jumbo";
    endfunction
    function new(string name, uvm_component parent);
      super.new(name, parent); cg = new();
      // rate x length bin x GI, as merged by cov_report.py (space "wifi_frame", target 100 %)
      for (int r = 4; r <= 11; r++) for (int l = 0; l < 5; l++) ow_cov_pkg::ow_cov::declare("wifi_frame", $sformatf("L%0d_%s", r, LEN_BIN(l)));
      for (int r = 0; r <= 7; r++) for (int l = 0; l < 5; l++) for (int g = 0; g < 2; g++)
        ow_cov_pkg::ow_cov::declare("wifi_frame", $sformatf("H%0d_%s_gi%0d", r, LEN_BIN(l), g));
    endfunction
    function void write(wifi_frame t);
      f = t; cg.sample();
      if (t.ht) ow_cov_pkg::ow_cov::hit("wifi_frame", $sformatf("H%0d_%s_gi%0d", t.rate_hw, len_bin(t.mpdu_len), t.sgi));
      else      ow_cov_pkg::ow_cov::hit("wifi_frame", $sformatf("L%0d_%s", t.rate_hw, len_bin(t.mpdu_len)));
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("WIFI_COV", $sformatf("PHY format coverage %.1f%%", cg.get_inst_coverage()), UVM_NONE)
    endfunction
  endclass

  // ---------------------------------------------------------------- RX descriptor
  // rx_intf m00_axis packet (= what axi_dma_1 S2MM writes to DDR), sdr.c offsets:
  //   +0  tsf[31:0]  +4 tsf[63:32]  +8 rssi_half_db[15:0]  +10 agc/gpio + pkt_exist[15:0]
  //   +12 len[15:0] (PSDU incl. FCS)  +14 {phase_offset[15:8], aggr_last, aggr, sgi, ht, rate[3:0]}
  //   +16 PSDU bytes; byte[16+len-1] bit7 = fcs_ok (byte_to_word_fcs_sn_insert.v)
  class rx_desc extends uvm_object;
    bit [63:0] tsf; shortint rssi_half_db; bit [15:0] agc; int unsigned len;
    bit [4:0] rate_idx; bit ht, sgi, aggr, aggr_last; bit [7:0] phase_offset;
    byte unsigned payload[$];  // len bytes, last one carries the fcs/sn byte
    bit fcs_ok; bit [6:0] sn;
    `uvm_object_utils(rx_desc)
    function new(string name = "rx_desc"); super.new(name); endfunction

    function bit parse(const ref byte unsigned b[$]);
      bit [15:0] r;
      if (b.size() < 16) return 0;
      for (int k = 0; k < 8; k++) tsf[8*k +: 8] = b[k];
      rssi_half_db = {b[9], b[8]}; agc = {b[11], b[10]}; len = {b[13], b[12]};
      r = {b[15], b[14]};
      rate_idx = r[4:0]; ht = r[4]; sgi = r[5]; aggr = r[6]; aggr_last = r[7]; phase_offset = r[15:8];
      if (b.size() < 16 + len || len == 0) return 0;
      payload.delete(); for (int k = 0; k < len; k++) payload.push_back(b[16 + k]);
      fcs_ok = payload[len - 1][7]; sn = payload[len - 1][6:0];
      return 1;
    endfunction
    virtual function string convert2string();
      return $sformatf("tsf=%0d len=%0d rate_idx=0x%0h ht=%0b sgi=%0b fcs_ok=%0b rssi=%0d agc=0x%0h",
                       tsf, len, rate_idx, ht, sgi, fcs_ok, rssi_half_db, agc);
    endfunction
  endclass
endpackage
