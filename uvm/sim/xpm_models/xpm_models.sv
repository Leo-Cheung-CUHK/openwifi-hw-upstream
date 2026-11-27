// Behavioural models of the Xilinx XPM primitives used by tx_intf, rx_intf, xpu and side_ch,
// for simulators without a Vivado install (Verilator in S0 CI). With Vivado present the flow
// compiles the real $XILINX_VIVADO/data/ip/xpm sources instead (sim/Makefile XPM_SRC).
//
// Only the configurations the openwifi RTL instantiates are modelled; anything else stops the
// simulation at time 0 so a new use is noticed instead of silently mis-modelled:
//   xpm_fifo_sync        READ_MODE "fwft", FIFO_READ_LATENCY 0 (all 31 instances)
//   xpm_fifo_async       READ_MODE "std",  FIFO_READ_LATENCY 1 (rx_intf gpio_status)
//   xpm_memory_tdpram    common clock, READ_LATENCY 1, whole-word writes (tx_bit_intf BRAM)
//   xpm_cdc_array_single DEST_SYNC_FF-stage synchroniser
// Differences from the real primitives, all on the conservative side for this RTL:
//   * flags and data counts update one clock after the write/read (XPM FWFT shows a new word
//     on dout 1-3 clocks later); wr_data_count == rd_data_count == occupancy
//   * no reset-busy period (wr_rst_busy / rd_rst_busy stay 0)
//   * writes to a full FIFO / reads of an empty one are ignored and flagged (overflow/underflow)
//   * xpm_fifo_sync fwft holds FIFO_WRITE_DEPTH + 1 words (depth - 1 in the array + the 2-word
//     output stage), as the real primitive: xpu mv_avg writes at a count of FIFO_WRITE_DEPTH
//     and relies on wr_data_count reaching FIFO_WRITE_DEPTH + 1
`timescale 1ns/1ps

module xpm_fifo_sync #(
  parameter string  DOUT_RESET_VALUE = "0", parameter string ECC_MODE = "no_ecc",
  parameter string  FIFO_MEMORY_TYPE = "auto", parameter integer FIFO_READ_LATENCY = 1,
  parameter integer FIFO_WRITE_DEPTH = 2048, parameter integer FULL_RESET_VALUE = 0,
  parameter integer PROG_EMPTY_THRESH = 10, parameter integer PROG_FULL_THRESH = 10,
  parameter integer RD_DATA_COUNT_WIDTH = 1, parameter integer READ_DATA_WIDTH = 32,
  parameter string  READ_MODE = "std", parameter integer SIM_ASSERT_CHK = 0,
  parameter string  USE_ADV_FEATURES = "0707", parameter integer WAKEUP_TIME = 0,
  parameter integer WRITE_DATA_WIDTH = 32, parameter integer WR_DATA_COUNT_WIDTH = 1
) (
  input  wire sleep, input wire rst, input wire wr_clk, input wire wr_en,
  input  wire [WRITE_DATA_WIDTH-1:0] din,
  output wire full, output wire prog_full, output wire [WR_DATA_COUNT_WIDTH-1:0] wr_data_count,
  output reg  overflow, output wire wr_rst_busy, output wire almost_full, output reg wr_ack,
  input  wire rd_en,
  output wire [READ_DATA_WIDTH-1:0] dout,
  output wire empty, output wire prog_empty, output wire [RD_DATA_COUNT_WIDTH-1:0] rd_data_count,
  output reg  underflow, output wire rd_rst_busy, output wire almost_empty, output wire data_valid,
  input  wire injectsbiterr, input wire injectdbiterr, output wire sbiterr, output wire dbiterr
);
  initial if (READ_MODE != "fwft" || FIFO_READ_LATENCY != 0 || READ_DATA_WIDTH != WRITE_DATA_WIDTH)
    $fatal(1, "xpm_fifo_sync model: only fwft / latency 0 / equal widths (got %s, %0d, %0d/%0d) in %m",
           READ_MODE, FIFO_READ_LATENCY, WRITE_DATA_WIDTH, READ_DATA_WIDTH);
  localparam integer CAP = FIFO_WRITE_DEPTH + 1;
  reg [WRITE_DATA_WIDTH-1:0] mem [0:CAP-1];
  integer wp, rp, cnt;
  wire do_wr = wr_en && cnt != CAP;
  wire do_rd = rd_en && cnt != 0;
  always @(posedge wr_clk) begin
    if (rst) begin wp <= 0; rp <= 0; cnt <= 0; overflow <= 0; underflow <= 0; wr_ack <= 0; end
    else begin
      if (do_wr) begin mem[wp] <= din; wp <= (wp == CAP - 1) ? 0 : wp + 1; end
      if (do_rd) rp <= (rp == CAP - 1) ? 0 : rp + 1;
      cnt <= cnt + do_wr - do_rd;
      overflow <= wr_en && !do_wr; underflow <= rd_en && !do_rd; wr_ack <= do_wr;
    end
  end
  assign dout          = (cnt != 0) ? mem[rp] : '0;
  assign empty         = (cnt == 0);
  assign full          = (cnt == CAP);
  assign almost_empty  = (cnt <= 1);
  assign almost_full   = (cnt >= CAP - 1);
  assign prog_full     = (cnt >= PROG_FULL_THRESH);
  assign prog_empty    = (cnt <= PROG_EMPTY_THRESH);
  assign data_valid    = (cnt != 0);
  assign wr_data_count = WR_DATA_COUNT_WIDTH'(cnt);
  assign rd_data_count = RD_DATA_COUNT_WIDTH'(cnt);
  assign wr_rst_busy = 1'b0; assign rd_rst_busy = 1'b0; assign sbiterr = 1'b0; assign dbiterr = 1'b0;
endmodule

module xpm_fifo_async #(
  parameter integer CDC_SYNC_STAGES = 2, parameter string DOUT_RESET_VALUE = "0",
  parameter string  ECC_MODE = "no_ecc", parameter string FIFO_MEMORY_TYPE = "auto",
  parameter integer FIFO_READ_LATENCY = 1, parameter integer FIFO_WRITE_DEPTH = 2048,
  parameter integer FULL_RESET_VALUE = 0, parameter integer PROG_EMPTY_THRESH = 10,
  parameter integer PROG_FULL_THRESH = 10, parameter integer RD_DATA_COUNT_WIDTH = 1,
  parameter integer READ_DATA_WIDTH = 32, parameter string READ_MODE = "std",
  parameter integer RELATED_CLOCKS = 0, parameter integer SIM_ASSERT_CHK = 0,
  parameter string  USE_ADV_FEATURES = "0707", parameter integer WAKEUP_TIME = 0,
  parameter integer WRITE_DATA_WIDTH = 32, parameter integer WR_DATA_COUNT_WIDTH = 1
) (
  input  wire sleep, input wire rst, input wire wr_clk, input wire wr_en,
  input  wire [WRITE_DATA_WIDTH-1:0] din,
  output wire full, output wire prog_full, output wire [WR_DATA_COUNT_WIDTH-1:0] wr_data_count,
  output wire overflow, output wire wr_rst_busy, output wire almost_full, output wire wr_ack,
  input  wire rd_clk, input wire rd_en,
  output reg  [READ_DATA_WIDTH-1:0] dout,
  output wire empty, output wire prog_empty, output wire [RD_DATA_COUNT_WIDTH-1:0] rd_data_count,
  output wire underflow, output wire rd_rst_busy, output wire almost_empty, output wire data_valid,
  input  wire injectsbiterr, input wire injectdbiterr, output wire sbiterr, output wire dbiterr
);
  initial if (READ_MODE != "std" || FIFO_READ_LATENCY != 1 || READ_DATA_WIDTH != WRITE_DATA_WIDTH)
    $fatal(1, "xpm_fifo_async model: only std / latency 1 / equal widths in %m");
  localparam integer AW = $clog2(FIFO_WRITE_DEPTH);
  reg [WRITE_DATA_WIDTH-1:0] mem [0:FIFO_WRITE_DEPTH-1];
  reg [AW:0] wp = 0, rp = 0;                      // binary pointers; the model crosses them directly
  wire [AW:0] occ = wp - rp;
  always @(posedge wr_clk) if (rst) wp <= 0; else if (wr_en && occ != FIFO_WRITE_DEPTH) begin mem[wp[AW-1:0]] <= din; wp <= wp + 1'b1; end
  always @(posedge rd_clk) if (rst) begin rp <= 0; dout <= '0; end
                           else if (rd_en && occ != 0) begin dout <= mem[rp[AW-1:0]]; rp <= rp + 1'b1; end
  assign full = (occ == FIFO_WRITE_DEPTH); assign empty = (occ == 0);
  assign almost_full = (occ >= FIFO_WRITE_DEPTH - 1); assign almost_empty = (occ <= 1);
  assign prog_full = (occ >= PROG_FULL_THRESH); assign prog_empty = (occ <= PROG_EMPTY_THRESH);
  assign wr_data_count = WR_DATA_COUNT_WIDTH'(occ); assign rd_data_count = RD_DATA_COUNT_WIDTH'(occ);
  assign overflow = 1'b0; assign underflow = 1'b0; assign wr_ack = 1'b0; assign data_valid = 1'b0;
  assign wr_rst_busy = 1'b0; assign rd_rst_busy = 1'b0; assign sbiterr = 1'b0; assign dbiterr = 1'b0;
endmodule

module xpm_memory_tdpram #(
  parameter integer MEMORY_SIZE = 2048, parameter string MEMORY_PRIMITIVE = "auto",
  parameter string  CLOCKING_MODE = "common_clock", parameter string MEMORY_INIT_FILE = "none",
  parameter string  MEMORY_INIT_PARAM = "", parameter integer USE_MEM_INIT = 1,
  parameter string  WAKEUP_TIME = "disable_sleep", parameter integer MESSAGE_CONTROL = 0,
  parameter string  ECC_MODE = "no_ecc", parameter string AUTO_SLEEP_TIME = "0",
  parameter integer USE_EMBEDDED_CONSTRAINT = 0, parameter string MEMORY_OPTIMIZATION = "true",
  parameter integer CASCADE_HEIGHT = 0, parameter integer SIM_ASSERT_CHK = 0,
  parameter integer WRITE_PROTECT = 1, parameter integer RST_MODE_A = 0, parameter integer RST_MODE_B = 0,
  parameter integer WRITE_DATA_WIDTH_A = 32, parameter integer READ_DATA_WIDTH_A = 32,
  parameter integer BYTE_WRITE_WIDTH_A = 32, parameter integer ADDR_WIDTH_A = 6,
  parameter         READ_RESET_VALUE_A = "0", parameter integer READ_LATENCY_A = 2,
  parameter string  WRITE_MODE_A = "no_change",
  parameter integer WRITE_DATA_WIDTH_B = 32, parameter integer READ_DATA_WIDTH_B = 32,
  parameter integer BYTE_WRITE_WIDTH_B = 32, parameter integer ADDR_WIDTH_B = 6,
  parameter         READ_RESET_VALUE_B = "0", parameter integer READ_LATENCY_B = 2,
  parameter string  WRITE_MODE_B = "no_change"
) (
  input  wire sleep,
  input  wire clka, input wire rsta, input wire ena, input wire regcea,
  input  wire [(WRITE_DATA_WIDTH_A/BYTE_WRITE_WIDTH_A)-1:0] wea,
  input  wire [ADDR_WIDTH_A-1:0] addra, input wire [WRITE_DATA_WIDTH_A-1:0] dina,
  input  wire injectsbiterra, input wire injectdbiterra,
  output reg  [READ_DATA_WIDTH_A-1:0] douta, output wire sbiterra, output wire dbiterra,
  input  wire clkb, input wire rstb, input wire enb, input wire regceb,
  input  wire [(WRITE_DATA_WIDTH_B/BYTE_WRITE_WIDTH_B)-1:0] web,
  input  wire [ADDR_WIDTH_B-1:0] addrb, input wire [WRITE_DATA_WIDTH_B-1:0] dinb,
  input  wire injectsbiterrb, input wire injectdbiterrb,
  output reg  [READ_DATA_WIDTH_B-1:0] doutb, output wire sbiterrb, output wire dbiterrb
);
  initial if (READ_LATENCY_A != 1 || READ_LATENCY_B != 1 || BYTE_WRITE_WIDTH_A != WRITE_DATA_WIDTH_A ||
              WRITE_DATA_WIDTH_A != WRITE_DATA_WIDTH_B || CLOCKING_MODE != "common_clock")
    $fatal(1, "xpm_memory_tdpram model: only common clock, latency 1, whole-word writes in %m");
  localparam integer W = WRITE_DATA_WIDTH_A;
  reg [W-1:0] mem [0:(1<<ADDR_WIDTH_A)-1];
  initial foreach (mem[i]) mem[i] = '0;
  always @(posedge clka) begin
    if (ena && wea[0]) mem[addra] <= dina;
    if (rsta) douta <= '0; else if (ena) douta <= wea[0] ? dina : mem[addra];       // write_first
    if (rstb) doutb <= '0; else if (enb) doutb <= (web[0] ? dinb : mem[addrb]);     // old data on A/B collision
    if (enb && web[0]) mem[addrb] <= dinb;
  end
  assign sbiterra = 1'b0; assign dbiterra = 1'b0; assign sbiterrb = 1'b0; assign dbiterrb = 1'b0;
endmodule

module xpm_cdc_array_single #(
  parameter integer DEST_SYNC_FF = 4, parameter integer INIT_SYNC_FF = 0,
  parameter integer SIM_ASSERT_CHK = 0, parameter integer SRC_INPUT_REG = 1, parameter integer WIDTH = 2
) (
  input wire src_clk, input wire [WIDTH-1:0] src_in, input wire dest_clk, output wire [WIDTH-1:0] dest_out
);
  reg [WIDTH-1:0] src_q;
  reg [WIDTH-1:0] sync [0:DEST_SYNC_FF-1];
  always @(posedge src_clk) src_q <= src_in;
  wire [WIDTH-1:0] d = SRC_INPUT_REG ? src_q : src_in;
  always @(posedge dest_clk) begin
    sync[0] <= d;
    for (int i = 1; i < DEST_SYNC_FF; i++) sync[i] <= sync[i-1];
  end
  assign dest_out = sync[DEST_SYNC_FF-1];
endmodule

module xpm_cdc_single #(
  parameter integer DEST_SYNC_FF = 4, parameter integer INIT_SYNC_FF = 0,
  parameter integer SIM_ASSERT_CHK = 0, parameter integer SRC_INPUT_REG = 1
) (input wire src_clk, input wire src_in, input wire dest_clk, output wire dest_out);
  xpm_cdc_array_single #(.DEST_SYNC_FF(DEST_SYNC_FF), .SRC_INPUT_REG(SRC_INPUT_REG), .WIDTH(1))
    u (.src_clk(src_clk), .src_in(src_in), .dest_clk(dest_clk), .dest_out(dest_out));
endmodule
