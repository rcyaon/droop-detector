// SPDX-FileCopyrightText: 2026 lena conde araujo
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// minimal 8N1 uart tx for streaming sample bytes to the host.

module uart_tx #(
    parameter CLK_HZ = 27_000_000,
    parameter BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] data,
    input  wire       we,     // ignored unless busy=0
    output reg        busy,
    output reg        tx
);

  localparam integer DIV = CLK_HZ / BAUD;

  reg [15:0] baud_cnt;
  reg [3:0]  bit_idx;
  reg [9:0]  shifter;  // {stop, data[7:0], start}

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy     <= 1'b0;
      tx       <= 1'b1;
      baud_cnt <= 16'd0;
      bit_idx  <= 4'd0;
      shifter  <= 10'h3ff;
    end else if (!busy) begin
      tx <= 1'b1;
      if (we) begin
        shifter  <= {1'b1, data, 1'b0};
        busy     <= 1'b1;
        baud_cnt <= 16'd0;
        bit_idx  <= 4'd0;
      end
    end else begin
      if (baud_cnt == DIV[15:0] - 16'd1) begin
        baud_cnt <= 16'd0;
        tx       <= shifter[0];
        shifter  <= {1'b1, shifter[9:1]};
        bit_idx  <= bit_idx + 4'd1;
        if (bit_idx == 4'd10) begin
          busy <= 1'b0;
          tx   <= 1'b1;
        end
      end else begin
        baud_cnt <= baud_cnt + 16'd1;
      end
    end
  end

endmodule
