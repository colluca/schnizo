// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Handles result request responses and updates the slot consumer counters.
module schnizo_rss_res_req_handling import schnizo_pkg::*; #(
  parameter type rs_slot_t   = logic,
  parameter type dest_mask_t = logic,
  parameter type res_rsp_t   = logic
) (
  input  logic clk_i,
  input  logic rst_i,

  // Registered slot state — used for result response generation
  input  rs_slot_t   slot_q_i,
  // Post-issue slot state — updated with consumer counts
  input  rs_slot_t   slot_i,
  input  logic       retired_i,
  input  loop_state_e loop_state_i,
  input  logic       restart_i,

  // Result request interface - incoming
  input  dest_mask_t dest_mask_i,
  input  logic       dest_mask_valid_i,
  output logic       dest_mask_ready_o,

  // Result response interface - outgoing
  output res_rsp_t   res_rsp_o,
  output logic       res_rsp_valid_o,
  input  logic       res_rsp_ready_i,

  // Result iteration output
  output logic       res_iter_o,

  // Updated slot state
  output rs_slot_t   slot_o
);

  /////////////////////////////////////////////////////
  // Result request handling and response generation //
  /////////////////////////////////////////////////////

  // Always answer requests using the "old" result (before result capture) as otherwise we
  // would create a loop. The loop comes from the connection back to the operand response
  // handling. The generated result response is sent back to the operand interface.
  assign res_rsp_o.dest_mask = dest_mask_i;
  assign res_rsp_o.operand   = slot_q_i.result.value;
  // We don't need to check the iteration here as it is already checked in the request crossbar.
  assign res_rsp_valid_o     = dest_mask_valid_i && slot_q_i.result.is_valid;
  assign dest_mask_ready_o   = res_rsp_ready_i;

  // Count the bits in the destination mask to count how many times the result
  // is being consumed
  logic [cf_math_pkg::idx_width($bits(dest_mask_t)+1)-1:0] num_current_consumers;
  popcount #(
    .INPUT_WIDTH($bits(dest_mask_t))
  ) i_consumer_popcount (
    .data_i(dest_mask_i),
    .popcount_o(num_current_consumers)
  );

  // The current result iteration state is directly passed to the output
  assign res_iter_o = slot_q_i.result.iteration;

  //////////////////////////////////////////////////
  // Update slot after result response generation //
  //////////////////////////////////////////////////

  always_comb begin
    slot_o = slot_i;
    // When we served a result request, update consumer counter
    if (res_rsp_valid_o && res_rsp_ready_i) begin
      slot_o.consumed_by = slot_o.consumed_by + num_current_consumers;
      // During LCP there may be only one request at a time. We still count all requests.
      if (enable_capture_consumers_i) begin
        slot_o.consumer_count = slot_o.consumer_count + num_current_consumers;
      end
    end
  end

endmodule
