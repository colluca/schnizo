// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"

// Captures FU results into the slot, handles RF writeback, and updates the slot accordingly.
module schnizo_rss_result_capture import schnizo_pkg::*; #(
  parameter type rs_slot_result_t = logic,
  parameter type result_t         = logic,
  parameter type result_tag_t     = logic,
  parameter type disp_req_t       = logic
) (
  // Control
  input  rs_slot_result_t slot_i,
  input  logic            issue_hs_i,
  input  result_t         result_i,
  input  logic            result_valid_i,
  input  loop_state_e     loop_state_i,
  input  logic            is_last_result_iter_i,
  input  disp_req_t       disp_req_i,
  output logic            result_ready_o,
  output logic            retired_o,
  output logic            retired_rs_o,
  output rs_slot_result_t slot_o,

  // Writeback
  output result_tag_t rf_wb_tag_o,
  output logic        rf_do_writeback_o
);

  ////////////////////
  // Result capture //
  ////////////////////

  // Capture the result:
  // - Always if the current result is invalid
  // - If the current result is valid, result must have been consumed by all consumers

  // The result is consumed when all consumers read the result once
  logic result_consumed;
  assign result_consumed = (slot_i.consumed_by == slot_i.consumer_count) &&
                           (slot_i.consumer_count != '0);

  // The ready may not be dependent on the valid. Otherwise, because of the RF/RSS writeback
  // synchronization logic, we would have a combinational loop.
  assign result_ready_o = result_consumed || !slot_i.result.is_valid || slot_i.consumer_count == '0;

  // We captured a new result when the stream fork signals the handshake to the FU.
  // This includes both cases (only RSS as well as RSS and RF).
  // A store instruction has no result. Thus we capture a dummy result at the same time
  // we issue the store instruction.
  assign retired_o = slot_i.has_dest ? issue_hs_i : (result_valid_i && result_ready_o);

  // Retired signal back to RS to step the result pointer.
  // For all instructions except stores, this retired signal is the same as used inside this RSS.
  // I.e., it is asserted in the cycle we retire the result / handshake it.
  // For stores this is different as stores have no result and thus retire immediately.
  // However, we must signal the retirement "in order" to the result pointer.
  // As loads and stores can be mixed, we could miss the retired signal for a store as it is only
  // asserted once in the cycle we issue it. But in this cycle the RS result pointer could be set
  // to an ongoing load. Thus we signal the retired signal always and as soon as the RS result
  // pointer steps to the store, it immediately "retires" the instruction.
  // TODO(colluca): does the RS really need a pointer? Or is a counter sufficient? In the latter
  // case we wouldn't need this differentiation and the RS would just set `retiring` to
  // |rss_retiring instead of rss_retiring[result_idx]. This would also be easier to extend if
  // we would at some point want to support multiple instructions retiring in the same cycle,
  // within the same RS, e.g. due to the presence of pipelines with different latencies.
  assign retired_rs_o = slot_i.has_dest ? 1'b1 : retired_o;

  //////////////////
  // RF writeback //
  //////////////////

  instr_tag_t rf_wb_tag;
  always_comb begin
    // Compose tag
    rf_wb_tag = '0;
    rf_wb_tag.dest_reg       = slot_i.dest_id;
    rf_wb_tag.dest_reg_is_fp = slot_i.dest_is_fp;
    // TODO(colluca): find proper solution for this
    // HACK:
    // We directly pass through the branch and jump details to support jumps in LCP1
    // (where we will fall back into regular HW loop mode). This is possible as the ALU is
    // single cycle and the dispatch request is valid until we write back.
    rf_wb_tag.is_branch = disp_req_i.tag.is_branch;
    rf_wb_tag.is_jump   = disp_req_i.tag.is_jump;
  end
  // TODO(colluca): Implicit cast from instr_tag_t to result_tag_t
  assign rf_wb_tag_o = rf_wb_tag;

  // In LCPx we always write back to the RF. In LEP, we need to write back in the last result
  // iteration, if we are the last instruction in program order to write to that register
  // (i.e. if `do_writeback` was set in LCP2). Instructions (e.g. stores) that don't have a
  // destination register don't writeback.
  // TODO(colluca): why do we need to mask the do_writeback signal in case of stores?
  //                Doesn't the LSU simply not raise result_valid_i when it decodes a store?
  //                And if it does, why?
  assign rf_do_writeback_o = (loop_state_i == LoopLep) ? (is_last_result_iter_i &&
    slot_i.do_writeback && !slot_i.has_dest) : 1'b1;

  //////////////////////////////////////
  // Slot update after result capture //
  //////////////////////////////////////

  always_comb begin
    slot_o = slot_i;
    if (retired_o) begin
      slot_o.result.is_valid  = 1'b1;
      slot_o.result.iteration = !slot_o.result.iteration;
      // Don't update the result FFs for stores.
      // TODO: Does this MUX really save power (by not updating the FFs) or will it add too much
      //       logic?
      // TODO(colluca): to save power we would want to avoid that it switches at all, i.e.
      // keep the value in slot_q, not '0.
      slot_o.result.value     = slot_o.has_dest ? '0 : result_i;
      slot_o.consumed_by      = '0;
    end
  end

endmodule
