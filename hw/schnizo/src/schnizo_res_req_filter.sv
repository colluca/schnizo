// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"

// This filtering module only forwards requests which a slot can handle with its current result.
module schnizo_res_req_filter #(
  // How many slots can be accessed by the request
  parameter int unsigned NofSlots  = 1,
  parameter type         slot_id_t = logic
) (
  input  logic clk_i,
  input  logic rst_i,

  input  logic     [NofSlots-1:0] res_iters_i,
  input  slot_id_t [NofSlots-1:0] slot_ids_i,

  input  logic     req_iter_i,
  input  slot_id_t req_slot_i,
  input  logic     req_valid_i,
  output logic     req_ready_o,

  output logic     [NofSlots-1:0] reqs_valid_o,
  input  logic     [NofSlots-1:0] reqs_ready_i
);
  logic [NofSlots-1:0] req_ready;

  // Forwarding logic:
  // - Only forward the valid to the slot we actually want
  // AND
  // - Only if the request matches the current result iteration of the slot
  //   (otherwise we could deadlock).
  for (genvar slot = 0; unsigned'(slot) < NofSlots; slot++) begin : gen_filter
    assign reqs_valid_o[slot] = (slot_ids_i[slot] == req_slot_i) &&
                                (req_iter_i == res_iters_i[slot]) &&
                                req_valid_i;

    // Signal ready if we get a ready but only if we actually placed a request.
    assign req_ready[slot] = reqs_valid_o[slot] && reqs_ready_i[slot];
  end

  // Instead of comparing the slot IDs we could also use a regular MUX. But what has the smaller
  // timing overhead?

  // As there can only be one valid request to the slots, we can simply OR all readies from the
  // slots. These readies must be guarded with its corresponding valid signal.
  assign req_ready_o = |req_ready;

  // There may be only served one request at a time.
  `ASSERT(onlyOneReady, (|reqs_valid_o) |-> $onehot0(req_ready), clk_i, rst_i,
    "More than one ready asserted at the same time");
endmodule
