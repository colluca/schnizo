// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: Fully connected stream crossbar with selective request masking and multi output
//              handling. The input data is a result request and the output is a mask for the
//              response crossbar.

`include "common_cells/assertions.svh"

/// Handshaking rules as defined by the `AMBA AXI` standard on default.
module schnizo_xbar_req #(
  /// Number of inputs into the crossbar (`> 0`).
  parameter int unsigned NumInp      = 32'd0,
  /// Number of outputs from the crossbar (`> 0`).
  parameter int unsigned NumOut      = 32'd0,
  /// Result request of the data ports. Must be overwritten with actual request type.
  parameter type         res_req_t   = logic,
  /// The mask which defines where to send the result to. This mask is generated depending on the
  /// currently valid requests. This way we can serve multiple request at once.
  parameter type         dest_mask_t = logic,
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
  /// Derived parameter, do **not** overwrite!
  ///
  /// Width of the output selection signal.
  parameter int unsigned SelWidth = (NumOut > 32'd1) ? unsigned'($clog2(NumOut)) : 32'd1,
  /// Derived parameter, do **not** overwrite!
  ///
  /// Signal type definition for selecting the output at the inputs.
  parameter type sel_oup_t = logic[SelWidth-1:0]
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
  /// Current result iteration flag value. Requests to an output must match the iteration flag.
  input  logic       [NumOut-1:0] res_iter_i,
  /// Output data ports. Valid if `valid_o = 1`
  output dest_mask_t [NumOut-1:0] dest_mask_o,
  /// Output is valid.
  output logic       [NumOut-1:0] valid_o,
  /// Output can be accepted.
  input  logic       [NumOut-1:0] ready_i
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

  // Generate the output arbitration.
  for (genvar j = 0; unsigned'(j) < NumOut; j++) begin : gen_outs
    // Mask out all requests which cannot be served currently.
    // A request can only be served if the current result iteration matches the
    // requested iteration.
    res_req_t [NumInp-1:0] masked_out;
    logic     [NumInp-1:0] masked_out_valid;
    logic     [NumInp-1:0] masked_out_ready;

    assign masked_out = out_data[j];

    for (genvar i = 0; unsigned'(i) < NumInp; i++) begin : gen_out_mask
      assign masked_out_valid[i] = (res_iter_i[j] == masked_out[i].requested_iter) &&
                                   out_valid[j][i];
    end
    assign out_ready[j] = masked_out_ready;

    // The output can accept multiple requests at once. We merge all requests into a bit mask which
    // specifies to which operand we should send the result.
    // In the case that the request and response crossbar is symmetric this mask corresponds to the
    // valid bits of the requests. The handshaking is combined to a single signal.
    dest_mask_t dest_mask;
    logic dest_mask_valid;
    logic dest_mask_ready;

    assign dest_mask        = masked_out_valid;
    assign dest_mask_valid  = |masked_out_valid;
    assign masked_out_ready = {NumInp{dest_mask_ready}} & masked_out_valid;

    spill_register #(
      .T     (dest_mask_t),
      .Bypass(!OutSpillReg)
    ) i_spill_register (
      .clk_i,
      .rst_ni,
      .valid_i(dest_mask_valid),
      .ready_o(dest_mask_ready),
      .data_i (dest_mask),
      .valid_o(valid_o[j]),
      .ready_i(ready_i[j]),
      .data_o (dest_mask_o[j])
    );
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
    for (genvar i = 0; unsigned'(i) < NumOut; i++) begin : gen_out_assertions
      `ASSERT(output_data_unstable, valid_o[i] && !ready_i[i] |=>
              $stable(dest_mask_o[i] & AxiVldMask), clk_i, !rst_ni,
              $sformatf("dest_mask_o is unstable at output: %0d Check that ", i,
                        "parameter LockIn is set."))
      `ASSERT(output_valid_taken, valid_o[i] && !ready_i[i] |=> valid_o[i], clk_i, !rst_ni,
              $sformatf("valid_o at output %0d has been taken away without a ready.", i))
    end
  end

  `ASSERT_INIT(numinp_0, NumInp > 32'd0, "NumInp has to be > 0!")
  `ASSERT_INIT(numout_0, NumOut > 32'd0, "NumOut has to be > 0!")
  `endif
endmodule
