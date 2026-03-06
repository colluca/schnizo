// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"

// Routes operand requests from the RSs to the result request ports of the RSs.
module schnizo_req_xbar #(
  parameter int unsigned  NofOperandReqs = 32'd0,
  parameter int unsigned  NofResRspIfs   = 32'd0,
  parameter type          operand_req_t  = logic,
  // TODO(colluca): rename dst and src everywhere
  parameter type          dest_mask_t    = logic
) (
  input  operand_req_t [NofOperandReqs-1:0] op_reqs_i,
  input  logic         [NofOperandReqs-1:0] op_reqs_valid_i,
  output logic         [NofOperandReqs-1:0] op_reqs_ready_o,
  input  operand_req_t [NofResRspIfs-1:0]   available_results_i,
  // TODO(colluca): rename data_o
  output dest_mask_t   [NofResRspIfs-1:0]   res_reqs_o,
  output logic         [NofResRspIfs-1:0]   res_reqs_valid_o,
  input  logic         [NofResRspIfs-1:0]   res_reqs_ready_i
);

  logic [NofResRspIfs-1:0][NofOperandReqs-1:0] readies;
  logic [NofOperandReqs-1:0][NofResRspIfs-1:0] transposed_readies;

  for (genvar i = 0; i < NofOperandReqs; i++) begin
    for (genvar j = 0; j < NofResRspIfs; j++) begin
      assign transposed_readies[i][j] = readies[j][i];
    end

    // TODO(colluca): we could add an assertion that transposed_readies[i] is
    // always one hot.
    assign op_reqs_ready_o[i] = |transposed_readies[i];
  end

  // At every result request port, mux all operand requests
  for (genvar i = 0; i < NofResRspIfs; i++) begin : gen_muxes
    schnizo_res_req_mux #(
      .NofOperandIfs(NofOperandReqs),
      .operand_req_t(operand_req_t),
      .dest_mask_t  (dest_mask_t)
    ) i_res_req_mux (
      .available_result_i(available_results_i[i]),
      .op_req_i          (op_reqs_i),
      .op_req_valid_i    (op_reqs_valid_i),
      .op_req_ready_o    (readies[i]),
      .res_req_o         (res_reqs_o[i]),
      .res_req_valid_o   (res_reqs_valid_o[i]),
      .res_req_ready_i   (res_reqs_ready_i[i])
    );
  end

  ////////////////
  // Assertions //
  ////////////////

  `ASSERT_INIT(NofOperandReqs_0, NofOperandReqs > 32'd0, "NofOperandReqs has to be > 0!")
  `ASSERT_INIT(NofResRspIfs_0, NofResRspIfs > 32'd0, "NofResRspIfs has to be > 0!")

endmodule
