// Test control of the xpu stand-in in the tx_intf block TB: which queues may transmit
// (xpu slice_en, per queue) and the station MAC address (CTS-to-self RA).
interface xpu_stub_ctl_if;
  logic [3:0]  slice_en = 4'hF;
  logic [47:0] mac_addr = 48'h66_55_44_33_22_11;
  logic [1:0]  tx_queue_idx;          // tx_intf -> xpu: queue of the frame being sent (observed)
endinterface
