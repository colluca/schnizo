// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// This module muxes result requests to forward one to a slot.
module schnizo_res_req_mux #(
  parameter int unsigned NofOperandIfs = 1,
  parameter type         operand_req_t = logic,
  parameter type         dest_mask_t   = logic
) (
  input  operand_req_t available_result_i,

  input  operand_req_t [NofOperandIfs-1:0] op_req_i,
  input  logic         [NofOperandIfs-1:0] op_req_valid_i,
  output logic         [NofOperandIfs-1:0] op_req_ready_o,

  output dest_mask_t res_req_o,
  output logic       res_req_valid_o,
  input  logic       res_req_ready_i
);

  // Only forward requests which the slot currently can handle, i.e. the requested result is
  // available. Without this filtering deadlocks can occur.
  for (genvar i = 0; i < NofOperandIfs; i++) begin : gen_req_filters
    logic gate;
    assign gate = op_req_i[i] == available_result_i;
    assign res_req_o[i] = gate && op_req_valid_i[i];
    assign op_req_ready_o[i] = gate && res_req_ready_i;
  end

  // The request is valid if at least one request from the filters is valid.
  assign res_req_valid_o = |res_req_o;

endmodule
