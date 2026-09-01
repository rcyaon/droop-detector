// SPDX-FileCopyrightText: 2026 lena conde araujo
// SPDX-License-Identifier: Apache-2.0

`default_nettype none
`ifdef SIM
`timescale 1ns / 1ps
`endif

// supply-sensing ring oscillator with enable gate.
//
// three implementations, selected by define:
//   SIM    - behavioral fixed-period model (cocotb / iverilog). the RTL sim
//            can't oscillate a real loop, so this stands in for it. the
//            frequency is arbitrary; tests only exercise the counters.
//   FPGA   - gowin LUT1 buffer chain with syn_keep (tang nano 20k). LUT
//            delay is VDD/temp dependent, so the sensor genuinely works
//            on the fpga too, just with different absolute numbers.
//   (none) - sky130 tapeout path: nand2 closes the loop (the single
//            inversion), dlygate4sd3 cells slow it down so the ripple
//            divider's first flop isn't asked to toggle at multi-GHz.
//
// loop topology (silicon):  nand2 -> dly[0] -> ... -> dly[STAGES-1] -+
//                             ^A                                     |
//                             +-------------------------------------+
//                             ^B = en   (en=0 parks the loop)

module ro_osc #(
    parameter STAGES      = 25,  // non-inverting delay stages
    parameter SIM_HALF_NS = 8.0  // behavioral half-period (SIM only)
) (
    input  wire en,
    output wire ro_out
);

`ifdef SIM

  reg ro_r = 1'b0;
  always begin
    #(SIM_HALF_NS);
    ro_r = en ? ~ro_r : 1'b0;
  end
  assign ro_out = ro_r;

`elsif FPGA

  // gowin LUT1 with INIT=2'b10 is a plain buffer (F = I0). instantiating
  // primitives (rather than assigns) keeps the synthesizer from collapsing
  // the loop even before syn_keep is considered.
  (* syn_keep = "true", keep = "true" *) wire [STAGES:0] n;

  assign n[0] = ~(n[STAGES] & en);  // maps to a LUT2, closes the loop

  genvar i;
  generate
    for (i = 0; i < STAGES; i = i + 1) begin : g_dly
      (* syn_keep = "true", keep = "true" *)
      LUT1 #(.INIT(2'b10)) u_buf (
          .F (n[i+1]),
          .I0(n[i])
      );
    end
  endgenerate

  assign ro_out = n[STAGES];

`else

  // sky130 tapeout path. cells are blackboxes to yosys and get linked
  // against the liberty at techmap, so the loop survives synthesis.
  // (* keep *) prevents sweep of the "unused" combinational cycle.
  wire [STAGES:0] n;

  (* keep *) sky130_fd_sc_hd__nand2_1 u_nand (
      .A(n[STAGES]),
      .B(en),
      .Y(n[0])
  );

  genvar i;
  generate
    for (i = 0; i < STAGES; i = i + 1) begin : g_dly
      (* keep *) sky130_fd_sc_hd__dlygate4sd3_1 u_dly (
          .A(n[i]),
          .X(n[i+1])
      );
    end
  endgenerate

  assign ro_out = n[STAGES];

`endif

endmodule
