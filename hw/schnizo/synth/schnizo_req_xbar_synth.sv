// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnizo_req_xbar_synth #(
  parameter int unsigned  NofOperandReqs = 32'd0,
  parameter int unsigned  NofResRspIfs   = 32'd0,
  localparam type         dest_mask_t    = logic [NofOperandReqs-1:0],
  localparam type         operand_req_t  = struct packed {
    logic [cf_math_pkg::idx_width(NofResRspIfs)-1:0] rss_idx;
    logic iteration_idx;
  }
) (
  input  logic                              clk_i,  // Needed only so synthesis doesn't fail
  input  logic                              rst_ni,  // Needed only so synthesis doesn't fail
  input  operand_req_t [NofOperandReqs-1:0] op_reqs_i,
  input  logic         [NofOperandReqs-1:0] op_reqs_valid_i,
  output logic         [NofOperandReqs-1:0] op_reqs_ready_o,
  input  logic         [NofResRspIfs-1:0]   result_iterations_i,
  output dest_mask_t   [NofResRspIfs-1:0]   res_reqs_o,
  output logic         [NofResRspIfs-1:0]   res_reqs_valid_o,
  input  logic         [NofResRspIfs-1:0]   res_reqs_ready_i
);

  operand_req_t [NofResRspIfs-1:0] available_results;

  for (genvar i = 0; i < NofResRspIfs; i++) begin
    assign available_results[i].rss_idx = i;
    assign available_results[i].iteration_idx = result_iterations_i[i];
  end

  schnizo_req_xbar #(
    .NofOperandReqs(NofOperandReqs),
    .NofResRspIfs(NofResRspIfs),
    .operand_req_t(operand_req_t),
    .dest_mask_t(dest_mask_t)
  ) i_req_xbar (
    .op_reqs_i,
    .op_reqs_valid_i,
    .op_reqs_ready_o,
    .available_results_i(available_results),
    .res_reqs_o,
    .res_reqs_valid_o,
    .res_reqs_ready_i
  );

endmodule