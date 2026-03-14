// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// The Reservation station slot. It contains the actual instruction buffer logic.
//
// Abbreviations:
// FU:  Functional Unit. This is for example an ALU, FPU or LSU.
// RS:  Reservation Station. Holds multiple RSS for a single FU and controls the execution.
// RSS: Reservation Station Slot. A slot can hold one instruction with all the required
//      information for the superscalar execution.
module schnizo_res_stat_slot import schnizo_pkg::*; #(
  parameter int unsigned NofOperands    = 2,
  parameter type         disp_req_t     = logic,
  parameter type         producer_id_t  = logic,
  parameter type         operand_req_t  = logic,
  parameter type         dest_mask_t    = logic,
  parameter type         res_rsp_t      = logic,
  parameter type         result_t       = logic,
  parameter type         result_tag_t   = logic,
  parameter type         rs_slot_t      = logic
) (
  input  logic clk_i,
  input  logic rst_i,

  // Index of the reservation station and this slot.
  input  producer_id_t producer_id_i,
  // If restart is asserted, we initialize the slot. THERE MAY NOT BE ANY instruction in flight!
  input  logic         restart_i,
  // Asserted for last LEP dispatch iteration to end the operand fetching.
  input  logic         is_last_disp_iter_i,
  // Asserted for last LEP result iteration to perform the possible writeback (based on result iteration).
  input  logic         is_last_result_iter_i,
  // Asserted in the cycle the instruction retires.
  output logic         retired_o,
  input  loop_state_e  loop_state_i,
  // Info on the result stored in the slot.
  output operand_req_t available_result_o,

  // Registered slot state (for the shared dispatch pipeline input mux at RS level)
  output rs_slot_t     slot_q_o,
  // Post-dispatch-pipeline slot state (from the shared dispatch pipeline at RS level)
  input  rs_slot_t     slot_issue_i,
  // Issue handshake from the shared dispatch pipeline
  input  logic         issue_hs_i,

  // Dispatch interface
  input  disp_req_t disp_req_i,

  // Result request interface - incoming - translated operand request
  // Result requests are converted to destination masks (where to send the result to) at RS level.
  input  dest_mask_t dest_mask_i,
  input  logic       dest_mask_valid_i,
  output logic       dest_mask_ready_o,

  // Result response interface - outgoing - result as operand response
  output res_rsp_t res_rsp_o,
  output logic     res_rsp_valid_o,
  input  logic     res_rsp_ready_i,

  // FU result interface
  input  result_t result_i,
  input  logic    result_valid_i,
  output logic    result_ready_o,

  // RF writeback interface
  output result_tag_t rf_wb_tag_o,
  output logic        rf_do_writeback_o
);

  /////////////////
  // Connections //
  /////////////////

  logic retired;

  //////////
  // Slot //
  //////////

  rs_slot_t slot_reset_value;
  rs_slot_t slot_q, slot_d;

  assign slot_reset_value = '{
    is_occupied:          1'b0, // suppresses operand requests
    consumer_count:       '0,
    consumed_by:          '0,
    alu_op:               AluOpAdd,
    lsu_op:               LsuOpLoad, // avoid store because the store flag has to be 0
    fpu_op:               FpuOpFadd,
    is_store:             1'b0,
    lsu_size:             Byte,
    fpu_fmt_src:          fpnew_pkg::FP32,
    fpu_fmt_dst:          fpnew_pkg::FP32,
    fpu_rnd_mode:         fpnew_pkg::RNE,
    // We ignore the result part - the iteration flag could be X.
    result:               '0,
    instruction_iter:     1'b0,
    dest_id:              '0,
    dest_is_fp:           '0,
    do_writeback:         1'b0,
    operands:             '0 // invalid operands lead to no issue requests
  };

  `FFAR(slot_q, slot_d, slot_reset_value, clk_i, rst_i);

  assign slot_q_o = slot_q;

  /////////////////////////////////////////////////////
  // Result request handling and response generation //
  /////////////////////////////////////////////////////

  rs_slot_t slot_res_rsp;

  schnizo_rss_res_req_handling #(
    .rs_slot_t    (rs_slot_t),
    .operand_req_t(operand_req_t),
    .producer_id_t(producer_id_t),
    .dest_mask_t  (dest_mask_t),
    .res_rsp_t    (res_rsp_t)
  ) i_res_req_handling (
    .clk_i             (clk_i),
    .rst_i             (rst_i),
    .slot_q_i          (slot_q),
    .slot_i            (slot_issue_i),
    .retired_i         (retired),
    .loop_state_i      (loop_state_i),
    .restart_i         (restart_i),
    .dest_mask_i       (dest_mask_i),
    .dest_mask_valid_i (dest_mask_valid_i),
    .dest_mask_ready_o (dest_mask_ready_o),
    .producer_id_i     (producer_id_i),
    .available_result_o(available_result_o),
    .res_rsp_o         (res_rsp_o),
    .res_rsp_valid_o   (res_rsp_valid_o),
    .res_rsp_ready_i   (res_rsp_ready_i),
    .slot_o            (slot_res_rsp)
  );

  ////////////////////
  // Result capture //
  ////////////////////

  rs_slot_t slot_wb;

  schnizo_rss_result_capture #(
    .rs_slot_t   (rs_slot_t),
    .result_t    (result_t),
    .result_tag_t(result_tag_t),
    .disp_req_t  (disp_req_t)
  ) i_result_capture (
    .slot_i               (slot_res_rsp),
    .issue_hs_i           (issue_hs_i),
    .result_i             (result_i),
    .result_valid_i       (result_valid_i),
    .loop_state_i         (loop_state_i),
    .is_last_result_iter_i(is_last_result_iter_i),
    .disp_req_i           (disp_req_i),
    .result_ready_o       (result_ready_o),
    .retired_o            (retired),
    .retired_rs_o         (retired_o),
    .rf_wb_tag_o          (rf_wb_tag_o),
    .rf_do_writeback_o    (rf_do_writeback_o),
    .slot_o               (slot_wb)
  );

  // Update the slot after all manipulations
  assign slot_d = slot_wb;

endmodule
