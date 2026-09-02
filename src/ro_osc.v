// SPDX-FileCopyrightText: 2026 lena conde araujo
// SPDX-License-Identifier: Apache-2.0

`default_nettype none
`ifdef SIM
`timescale 1ns / 1ps
`endif

// supply-sensing ring oscillator with enable gate. three builds:
//   SIM    - behavioral fixed-period model; a real loop won't oscillate
//            in rtl sim, and the tests only exercise the counters.
//   FPGA   - gowin LUT1 buffer chain (LUT delay tracks VDD too).
//   (none) - sky130 tapeout: nand2 is the loop's one inversion and its
//            switch; dlygate4sd3 cells keep it out of the GHz.
//
// loop:  nand2 -> dly[0] -> ... -> dly[STAGES-1] -+
//          ^B = en (0 parks it)                   |
//          ^A <------------------------------------+

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

  // LUT1 INIT=2'b10 is a plain buffer; instantiating primitives rather
  // than assigns keeps the tool from collapsing the loop.
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

  // cells are blackboxes to yosys until techmap, so the loop survives
  // synthesis; (* keep *) stops the sweep of an "unused" cycle.
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
