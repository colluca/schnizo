// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"

/// Fully connected crossbar for multi-output result broadcasting.
///
/// Handshaking rules as defined by the `AMBA AXI` standard on default.
module schnizo_rsp_xbar #(
  parameter int unsigned  NofRs                   = 32'd0,
  parameter int unsigned  NofRss      [NofRs-1:0] = '{default: 32'd0},
  parameter int unsigned  NofRspPorts [NofRs-1:0] = '{default: 32'd0},
  // TODO(colluca): can this be derived from NofRspPorts? Otherwise add an assertion
  parameter int unsigned  TotalNofRspPorts        = 32'd0,
  // TODO(colluca): can this be derived from NofRss? Otherwise add an assertion
  parameter int unsigned  NumInp                  = 32'd0,
  parameter int unsigned  NumOut                  = 32'd0,
  parameter type          payload_t               = logic,
  /// The mask which defines where to send the result to. This mask is generated depending on the
  /// currently valid requests. This way we can serve multiple request at once.
  localparam type         dest_mask_t             = logic [NumOut-1:0]
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
  // TODO(colluca): create an abstract function that can be reused for both of these
  function automatic int unsigned rss_offset(input int unsigned n);
      int unsigned s;
      s = '0;
      for (int i = 0; i < n; i++) begin
          s += NofRss[i];
      end
      return s;
  endfunction
  function automatic int unsigned rsp_offset(input int unsigned n);
      int unsigned s;
      s = '0;
      for (int i = 0; i < n; i++) begin
        s += NofRspPorts[i];
      end
      return s;
  endfunction

  typedef struct packed {
    payload_t data;
    dest_mask_t sel;
  } data_and_sel_t;

  data_and_sel_t [TotalNofRspPorts-1:0] mux1_data;
  logic          [TotalNofRspPorts-1:0] mux1_valid;
  logic          [TotalNofRspPorts-1:0] mux1_ready;

  payload_t [TotalNofRspPorts-1:0][NumOut-1:0] demux_data;
  logic     [TotalNofRspPorts-1:0][NumOut-1:0] demux_valid;
  logic     [TotalNofRspPorts-1:0][NumOut-1:0] demux_ready;

  payload_t [NumOut-1:0][TotalNofRspPorts-1:0] mux2_data;
  logic     [NumOut-1:0][TotalNofRspPorts-1:0] mux2_valid;
  logic     [NumOut-1:0][TotalNofRspPorts-1:0] mux2_ready;

  // Generate the first stage of muxes (NofRss -> NofRspPorts)
  for (genvar i = 0; i < NofRs; i++) begin : gen_rs_muxes
    if (NofRss[i] > 0) begin : gen_rs_mux

      localparam int unsigned RssIdxWidth = cf_math_pkg::idx_width(NofRss[i]);
      localparam int unsigned RssOffset = rss_offset(i);
      localparam int unsigned RspOffset = rsp_offset(i);

      // Get signals from this RS
      logic       [NofRss[i]-1:0] rs_valid;
      logic       [NofRss[i]-1:0] rs_ready;
      payload_t   [NofRss[i]-1:0] rs_data;
      dest_mask_t [NofRss[i]-1:0] rs_sel;
      assign rs_valid = valid_i[RssOffset+:NofRss[i]];
      assign rs_data = data_i[RssOffset+:NofRss[i]];
      assign rs_sel = sel_i[RssOffset+:NofRss[i]];
      assign ready_o[RssOffset+:NofRss[i]] = rs_ready;

      // Priority encoder to find the first NofRspPorts valid responses
      // TODO(colluca): technically we wouldn't need this, if we would just forward the
      // indices of the arbitrated result requests
      logic [NofRspPorts[i]-1:0][RssIdxWidth-1:0] mux1_selects;
      always_comb begin
        automatic int cnt = 0;
        mux1_selects = '0;
        for (int j = 0; j < NofRss[i]; j++) begin
          if (rs_valid[j]) begin
            mux1_selects[cnt] = j;
            cnt++;
          end
          if (cnt >= NofRspPorts[i]) break;
        end
      end

      // Pack data and select together to pass them through the mux
      data_and_sel_t [NofRss[i]-1:0] rs_data_and_sel;
      for (genvar j = 0; j < NofRss[i]; j++) begin : gen_data_and_sel_pack
        assign rs_data_and_sel[j].data = rs_data[j];
        assign rs_data_and_sel[j].sel = rs_sel[j];
      end

      // Each result port may grant a result request. To avoid multiple drivers
      // on the ready signals, we must explicitly OR-combine them.
      logic [NofRspPorts[i]-1:0][NofRss[i]-1:0] rs_ready_per_port;
      logic [NofRss[i]-1:0][NofRspPorts[i]-1:0] rs_ready_per_port_transposed;
      for (genvar rss = 0; rss < NofRss[i]; rss++) begin : gen_combine_port_readies
        for (genvar port = 0; port < NofRspPorts[i]; port++) begin : gen_iter_ports
          assign rs_ready_per_port_transposed[rss][port] = rs_ready_per_port[port][rss];
        end
        assign rs_ready[rss] = |rs_ready_per_port_transposed[rss];
      end

      // Generate one mux for each port
      for (genvar j = 0; j < NofRspPorts[i]; j++) begin : gen_mux
        // DANGER! Output data may change on the interface before a handshake,
        // e.g. if a higher priority valid appears causing the select to change.
        // TODO(colluca): is this safe?
        stream_mux #(
          .DATA_T(data_and_sel_t),
          .N_INP(NofRss[i])
        ) i_rsp_mux (
          .inp_data_i(rs_data_and_sel),
          .inp_valid_i(rs_valid),
          .inp_ready_o(rs_ready_per_port[j]),
          .inp_sel_i(mux1_selects[j]),
          .oup_data_o(mux1_data[RspOffset+j]),
          .oup_valid_o(mux1_valid[RspOffset+j]),
          .oup_ready_i(mux1_ready[RspOffset+j])
        );
      end
    end
  end

  // Generate the input demuxes
  for (genvar i = 0; i < TotalNofRspPorts; i++) begin : gen_demuxes
    // We send the result to all selected outputs. There is no synchronization!
    // DANGER: This assumes that each response is immediately accepted!
    //         (handshake must happen in the same cycle as the valid is asserted).
    assign demux_valid[i] = {NumOut{mux1_valid[i]}} & mux1_data[i].sel;
    // With the assumption above we can simply take one ready signal and send it back.
    assign mux1_ready[i] = |(demux_ready[i] & mux1_data[i].sel);
    // Propagate the data from this input to all outputs.
    assign demux_data[i]  = {NumOut{mux1_data[i].data}};
  end

  // Connections between demuxes and muxes
  for (genvar i = 0; i < TotalNofRspPorts; i++) begin : gen_connection_demuxes
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
      .NumIn    (TotalNofRspPorts),
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
