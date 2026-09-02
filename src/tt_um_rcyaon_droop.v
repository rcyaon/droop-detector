// SPDX-FileCopyrightText: 2026 lena conde araujo
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// all-digital supply-droop detector, ttsky26c, 1x1 tile. an RO tracks
// local VDD, an aggressor yanks the rail on demand, and the measurement
// core reports RO period (fast) or frequency (calibration). see README.
//
// pinout ------------------------------------------------------------
//  ui_in[1:0]  aggressor mode: 00 off / 01 cont / 10 trig / 11 auto
//  ui_in[2]    aggressor trigger (rising edge)
//  ui_in[5:3]  burst length, 16 << sel clk cycles
//  ui_in[6]    0 period mode / 1 frequency mode
//  ui_in[7]    RO enable (0 parks it)
//  uio_in[1:0] divider tap: /16 /64 /256 /1024
//  uio_in[2]   measure the clk/2 self-test source instead of the RO
//  uo_out[7:0] sample byte
//  uio_out[3]  valid    [4] agg active    [5] divided RO (scope this)
//  uio_out[6]  sat      [7] heartbeat ^ parity of bank[7:0]

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
  wire       st_sel    = uio_in[2];

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

  // the measured source is the ring, or a clk/2 square wave when
  // st_sel is set. that self-test path earns its ~10 um^2 twice over:
  // on silicon it exercises the whole divider/counter chain against a
  // known frequency without trusting the ring, and in gate-level sim it
  // is the only way the measurement path can run at all. under the
  // sky130 FUNCTIONAL models every combinational cell is zero-delay, so
  // the hardened ring is a zero-delay loop: release its enable and the
  // event simulator spins at one timestamp forever. GL therefore leaves
  // the ring parked and measures st_clk, whose counts are exact.
  reg st_clk;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) st_clk <= 1'b0;
    else        st_clk <= ~st_clk;
  end

  wire ro_meas = st_sel ? st_clk : ro_out;

  droop_sensor u_sense (
      .clk      (clk),
      .rst_n    (rst_n),
      .ro_out   (ro_meas),
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
      .WIDTH(64)
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
      hb[22] ^ agg_parity,  // [7] the xor is what keeps the bank alive
      sat,                  // [6]
      ro_div,               // [5]
      agg_active,           // [4]
      valid,                // [3]
      3'b000                // [2:0] configured as inputs, drive 0
  };

  // avoid unused warnings
  wire _unused = &{ena, uio_in[7:3], 1'b0};

endmodule
