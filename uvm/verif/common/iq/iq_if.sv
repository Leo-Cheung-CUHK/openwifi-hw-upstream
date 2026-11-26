// Baseband I/Q bus. 64 bits wide so one interface covers both layouts used in openwifi:
//   PACK_ADC64 : adc_data / dac_data  = {Q1, I1, Q0, I0}  (2 antennas, 16b each)
//   PACK_IQ32  : sample0 / result_iq = {I, Q} in [31:0]  (single stream)
// 'valid' is a strobe (openofdm sample_in_strobe, result_iq_valid) or a level (adc_valid).
// 'ready' is only used by the DAC side (dac_ready) and openofdm_tx hold (inverted).
interface iq_if (input logic clk, input logic rst_n);
  logic [63:0] data;
  logic        valid;
  logic        ready;

  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output data, valid; input ready;
  endclocking
  clocking mon_cb @(posedge clk);
    default input #1step;
    input data, valid, ready;
  endclocking
endinterface
