// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"

// Fully connected stream crossbar but without output MUXing. This is performed inside the RS.
// Handshaking rules as defined by the `AMBA AXI` standard on default.
module schnizo_xbar_req #(
  /// Number of inputs into the crossbar (`> 0`).
  parameter int unsigned NumInp      = 32'd0,
  /// Number of outputs from the crossbar (`> 0`).
  parameter int unsigned NumOut      = 32'd0,
  /// Result request of the data ports. Must be overwritten with actual request type.
  parameter type         res_req_t   = logic,
  /// Adds a spill register stage at each output.
  parameter bit          OutSpillReg = 1'b0,
  /// Use strict AXI valid ready handshaking.
  /// To be protocol conform also the parameter `LockIn` has to be set.
  parameter int unsigned AxiVldRdy   = 1'b1,
  /// Lock in the arbitration decision of the `rr_arb_tree`.
  /// When this is set, valids have to be asserted until the corresponding transaction is indicated
  /// by ready.
  parameter int unsigned LockIn      = 1'b1,
  /// If `AxiVldReady` is 1, which bits of the payload to check for stability on valid inputs.
  /// In some cases, we may want to allow parts of the payload to change depending on the value of
  /// other parts (e.g. write data in read requests), requiring more nuanced external assertions.
  parameter res_req_t    AxiVldMask  = '1,
  /// Width of the output selection signal.
  localparam int unsigned SelWidth = (NumOut > 32'd1) ? unsigned'($clog2(NumOut)) : 32'd1,
  /// Signal type definition for selecting the output at the inputs.
  localparam type sel_oup_t = logic[SelWidth-1:0]
) (
  /// Clock, positive edge triggered.
  input  logic                    clk_i,
  /// Asynchronous reset, active low.
  input  logic                    rst_ni,
  /// Input data ports.
  /// Has to be stable as long as `valid_i` is asserted when parameter `AxiVldRdy` is set.
  input  res_req_t   [NumInp-1:0] data_i,
  /// Selection of the output port where the data should be routed.
  /// Has to be stable as long as `valid_i` is asserted and parameter `AxiVldRdy` is set.
  input  sel_oup_t   [NumInp-1:0] sel_i,
  /// Input is valid.
  input  logic       [NumInp-1:0] valid_i,
  /// Input is ready to accept data.
  output logic       [NumInp-1:0] ready_o,
  /// Output data ports. Valid if `valid_o = 1`
  output res_req_t   [NumOut-1:0][NumInp-1:0] res_req_o,
  /// Output is valid.
  output logic       [NumOut-1:0][NumInp-1:0] valid_o,
  /// Output can be accepted.
  input  logic       [NumOut-1:0][NumInp-1:0] ready_i
);

  logic     [NumInp-1:0][NumOut-1:0] inp_valid;
  logic     [NumInp-1:0][NumOut-1:0] inp_ready;

  res_req_t [NumOut-1:0][NumInp-1:0] out_data;
  logic     [NumOut-1:0][NumInp-1:0] out_valid;
  logic     [NumOut-1:0][NumInp-1:0] out_ready;

  // Generate the input selection
  for (genvar i = 0; unsigned'(i) < NumInp; i++) begin : gen_inps
    stream_demux #(
      .N_OUP (NumOut)
    ) i_stream_demux (
      .inp_valid_i(valid_i[i]),
      .inp_ready_o(ready_o[i]),
      .oup_sel_i  (sel_i[i]),
      .oup_valid_o(inp_valid[i]),
      .oup_ready_i(inp_ready[i])
    );

    // Do the switching cross of the signals.
    for (genvar j = 0; unsigned'(j) < NumOut; j++) begin : gen_cross
      // Propagate the data from this input to all outputs.
      assign out_data[j][i]  = data_i[i];
      // switch handshaking
      assign out_valid[j][i] = inp_valid[i][j];
      assign inp_ready[i][j] = out_ready[j][i];
    end
  end

  // Generate the output arbitration. There is no arbiter because it is handled inside the RS
  for (genvar j = 0; unsigned'(j) < NumOut; j++) begin : gen_outs
    // A cut of all xbar outputs would be way too expensive. Therefore we don't have a cut here.
    assign res_req_o[j] = out_data[j];
    assign valid_o[j]   = out_valid[j];
    assign out_ready[j] = ready_i[j];
  end

  // Assertions
  // Make sure that the handshake and payload is stable
`ifndef COMMON_CELLS_ASSERTS_OFF
  for (genvar i = 0; unsigned'(i) < NumInp; i++) begin : gen_sel_assertions
    `ASSERT(non_existing_output, valid_i[i] |-> sel_i[i] < NumOut, clk_i, !rst_ni,
            "Non-existing output is selected!")
  end

  if (AxiVldRdy) begin : gen_handshake_assertions
    for (genvar i = 0; unsigned'(i) < NumInp; i++) begin : gen_inp_assertions
      `ASSERT(input_data_unstable, valid_i[i] && !ready_o[i] |=> $stable(data_i[i] & AxiVldMask),
              clk_i, !rst_ni, $sformatf("data_i is unstable at input: %0d", i))
      `ASSERT(input_sel_unstable, valid_i[i] && !ready_o[i] |=> $stable(sel_i[i]), clk_i, !rst_ni,
              $sformatf("sel_i is unstable at input: %0d", i))
      `ASSERT(input_valid_taken, valid_i[i] && !ready_o[i] |=> valid_i[i], clk_i, !rst_ni,
              $sformatf("valid_i at input %0d has been taken away without a ready.", i))
    end
  end

  `ASSERT_INIT(numinp_0, NumInp > 32'd0, "NumInp has to be > 0!")
  `ASSERT_INIT(numout_0, NumOut > 32'd0, "NumOut has to be > 0!")
`endif // COMMON_CELLS_ASSERTS_OFF

endmodule
