// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// This module muxes result requests from the operand distribution network to the correct slot.
module schnizo_res_req_mux #(
  // How many slots can be accessed by the request
  parameter int unsigned NofOperandIfs = 1,
  parameter int unsigned NofSlots      = 1,
  parameter type         res_req_t     = logic,
  parameter type         dest_mask_t   = logic,
  parameter type         slot_id_t     = logic
) (
  input  logic clk_i,
  input  logic rst_i,

  input  slot_id_t [NofSlots-1:0] slot_ids_i,
  input  logic     [NofSlots-1:0] res_iters_i,

  input  res_req_t [NofOperandIfs-1:0] res_req_i,
  input  logic     [NofOperandIfs-1:0] res_req_valid_i,
  output logic     [NofOperandIfs-1:0] res_req_ready_o,

  output dest_mask_t [NofSlots-1:0] dest_mask_o,
  output logic       [NofSlots-1:0] dest_mask_valid_o,
  input  logic       [NofSlots-1:0] dest_mask_ready_i
);
  logic [NofOperandIfs-1:0][NofSlots-1:0] valids_from_filter;
  logic [NofOperandIfs-1:0][NofSlots-1:0] readies_to_filter;

  // Only forward requests which the slot currently can handle, i.e. the requested result is
  // available. Without this filtering deadlocks can occur.
  for (genvar op = 0; op < NofOperandIfs; op++) begin : gen_req_filter
    schnizo_res_req_filter #(
      .NofSlots (NofSlots),
      .slot_id_t(slot_id_t)
    ) i_res_req_filter (
      .clk_i,
      .rst_i,
      .res_iters_i(res_iters_i),
      .slot_ids_i  (slot_ids_i),
      .req_iter_i  (res_req_i[op].requested_iter),
      .req_slot_i  (res_req_i[op].slot_id),
      .req_valid_i (res_req_valid_i[op]),
      .req_ready_o (res_req_ready_o[op]),
      .reqs_valid_o(valids_from_filter[op]),
      .reqs_ready_i(readies_to_filter[op])
    );
  end

  // After filtering we don't need the actual request information anymore.
  // The operand interface index of the valids is sufficient to send back the response.
  // From these indeces we create the destination mask, signalling where to send the response to.
  for (genvar slot = 0; slot < NofSlots; slot++) begin : gen_dest_mask
    logic [NofOperandIfs-1:0] dest_mask;
    for (genvar op = 0; op < NofOperandIfs; op++) begin : gen_dest_mask_inner
      assign dest_mask[op] = valids_from_filter[op][slot];
      assign readies_to_filter[op][slot] = dest_mask_ready_i[slot];
    end

    assign dest_mask_o[slot] = dest_mask;
    // The destination mask is valid if at least one request from the filters is valid.
    assign dest_mask_valid_o[slot] = |dest_mask;
  end

endmodule
