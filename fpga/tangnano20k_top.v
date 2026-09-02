// SPDX-FileCopyrightText: 2026 lena conde araujo
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// tang nano 20k wrapper. synthesize with -DFPGA so ro_osc uses the gowin
// LUT1 chain. 27 MHz crystal drives clk (only the period counts scale),
// S1 triggers the aggressor, S2 selects frequency mode, LEDs show
// sample[7:2]. samples arriving while the uart is busy are dropped --
// decimation, so a slow uart never stalls the sensor.
//
// read it with: python3 -c "import serial;s=serial.Serial(
//   '/dev/ttyUSB1',115200);[print(s.read()[0]) for _ in iter(int,1)]"

module tangnano20k_top (
    input  wire       sys_clk,   // 27 MHz
    input  wire       s1,        // button, active low
    input  wire       s2,        // button, active low
    output wire [5:0] led,       // active low
    output wire       uart_txp
);

  // ---- compile-time config --------------------------------------------
  localparam [1:0] AGG_MODE = 2'b10;  // triggered burst on S1
  localparam [2:0] AGG_LEN  = 3'd4;   // 16<<4 = 256 cycle bursts
  localparam [1:0] TAP_SEL  = 2'b01;  // /64

  // ---- power-on reset --------------------------------------------------
  reg [7:0] por = 8'd0;
  wire rst_n = por[7];
  always @(posedge sys_clk) begin
    if (!por[7]) por <= por + 8'd1;
  end

  // ---- tt module -------------------------------------------------------
  wire [7:0] ui_in = {
      1'b1,        // [7] ro enable
      ~s2,         // [6] hold S2 for frequency/cal mode
      AGG_LEN,     // [5:3]
      ~s1,         // [2] trigger (button is active low)
      AGG_MODE     // [1:0]
  };

  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;

  tt_um_rcyaon_droop u_tt (
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in ({6'b0, TAP_SEL}),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (1'b1),
      .clk    (sys_clk),
      .rst_n  (rst_n)
  );

  wire valid = uio_out[3];

  // ---- leds ------------------------------------------------------------
  reg [7:0] sample_r;
  always @(posedge sys_clk) begin
    if (valid) sample_r <= uo_out;
  end
  assign led = ~sample_r[7:2];

  // ---- uart stream -----------------------------------------------------
  wire uart_busy;
  uart_tx #(
      .CLK_HZ(27_000_000),
      .BAUD  (115_200)
  ) u_uart (
      .clk  (sys_clk),
      .rst_n(rst_n),
      .data (uo_out),
      .we   (valid & ~uart_busy),
      .busy (uart_busy),
      .tx   (uart_txp)
  );

endmodule
