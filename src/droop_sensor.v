// SPDX-FileCopyrightText: 2026 lena conde araujo
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module droop_sensor (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ro_out,
    input  wire [1:0] tap_sel,    // 00: /16   01: /64   10: /256   11: /1024
    input  wire       meas_mode,  // 0: period (fast)   1: frequency (cal)
    output reg  [7:0] sample,
    output reg        valid,      // 1-cycle strobe when sample updates
    output reg        sat,        // sample saturated at 0xff; pick a lower tap
    output wire       ro_div      // tapped divided RO, routed to a pin for scope
);

  // ---- async ripple divider (RO domain) --------------------------------
  // only edges matter, but every stage still gets a real reset: without
  // one they power up X in gate-level sim, and ~X stays X, pinning valid
  // at X forever. async release is harmless -- the divider's phase means
  // nothing and its output crosses into clk through the 2ff sync below.
  //
  // one 1-bit flop per stage gathered by assign, not a shared reg [9:0]:
  // the linter calls that MULTIDRIVEN, which is fatal in the tt flow.
  wire [9:0] div;

  reg div0;
  initial div0 = 1'b0;
  always @(posedge ro_out or negedge rst_n) begin
    if (!rst_n) div0 <= 1'b0;
    else        div0 <= ~div0;
  end
  assign div[0] = div0;

  genvar i;
  generate
    for (i = 1; i < 10; i = i + 1) begin : g_div
      reg q;
      initial q = 1'b0;
      always @(posedge div[i-1] or negedge rst_n) begin
        if (!rst_n) q <= 1'b0;
        else        q <= ~q;
      end
      assign div[i] = q;
    end
  endgenerate

  assign ro_div = (tap_sel == 2'd0) ? div[3] :
                  (tap_sel == 2'd1) ? div[5] :
                  (tap_sel == 2'd2) ? div[7] :
                                      div[9];

  // ---- 2ff sync + edge detect (clk domain) -----------------------------
  reg [2:0] sync;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) sync <= 3'd0;
    else        sync <= {sync[1:0], ro_div};
  end
  wire tick = sync[1] & ~sync[2];

  // ---- measurement -----------------------------------------------------
  reg  [13:0] per_cnt;  // clk cycles since last tick (saturating)
  reg  [13:0] win_cnt;  // frequency-mode window position
  reg  [13:0] frq_cnt;  // ticks seen this window

  wire [13:0] per_next = (per_cnt == 14'h3fff) ? per_cnt : per_cnt + 14'd1;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      per_cnt <= 14'd0;
      win_cnt <= 14'd0;
      frq_cnt <= 14'd0;
      sample  <= 8'd0;
      valid   <= 1'b0;
      sat     <= 1'b0;
    end else begin
      valid <= 1'b0;

      if (!meas_mode) begin
        // period mode
        per_cnt <= tick ? 14'd1 : per_next;
        if (tick) begin
          sample <= (per_next > 14'd255) ? 8'hff : per_next[7:0];
          sat    <= (per_next > 14'd255);
          valid  <= 1'b1;
        end
      end else begin
        // frequency mode: window = 8192 clk cycles
        win_cnt <= win_cnt + 14'd1;
        if (tick) frq_cnt <= frq_cnt + 14'd1;
        if (win_cnt == 14'd8191) begin
          win_cnt <= 14'd0;
          sample  <= (frq_cnt > 14'd255) ? 8'hff : frq_cnt[7:0];
          sat     <= (frq_cnt > 14'd255);
          frq_cnt <= tick ? 14'd1 : 14'd0;
          valid   <= 1'b1;
        end
      end
    end
  end

endmodule
