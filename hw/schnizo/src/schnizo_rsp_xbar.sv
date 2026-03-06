// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"

/// Fully connected crossbar for multi-output result broadcasting.
///
/// Handshaking rules as defined by the `AMBA AXI` standard on default.
module schnizo_rsp_xbar #(
  /// Number of inputs into the crossbar (`> 0`).
  parameter int unsigned NumInp      = 32'd0,
  /// Number of outputs from the crossbar (`> 0`).
  parameter int unsigned NumOut      = 32'd0,
  /// Data width of the stream. Can be overwritten by defining the type parameter `payload_t`.
  parameter int unsigned DataWidth   = 32'd1,
  /// Payload type of the data ports, only usage of parameter `DataWidth`.
  parameter type         payload_t   = logic [DataWidth-1:0],
  /// The mask which defines where to send the result to. This mask is generated depending on the
  /// currently valid requests. This way we can serve multiple request at once.
  parameter type         dest_mask_t = logic,
  /// Adds a spill register stage at each output.
  parameter bit          OutSpillReg = 1'b0,
  /// Width of the input index signal.
  localparam int unsigned IdxWidth = (NumInp > 32'd1) ? unsigned'($clog2(NumInp)) : 32'd1,
  /// Signal type definition indicating from which input the output came.
  localparam type idx_inp_t = logic[IdxWidth-1:0]
) (
  /// Clock, positive edge triggered.
  input  logic                    clk_i,
  /// Asynchronous reset, active low.
  input  logic                    rst_ni,
  /// Flush the state of the internal `rr_arb_tree` modules.
  /// If not used set to `0`.
  /// Flush should only be used if there are no active `valid_i`, otherwise it will
  /// not adhere to the AXI handshaking.
  input  logic                    flush_i,
  /// Provide an external state for the `rr_arb_tree` models.
  /// Will only do something if ExtPrio is `1` otherwise tie to `0`.
  input  idx_inp_t   [NumOut-1:0] rr_i,
  /// Input data ports.
  /// Has to be stable as long as `valid_i` is asserted when parameter `AxiVldRdy` is set.
  input  payload_t   [NumInp-1:0] data_i,
  /// Selection of the output port where the data should be routed.
  /// Has to be stable as long as `valid_i` is asserted and parameter `AxiVldRdy` is set.
  input  dest_mask_t [NumInp-1:0] sel_i,
  /// Input is valid.
  input  logic       [NumInp-1:0] valid_i,
  /// Input is ready to accept data.
  output logic       [NumInp-1:0] ready_o,
  /// Output data ports. Valid if `valid_o = 1`
  output payload_t   [NumOut-1:0] data_o,
  /// Index of the input port where data came from.
  output idx_inp_t   [NumOut-1:0] idx_o,
  /// Output is valid.
  output logic       [NumOut-1:0] valid_o,
  /// Output can be accepted.
  input  logic       [NumOut-1:0] ready_i
);
  typedef struct packed {
    payload_t data;
    idx_inp_t idx;
  } spill_data_t;

  logic     [NumInp-1:0][NumOut-1:0] inp_valid;
  logic     [NumInp-1:0][NumOut-1:0] inp_ready;

  payload_t [NumOut-1:0][NumInp-1:0] out_data;
  logic     [NumOut-1:0][NumInp-1:0] out_valid;
  logic     [NumOut-1:0][NumInp-1:0] out_ready;

  // Generate the input selection
  for (genvar i = 0; unsigned'(i) < NumInp; i++) begin : gen_inps
    // We send the result to all selected outputs. There is no synchronization!
    // DANGER: This assumes that each response is immediately accepted!
    //         (handshake must happen in the same cycle as the valid is asserted).
    assign inp_valid[i] = {NumOut{valid_i[i]}} & sel_i[i];
    // With the assumption above we can simply take one ready signal and send it back.
    assign ready_o[i]   = |(inp_ready[i] & sel_i[i]);


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
    spill_data_t arb;
    logic        arb_valid, arb_ready;

    // As there is anyway only 1 active request, there will also be only one response at a time.
    // We thus can simplify it to a static arbiter. In theory we could also | all valids and send
    // back the ready to the incoming response.
    // TODO(colluca): the described alternative would be like using a stream_mux
    rr_arb_tree #(
      .NumIn    (NumInp),
      .DataType (payload_t),
      .ExtPrio  (1),
      .AxiVldRdy(0),
      .LockIn   (0),
      .FairArb  (1'b0)
    ) i_rr_arb_tree (
      .clk_i,
      .rst_ni,
      .flush_i,
      .rr_i    ( '0           ),
      .req_i   ( out_valid[j] ),
      .gnt_o   ( out_ready[j] ),
      .data_i  ( out_data[j]  ),
      .req_o   ( arb_valid    ),
      .gnt_i   ( arb_ready    ),
      .data_o  ( arb.data     ),
      .idx_o   ( arb.idx      )
    );

    spill_data_t spill;

    spill_register #(
      .T      ( spill_data_t ),
      .Bypass ( !OutSpillReg )
    ) i_spill_register (
      .clk_i,
      .rst_ni,
      .valid_i ( arb_valid  ),
      .ready_o ( arb_ready  ),
      .data_i  ( arb        ),
      .valid_o ( valid_o[j] ),
      .ready_i ( ready_i[j] ),
      .data_o  ( spill      )
    );
    // Assign the outputs (deaggregate the data).
    always_comb begin
      data_o[j] = spill.data;
      idx_o[j]  = spill.idx;
    end
  end

  // Assertions
  // Make sure that the handshake and payload is stable
`ifndef COMMON_CELLS_ASSERTS_OFF
  `ASSERT_INIT(numinp_0, NumInp > 32'd0, "NumInp has to be > 0!")
  `ASSERT_INIT(numout_0, NumOut > 32'd0, "NumOut has to be > 0!")
`endif // COMMON_CELLS_ASSERTS_OFF

endmodule
