// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// Handles result request responses and updates the slot consumer counters.
module schnova_rss_res_req_handling import schnizo_pkg::*; #(
  parameter type rs_slot_result_t = logic,
  parameter type operand_req_t    = logic,
  parameter type producer_id_t    = logic,
  parameter type dest_mask_t      = logic,
  parameter type res_rsp_t        = logic
) (
  input  logic clk_i,
  input  logic rst_i,

  // Control
  input  rs_slot_result_t slot_i,
  input  producer_id_t    producer_id_i,
  input  logic            retired_i,
  input  logic            restart_i,
  output rs_slot_result_t slot_o,

  // Result request
  input  dest_mask_t   dest_mask_i,
  input  logic         dest_mask_valid_i,
  output logic         dest_mask_ready_o,
  output operand_req_t available_result_o,

  // Result response
  output res_rsp_t res_rsp_o,
  output logic     res_rsp_valid_o,
  input  logic     res_rsp_ready_i
);

  /////////////////////////////////////////////////////
  // Result request handling and response generation //
  /////////////////////////////////////////////////////

  assign available_result_o.producer               = producer_id_i.rs_id;
  assign available_result_o.request.slot_id        = producer_id_i.slot_id;

  // Always answer requests using the "old" result (before result capture) as otherwise we
  // would create a loop. The loop comes from the connection back to the operand response
  // handling. The generated result response is sent back to the operand interface.
  assign res_rsp_o.dest_mask = dest_mask_i;
  assign res_rsp_o.operand   = slot_i.result.value;
  // We don't need to check the iteration here as it is already checked in the request crossbar.
  assign res_rsp_valid_o     = dest_mask_valid_i && slot_i.result.is_valid;
  assign dest_mask_ready_o   = res_rsp_ready_i;

  // We don't have to update the consumer counts, so we can just forward the slot
  assign slot_o = slot_i;

endmodule
