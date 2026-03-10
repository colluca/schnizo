// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"

/// Fully connected crossbar for multi-output result broadcasting.
///
/// Handshaking rules as defined by the `AMBA AXI` standard on default.
module schnizo_rsp_xbar #(
  parameter int unsigned  NofRs              = 32'd0,
  parameter int unsigned  NofRss [NofRs-1:0] = '{default: 32'd0},
  // TODO(colluca): can this be derived from the previous two? Otherwise add an assertion
  parameter int unsigned  NumInp             = 32'd0,
  parameter int unsigned  NumOut             = 32'd0,
  parameter type          payload_t          = logic,
  /// The mask which defines where to send the result to. This mask is generated depending on the
  /// currently valid requests. This way we can serve multiple request at once.
  localparam type         dest_mask_t        = logic [NumOut-1:0]
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  payload_t   [NumInp-1:0] data_i,
  input  dest_mask_t [NumInp-1:0] sel_i,
  input  logic       [NumInp-1:0] valid_i,
  output logic       [NumInp-1:0] ready_o,
  output payload_t   [NumOut-1:0] data_o,
  output logic       [NumOut-1:0] valid_o,
  input  logic       [NumOut-1:0] ready_i
);

  /// Sum first n elements of array
  function automatic int unsigned rss_offset(input int unsigned n);
      int unsigned s;
      s = '0;
      for (int i = 0; i < n; i++) begin
          s += NofRss[i];
      end
      return s;
  endfunction

  payload_t   [NofRs-1:0] mux1_data;
  dest_mask_t [NofRs-1:0] mux1_sel;
  logic       [NofRs-1:0] mux1_valid;
  logic       [NofRs-1:0] mux1_ready;

  payload_t [NofRs-1:0][NumOut-1:0] demux_data;
  logic     [NofRs-1:0][NumOut-1:0] demux_valid;
  logic     [NofRs-1:0][NumOut-1:0] demux_ready;

  payload_t [NumOut-1:0][NofRs-1:0] mux2_data;
  logic     [NumOut-1:0][NofRs-1:0] mux2_valid;
  logic     [NumOut-1:0][NofRs-1:0] mux2_ready;

  typedef struct packed {
    payload_t data;
    dest_mask_t sel;
  } data_and_sel_t;

  // Generate the first stage of muxes (NofRss -> 1)
  for (genvar i = 0; i < NofRs; i++) begin : gen_muxes_1

    localparam int unsigned RssOffset = rss_offset(i);

    payload_t [NofRss[i]-1:0] data;
    dest_mask_t [NofRss[i]-1:0] sel;
    data_and_sel_t [NofRss[i]-1:0] data_and_sel;

    // Pack data and select together
    always_comb begin
      data = data_i[RssOffset+:NofRss[i]];
      sel = sel_i[RssOffset+:NofRss[i]];  
      for (int j = 0; j < NofRss[i]; j++) begin
        data_and_sel[j].data = data[j];
        data_and_sel[j].sel = sel[j];
      end
    end

    rr_arb_tree #(
      .NumIn    (NofRss[i]),
      .DataType (data_and_sel_t),
      .ExtPrio  (1),
      .AxiVldRdy(0),
      .LockIn   (0),
      .FairArb  (1'b0)
    ) i_rr_arb_tree (
      .clk_i,
      .rst_ni,
      .flush_i('0),
      .rr_i   ('0),
      .req_i  (valid_i[RssOffset+:NofRss[i]]),
      .gnt_o  (ready_o[RssOffset+:NofRss[i]]),
      .data_i (data_and_sel),
      .req_o  (mux1_valid[i]),
      .gnt_i  (mux1_ready[i]),
      .data_o ({mux1_data[i], mux1_sel[i]}),
      .idx_o  ()
    );
  end

  // Generate the input demuxes
  for (genvar i = 0; i < NofRs; i++) begin : gen_demuxes
    // We send the result to all selected outputs. There is no synchronization!
    // DANGER: This assumes that each response is immediately accepted!
    //         (handshake must happen in the same cycle as the valid is asserted).
    assign demux_valid[i] = {NumOut{mux1_valid[i]}} & mux1_sel[i];
    // With the assumption above we can simply take one ready signal and send it back.
    assign mux1_ready[i] = |(demux_ready[i] & mux1_sel[i]);
    // Propagate the data from this input to all outputs.
    assign demux_data[i]  = {NumOut{mux1_data[i]}};
  end

  // Connections between demuxes and muxes
  for (genvar i = 0; i < NofRs; i++) begin : gen_connection_demuxes
    for (genvar j = 0; j < NumOut; j++) begin : gen_connection_muxes
      assign mux2_data[j][i] = demux_data[i][j];
      assign mux2_valid[j][i] = demux_valid[i][j];
      assign demux_ready[i][j] = mux2_ready[j][i];
    end
  end

  // Generate the output muxes
  for (genvar j = 0; j < NumOut; j++) begin : gen_muxes_2
    // As there is anyway only 1 active request, there will also be only one response at a time.
    // We thus can simplify it to a static arbiter. In theory we could also | all valids and send
    // back the ready to the incoming response.
    rr_arb_tree #(
      .NumIn    (NofRs),
      .DataType (payload_t),
      .ExtPrio  (1),
      .AxiVldRdy(0),
      .LockIn   (0),
      .FairArb  (1'b0)
    ) i_rr_arb_tree (
      .clk_i,
      .rst_ni,
      .flush_i('0),
      .rr_i   ('0),
      .req_i  (mux2_valid[j]),
      .gnt_o  (mux2_ready[j]),
      .data_i (mux2_data[j]),
      .req_o  (valid_o[j]),
      .gnt_i  (ready_i[j]),
      .data_o (data_o[j]),
      .idx_o  ()
    );
  end

  // Assertions
  `ASSERT_INIT(numinp_0, NumInp > 32'd0, "NumInp has to be > 0!")
  `ASSERT_INIT(numout_0, NumOut > 32'd0, "NumOut has to be > 0!")

endmodule
