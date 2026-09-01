// SPDX-FileCopyrightText: 2026 lena conde araujo
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// simultaneous-switching aggressor: WIDTH flops all toggling on the same
// clk edge. every toggle draws a synchronized slug of dynamic current
// from the tile's rail, which is what actually produces the droop the
// sensor watches.
//
// modes:
//   00  off
//   01  continuous  (dc-ish load: rail settles to a new lower operating point)
//   10  one burst of burst_len cycles per trigger rising edge
//   11  periodic bursts, one every 32768 clk cycles (free-running,
//       handy when you want a repeating event to trigger a scope on)
//
// burst_len = 16 << len_sel  ->  16 .. 2048 clk cycles.
//
// the xor-reduced parity output gives the bank real observable fanout so
// no tool in the flow can argue the flops are dead logic. it gets folded
// into the heartbeat pin at top level where it changes nothing visible.

module aggressor #(
    parameter WIDTH = 128
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [1:0] mode,
    input  wire       trigger,   // raw async pin; synced internally
    input  wire [2:0] len_sel,
    output reg        active,    // high while the bank is toggling
    output wire       parity
);

  (* keep *) reg [WIDTH-1:0] bank;
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

  always @(posedge clk) begin
    if (active) bank <= ~bank;
  end

  assign parity = ^bank;

endmodule
