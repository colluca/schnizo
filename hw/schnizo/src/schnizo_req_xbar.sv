// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"

// Routes operand requests from the RSs to the result request ports of the RSs.
module schnizo_req_xbar #(
  parameter int unsigned  NofOperandReqs = 32'd0,
  parameter int unsigned  NofRs = 32'd0,
  parameter int unsigned  NofRss       [NofRs-1:0] = '{default: 32'd0},
  parameter int unsigned  NofResRspIfs [NofRs-1:0] = '{default: 32'd0},
  // TODO(colluca): derive from previous arrays
  parameter int unsigned  TotalNofRss = 32'd0,
  parameter int unsigned  TotalNofResRspIfs   = 32'd0,
  parameter type          operand_req_t  = logic,
  parameter type          res_req_t  = logic,
  parameter type          ext_res_req_t  = logic,
  parameter type          available_result_t = logic,
  parameter type          slot_id_t = logic,
  // TODO(colluca): rename dst and src everywhere
  parameter type          dest_mask_t    = logic
) (
  input  operand_req_t      [NofOperandReqs-1:0]    op_reqs_i,
  input  logic              [NofOperandReqs-1:0]    op_reqs_valid_i,
  output logic              [NofOperandReqs-1:0]    op_reqs_ready_o,
  input  available_result_t [TotalNofRss-1:0]       available_results_i,
  output ext_res_req_t      [TotalNofResRspIfs-1:0] res_reqs_o,
  output logic              [TotalNofResRspIfs-1:0] res_reqs_valid_o,
  input  logic              [TotalNofResRspIfs-1:0] res_reqs_ready_i
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
  function automatic int unsigned port_offset(input int unsigned n);
      int unsigned s;
      s = '0;
      for (int i = 0; i < n; i++) begin
        s += NofResRspIfs[i];
      end
      return s;
  endfunction

  // NofOperandReqs 1->NofRs demuxes
  res_req_t [NofOperandReqs-1:0][NofRs-1:0] demuxed_reqs;
  logic     [NofOperandReqs-1:0][NofRs-1:0] demuxed_reqs_valid, demuxed_reqs_ready;
  for (genvar req = 0; req < NofOperandReqs; req++) begin : gen_demux_stage
    stream_demux #(
      .N_OUP(NofRs)
    ) i_demux (
      .inp_valid_i(op_reqs_valid_i[req]),
      .inp_ready_o(op_reqs_ready_o[req]),
      .oup_sel_i  (op_reqs_i[req].producer),
      .oup_valid_o(demuxed_reqs_valid[req]),
      .oup_ready_i(demuxed_reqs_ready[req])
    );
    assign demuxed_reqs[req] = {NofRs{op_reqs_i[req].request}};
  end

  // Transpose
  res_req_t [NofRs-1:0][NofOperandReqs-1:0] transposed_reqs;
  logic     [NofRs-1:0][NofOperandReqs-1:0] transposed_reqs_valid, transposed_reqs_ready;
  for (genvar i = 0; i < NofOperandReqs; i++) begin : gen_transpose_i
    for (genvar j = 0; j < NofRs; j++) begin : gen_transpose_j
      assign transposed_reqs[j][i]       = demuxed_reqs[i][j];
      assign transposed_reqs_valid[j][i] = demuxed_reqs_valid[i][j];
      assign demuxed_reqs_ready[i][j]    = transposed_reqs_ready[j][i];
    end
  end

  // Generate filter, coalescer and arbiters for each RS
  for (genvar rs = 0; rs < NofRs; rs++) begin : gen_rs

    localparam int unsigned RssOffset = rss_offset(rs);
    localparam int unsigned PortOffset = port_offset(rs);
    localparam int unsigned LocalNofRss = NofRss[rs];
    localparam int unsigned LocalNofPorts = NofResRspIfs[rs];
    typedef logic [cf_math_pkg::idx_width(LocalNofRss)-1:0] local_slot_id_t;

    // Filter
    ext_res_req_t [NofOperandReqs-1:0] filtered_reqs;
    logic         [NofOperandReqs-1:0] filtered_reqs_valid, filtered_reqs_ready;
    for (genvar req = 0; req < NofOperandReqs; req++) begin : gen_filter
      res_req_t op_req;
      available_result_t addressed_result;
      assign op_req = transposed_reqs[rs][req];
      assign addressed_result = available_results_i[RssOffset + op_req.slot_id];

      logic pass;
      assign pass = addressed_result.valid && (addressed_result.iteration == op_req.requested_iter);
      assign filtered_reqs_valid[req]       = pass && transposed_reqs_valid[rs][req];
      assign transposed_reqs_ready[rs][req] = pass && filtered_reqs_ready[req];
      assign filtered_reqs[req].slot_id   = transposed_reqs[rs][req].slot_id;
      assign filtered_reqs[req].dest_mask = 1'b1 << req;
    end

    // Coalescing
    dest_mask_t [LocalNofRss-1:0] coalesced_reqs;
    logic       [LocalNofRss-1:0] coalesced_reqs_valid, coalesced_reqs_ready;
    always_comb begin
      coalesced_reqs       = '0;
      coalesced_reqs_valid = '0;
      filtered_reqs_ready  = '0;
      for (int unsigned rss = 0; rss < LocalNofRss; rss++) begin
        for (int unsigned req = 0; req < NofOperandReqs; req++) begin
          if (filtered_reqs[req].slot_id == rss) begin
            coalesced_reqs_valid[rss] |= filtered_reqs_valid[req];
            if (filtered_reqs_valid[req]) begin
              coalesced_reqs[rss] |= filtered_reqs[req].dest_mask;
            end
            filtered_reqs_ready[req]   = coalesced_reqs_ready[rss];
          end
        end
      end
    end
  
    // Selection
    dest_mask_t     [LocalNofPorts-1:0] selected_reqs;
    logic           [LocalNofPorts-1:0] selected_reqs_valid, selected_reqs_ready;
    local_slot_id_t [LocalNofPorts-1:0] selects;
    logic           [LocalNofPorts-1:0] port_assigned;
    // Priority encoder to select the first LocalNofPorts valid coalesced requests
    always_comb begin
      automatic int cnt = 0;
      selects       = '0;
      port_assigned = '0;
      for (int rss = 0; rss < LocalNofRss; rss++) begin
        if (coalesced_reqs_valid[rss]) begin
          selects[cnt]       = rss;
          port_assigned[cnt] = 1'b1;
          cnt++;
        end
        if (cnt >= LocalNofPorts) break;
      end
    end
    // Each port drives its own ready vector; OR-combine per slot to avoid multiple drivers.
    logic [LocalNofPorts-1:0][LocalNofRss-1:0] coalesced_reqs_ready_per_port;
    for (genvar rss = 0; rss < LocalNofRss; rss++) begin : gen_combine_coalesced_ready
      always_comb begin
        coalesced_reqs_ready[rss] = 1'b0;
        for (int port = 0; port < LocalNofPorts; port++) begin
          coalesced_reqs_ready[rss] |= coalesced_reqs_ready_per_port[port][rss];
        end
      end
    end
    // Mux the selected requests
    for (genvar port = 0; port < LocalNofPorts; port++) begin : gen_mux
      logic mux_valid_o;
      stream_mux #(
        .DATA_T(dest_mask_t),
        .N_INP(LocalNofRss)
      ) i_mux (
        .inp_data_i (coalesced_reqs),
        .inp_valid_i(coalesced_reqs_valid),
        .inp_ready_o(coalesced_reqs_ready_per_port[port]),
        .inp_sel_i  (selects[port]),
        .oup_data_o (selected_reqs[port]),
        .oup_valid_o(mux_valid_o),
        .oup_ready_i(selected_reqs_ready[port])
      );
      assign selected_reqs_valid[port]             = mux_valid_o && port_assigned[port];
      assign res_reqs_o[PortOffset+port].dest_mask = selected_reqs[port];
      assign res_reqs_o[PortOffset+port].slot_id   = selects[port];
      assign res_reqs_valid_o[PortOffset+port]     = selected_reqs_valid[port];
      assign selected_reqs_ready[port]             = res_reqs_ready_i[PortOffset+port];
    end

  end

endmodule
