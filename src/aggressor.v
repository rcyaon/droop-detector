// SPDX-FileCopyrightText: 2026 lena conde araujo
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// simultaneous-switching aggressor: WIDTH flops toggling on one clk
// edge, each toggle pulling a slug of current off the tile's rail.
//
// modes: 00 off, 01 continuous, 10 one burst per trigger edge,
//        11 a burst every 32768 clk.  burst_len = 16 << len_sel.
//
// WIDTH=64 and the 8-bit parity are area limits, not preferences: 128
// flops blew detailed placement on a 1x1 tile, and a full ^bank is a
// 127-gate tree. 

module aggressor #(
    parameter WIDTH = 64
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [1:0] mode,
    input  wire       trigger,   // raw async pin; synced internally
    input  wire [2:0] len_sel,
    output reg        active,    // high while the bank is toggling
    output wire       parity
);

  (* keep = "true" *) reg [WIDTH-1:0] bank;
  initial bank = {WIDTH{1'b0}};

  reg  [2:0]  trig_sync;
  reg  [11:0] burst_cnt;
  reg  [14:0] period_cnt;

  wire        trig_rise = trig_sync[1] & ~trig_sync[2];
  wire [11:0] burst_len = 12'd16 << len_sel;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      trig_sync  <= 3'd0;
      burst_cnt  <= 12'd0;
      period_cnt <= 15'd0;
      active     <= 1'b0;
    end else begin
      trig_sync  <= {trig_sync[1:0], trigger};
      period_cnt <= period_cnt + 15'd1;

      case (mode)
        2'b00: begin
          active    <= 1'b0;
          burst_cnt <= 12'd0;
        end
        2'b01: begin
          active <= 1'b1;
        end
        2'b10: begin
          if (trig_rise)              burst_cnt <= burst_len;
          else if (burst_cnt != 0)    burst_cnt <= burst_cnt - 12'd1;
          active <= (burst_cnt != 12'd0);
        end
        2'b11: begin
          if (period_cnt == 15'd0)    burst_cnt <= burst_len;
          else if (burst_cnt != 0)    burst_cnt <= burst_cnt - 12'd1;
          active <= (burst_cnt != 12'd0);
        end
      endcase
    end
  end

  // the value means nothing (current load, not state); reset only so the
  // bank isn't X forever in gate-level sim. 
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)      bank <= {WIDTH{1'b0}};
    else if (active) bank <= ~bank;
  end

  // 7 gates, not WIDTH-1: just enough to keep opt_clean off the bank.
  assign parity = ^bank[7:0];

endmodule
