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
  input  loop_state_e     loop_state_i,
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

  //////////////////
  // State update //
  //////////////////

  logic enable_capture_consumers_q, enable_capture_consumers_d;
  `FFAR(enable_capture_consumers_q, enable_capture_consumers_d, 1'b0, clk_i, rst_i);

  // We have to start capturing the consumer count after we got the result from
  // LCP1. We stop capturing the consumer count once we got the result from LCP2.
  // TODO(colluca): effectively the info we are tracking here is the loop state, at the result
  // side rather than the issue side. We have to capture consumers (increment consumer count)
  // only while we have a result produced in LCP1.
  always_comb begin
    enable_capture_consumers_d = enable_capture_consumers_q;

    // set after LCP1 result
    if (!enable_capture_consumers_q &&
        retired_i &&
        (loop_state_i == LoopLcp1)) begin
      enable_capture_consumers_d = 1'b1;
    end

    // clear after LCP2 result
    if (enable_capture_consumers_q && retired_i) begin
      enable_capture_consumers_d = 1'b0;
    end

    // Initialization of the slot has highest prio
    if (restart_i) begin
      enable_capture_consumers_d = 1'b0;
    end
  end

  /////////////////////////////////////////////////////
  // Result request handling and response generation //
  /////////////////////////////////////////////////////

  assign available_result_o.producer               = producer_id_i.rs_id;
  assign available_result_o.request.requested_iter = slot_i.result.iteration;
  assign available_result_o.request.slot_id        = producer_id_i.slot_id;

  // Always answer requests using the "old" result (before result capture) as otherwise we
  // would create a loop. The loop comes from the connection back to the operand response
  // handling. The generated result response is sent back to the operand interface.
  assign res_rsp_o.dest_mask = dest_mask_i;
  assign res_rsp_o.operand   = slot_i.result.value;
  // We don't need to check the iteration here as it is already checked in the request crossbar.
  assign res_rsp_valid_o     = dest_mask_valid_i && slot_i.result.is_valid;
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

  //////////////////////////////////////////////////
  // Update slot after result response generation //
  //////////////////////////////////////////////////

  always_comb begin
    slot_o = slot_i;
    // When we served a result request, update consumer counter
    if (res_rsp_valid_o && res_rsp_ready_i) begin
      slot_o.consumed_by = slot_o.consumed_by + num_current_consumers;
      // During LCP there may be only one request at at time.. We still count all requests.
      if (enable_capture_consumers_q) begin
        slot_o.consumer_count = slot_o.consumer_count + num_current_consumers;
      end
    end
  end

endmodule
