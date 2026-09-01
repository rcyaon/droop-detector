// SPDX-FileCopyrightText: 2026 lena conde araujo
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// all-digital supply-droop detector, ttsky26c, 1x1 tile.
//
// an RO whose frequency tracks the tile's local VDD, an on-tile
// simultaneous-switching aggressor to yank the rail on demand, and a
// small measurement core that reports either the RO period (fast
// sampling, watch the droop) or the RO frequency over a fixed window
// (slow, calibrate the sensor).
//
// pinout ------------------------------------------------------------
//  ui_in[1:0]  aggressor mode      00 off / 01 cont / 10 trig / 11 auto
//  ui_in[2]    aggressor trigger   (rising edge, mode 10)
//  ui_in[5:3]  burst length        16 << sel clk cycles (16..2048)
//  ui_in[6]    measurement mode    0 period (fast) / 1 frequency (cal)
//  ui_in[7]    RO enable           0 parks the oscillator
//
//  uio_in[1:0] divider tap         00 /16, 01 /64, 10 /256, 11 /1024
//  uio_in[2]   (reserved input)
//
//  uo_out[7:0] sample byte
//
//  uio_out[3]  sample valid strobe
//  uio_out[4]  aggressor active
//  uio_out[5]  ro_div  <- divided RO straight to a pin: put a scope on it
//  uio_out[6]  saturation flag (sample pinned at 0xff, pick a lower tap)
//  uio_out[7]  heartbeat (~6 Hz at 50 MHz) xor aggressor parity

module tt_um_rcyaon_droop (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  // ---- config from pins ------------------------------------------------
  wire [1:0] agg_mode  = ui_in[1:0];
  wire       agg_trig  = ui_in[2];
  wire [2:0] agg_len   = ui_in[5:3];
  wire       meas_mode = ui_in[6];
  wire       ro_en     = ui_in[7];
  wire [1:0] tap_sel   = uio_in[1:0];

  // ---- sensor ----------------------------------------------------------
  wire ro_out, ro_div;
  wire [7:0] sample;
  wire valid, sat;

  ro_osc #(
      .STAGES(25)
  ) u_ro (
      .en    (ro_en),
      .ro_out(ro_out)
  );

  droop_sensor u_sense (
      .clk      (clk),
      .rst_n    (rst_n),
      .ro_out   (ro_out),
      .tap_sel  (tap_sel),
      .meas_mode(meas_mode),
      .sample   (sample),
      .valid    (valid),
      .sat      (sat),
      .ro_div   (ro_div)
  );

  // ---- aggressor -------------------------------------------------------
  wire agg_active, agg_parity;

  aggressor #(
      .WIDTH(128)
  ) u_agg (
      .clk    (clk),
      .rst_n  (rst_n),
      .mode   (agg_mode),
      .trigger(agg_trig),
      .len_sel(agg_len),
      .active (agg_active),
      .parity (agg_parity)
  );

  // ---- heartbeat -------------------------------------------------------
  reg [22:0] hb;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) hb <= 23'd0;
    else        hb <= hb + 23'd1;
  end

  // ---- outputs ---------------------------------------------------------
  assign uo_out = sample;

  assign uio_oe  = 8'b1111_1000;  // [2:0] inputs, [7:3] outputs
  assign uio_out = {
      hb[22] ^ agg_parity,  // [7] heartbeat (parity xor keeps bank alive)
      sat,                  // [6]
      ro_div,               // [5]
      agg_active,           // [4]
      valid,                // [3]
      3'b000                // [2:0] configured as inputs, drive 0
  };

  // avoid unused warnings
  wire _unused = &{ena, uio_in[7:2], 1'b0};

endmodule
