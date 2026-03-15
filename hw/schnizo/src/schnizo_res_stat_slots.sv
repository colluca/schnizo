// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// Datapath of the Reservation Station.
// Contains the slot registers, dispatch pipeline, result capture, and RF writeback path.
module schnizo_res_stat_slots import schnizo_pkg::*; #(
  parameter  int unsigned     NofRss        = 4,
  parameter  int unsigned     NofOperands   = 3,
  parameter  int unsigned     NofResRspIfs  = 1,
  parameter  int unsigned     ConsumerCount = 4,
  parameter  int unsigned     RegAddrWidth  = 5,
  parameter  type             rs_slot_t     = logic,
  parameter  type             rss_operand_t = logic,
  parameter  type             rss_result_t  = logic,
  parameter  type             disp_req_t    = logic,
  parameter  type             issue_req_t   = logic,
  parameter  type             result_t      = logic,
  parameter  type             result_tag_t  = logic,
  parameter  type             producer_id_t = logic,
  parameter  type             slot_id_t     = logic,
  parameter  type             operand_req_t = logic,
  parameter  type             operand_t     = logic,
  parameter  type             res_req_t     = logic,
  parameter  type             dest_mask_t   = logic,
  parameter  type             res_rsp_t     = logic,
  localparam integer unsigned NofRssWidth   = cf_math_pkg::idx_width(NofRss),
  localparam type             rss_idx_t     = logic [NofRssWidth-1:0]
) (
  input  logic clk_i,
  input  logic rst_i,

  // Control
  input  producer_id_t producer_id_i,
  input  logic         restart_i,
  input  loop_state_e  loop_state_i,
  input  rss_idx_t     disp_idx_i,
  input  logic         last_result_iter_i,
  output logic         retiring_o,

  // Dispatch
  input  disp_req_t    disp_req_i,
  input  logic         disp_req_valid_i,
  output logic         disp_req_ready_o,
  // producer id of the slot that was dispatched to
  output producer_id_t disp_rsp_o,

  // Issue
  output issue_req_t issue_req_o,
  output logic       issue_req_valid_o,
  input  logic       issue_req_ready_i,
  output logic       instr_exec_commit_o,

  // Result from FU
  input  result_t     result_i,
  input  result_tag_t result_tag_i,
  input  logic        result_valid_i,
  output logic        result_ready_o,

  // RF writeback
  output result_t     rf_wb_result_o,
  output result_tag_t rf_wb_tag_o,
  output logic        rf_wb_valid_o,
  input  logic        rf_wb_ready_i,

  // Operand request
  output operand_req_t [NofRss-1:0]      available_results_o,
  output operand_req_t [NofOperands-1:0] op_reqs_o,
  output logic         [NofOperands-1:0] op_reqs_valid_o,
  input  logic         [NofOperands-1:0] op_reqs_ready_i,

  // Result request
  input  dest_mask_t [NofResRspIfs-1:0] res_reqs_i,
  input  logic       [NofResRspIfs-1:0] res_reqs_valid_i,
  output logic       [NofResRspIfs-1:0] res_reqs_ready_o,

  // Result response
  output res_rsp_t [NofResRspIfs-1:0] res_rsps_o,
  output logic     [NofResRspIfs-1:0] res_rsps_valid_o,
  input  logic     [NofResRspIfs-1:0] res_rsps_ready_i,

  // Operand response
  input  operand_t [NofOperands-1:0] op_rsps_i,
  input  logic     [NofOperands-1:0] op_rsps_valid_i,
  output logic     [NofOperands-1:0] op_rsps_ready_o
);

  /////////////////////////////////////
  // Parameters and type definitions //
  /////////////////////////////////////

  localparam integer unsigned ConsumerCountWidth = cf_math_pkg::idx_width(ConsumerCount);

  /////////////////
  // Connections //
  /////////////////


  rss_idx_t result_rss_sel;
  assign result_rss_sel = rss_idx_t'(result_tag_i);

  rs_slot_t [NofRss-1:0] slot_qs;          // registered state of each slot
  rs_slot_t [NofRss-1:0] slot_ds;          // next state for each slot
  rs_slot_t              slot_issue;       // post-dispatch-pipeline state for the selected slot
  logic                  issue_hs;         // issue handshake from the dispatch pipeline
  rs_slot_t [NofRss-1:0] slot_res_rsps;    // post-res-req-handling state from each slot
  rs_slot_t              slot_wb_capture;  // post-result-capture state for the selected slot
  logic                  capture_retired;
  logic                  capture_retired_rs;
  result_tag_t           capture_rf_wb_tag;
  logic                  capture_rf_do_writeback;

  assign retiring_o = capture_retired_rs;

  ///////////
  // Slots //
  ///////////

  slot_id_t     [NofRss-1:0] slot_ids;
  producer_id_t [NofRss-1:0] rss_ids;

  rs_slot_t slot_reset_value;
  assign slot_reset_value = '{
    is_occupied:          1'b0, // suppresses operand requests
    consumer_count:       '0,
    consumed_by:          '0,
    alu_op:               AluOpAdd,
    lsu_op:               LsuOpLoad, // avoid store because the store flag has to be 0
    fpu_op:               FpuOpFadd,
    lsu_size:             Byte,
    fpu_fmt_src:          fpnew_pkg::FP32,
    fpu_fmt_dst:          fpnew_pkg::FP32,
    fpu_rnd_mode:         fpnew_pkg::RNE,
    // We ignore the result part - the iteration flag could be X.
    result:               '0,
    instruction_iter:     1'b0,
    has_dest:             1'b0,
    dest_id:              '0,
    dest_is_fp:           '0,
    do_writeback:         1'b0,
    operands:             '0 // invalid operands lead to no issue requests
  };

  for (genvar rss = 0; rss < NofRss; rss++) begin : gen_rss
    assign slot_ids[rss] = slot_id_t'(rss);
    assign rss_ids[rss] = producer_id_t'{
      slot_id: slot_ids[rss],
      rs_id:   producer_id_i.rs_id
    };

    assign slot_ds[rss] = (rss_idx_t'(rss) == result_rss_sel) ? slot_wb_capture : slot_res_rsps[rss];
    `FFAR(slot_qs[rss], slot_ds[rss], slot_reset_value, clk_i, rst_i);

    schnizo_rss_res_req_handling #(
      .rs_slot_t    (rs_slot_t),
      .operand_req_t(operand_req_t),
      .producer_id_t(producer_id_t),
      .dest_mask_t  (dest_mask_t),
      .res_rsp_t    (res_rsp_t)
    ) i_res_req_handling (
      .clk_i,
      .rst_i,
      .slot_q_i          (slot_qs[rss]),
      .slot_i            (disp_req_valid_i && (rss_idx_t'(rss) == disp_idx_i) ? slot_issue : slot_qs[rss]),
      .retired_i         (capture_retired && (rss_idx_t'(rss) == result_rss_sel)),
      .loop_state_i      (loop_state_i),
      .restart_i         (restart_i),
      .dest_mask_i       (res_reqs_i[rss]),
      .dest_mask_valid_i (res_reqs_valid_i[rss]),
      .dest_mask_ready_o (res_reqs_ready_o[rss]),
      .producer_id_i     (rss_ids[rss]),
      .available_result_o(available_results_o[rss]),
      .res_rsp_o         (res_rsps_o[rss]),
      .res_rsp_valid_o   (res_rsps_valid_o[rss]),
      .res_rsp_ready_i   (res_rsps_ready_i[rss]),
      .slot_o            (slot_res_rsps[rss])
    );
  end

  ///////////////////////
  // Dispatch pipeline //
  ///////////////////////

  logic disp_req_ready_pipeline;
  assign disp_req_ready_o = disp_req_ready_pipeline;

  logic       issue_req_valid_raw;
  issue_req_t issue_req_raw;

  schnizo_rss_dispatch_pipeline #(
    .NofOperands  (NofOperands),
    .disp_req_t   (disp_req_t),
    .producer_id_t(producer_id_t),
    .rs_slot_t    (rs_slot_t),
    .rss_operand_t(rss_operand_t),
    .rss_result_t (rss_result_t),
    .operand_req_t(operand_req_t),
    .res_req_t    (res_req_t),
    .operand_t    (operand_t),
    .issue_req_t  (issue_req_t)
  ) i_dispatch_pipeline (
    .restart_i         (restart_i),
    .producer_id_i     (rss_ids[disp_idx_i]),
    .loop_state_i      (loop_state_i),
    .disp_req_i        (disp_req_i),
    .disp_req_valid_i  (disp_req_valid_i),
    .disp_req_ready_o  (disp_req_ready_pipeline),
    .slot_i            (slot_qs[disp_idx_i]),
    .slot_reset_state_i(slot_reset_value),
    .op_reqs_o         (op_reqs_o),
    .op_reqs_valid_o   (op_reqs_valid_o),
    .op_reqs_ready_i   (op_reqs_ready_i),
    .op_rsps_i         (op_rsps_i),
    .op_rsps_valid_i   (op_rsps_valid_i),
    .op_rsps_ready_o   (op_rsps_ready_o),
    .issue_req_o       (issue_req_raw),
    .issue_req_valid_o (issue_req_valid_raw),
    .issue_req_ready_i (issue_req_ready_i),
    .issue_hs_o        (issue_hs),
    .slot_o            (slot_issue)
  );

  // TODO(colluca): use rss_ids
  assign disp_rsp_o = producer_id_t'{
    slot_id: slot_ids[disp_idx_i],
    rs_id:   producer_id_i.rs_id
  };

  assign issue_req_valid_o   = issue_req_valid_raw;
  assign issue_req_o         = issue_req_raw;

  // Each accepted dispatch request was committed so we also commit to each issue request.
  assign instr_exec_commit_o = issue_req_valid_o;

  /////////////////////////
  // Result RF/RSS demux //
  /////////////////////////

  logic rss_wb_valid, rss_wb_ready;
  logic rf_wb_valid, rf_wb_ready;

  stream_fork #(
    .N_OUP(32'd2)
  ) i_result_fork (
    .clk_i,
    .rst_ni (!rst_i),
    .valid_i(result_valid_i),
    .ready_o(result_ready_o),
    .valid_o({rf_wb_valid, rss_wb_valid}),
    .ready_i({rf_wb_ready, rss_wb_ready})
  );

  ///////////////////////////////////////
  // Synchronize RF and RSS writebacks //
  ///////////////////////////////////////

  // Synchronize the two streams, otherwise it may occur that a result
  // capture event precedes an issue event, with single-cycle FUs.
  // While this does not seem to compromise correctness, it does complicate the
  // tracer design, and it does go against the expectation that issue
  // precedes result capture.

  logic rf_do_writeback;
  assign rf_do_writeback = capture_rf_do_writeback;

  logic rss_wb_valid_sync, rss_wb_ready_sync;
  logic rf_wb_valid_sync, rf_wb_ready_sync;
  logic rss_wb_enable;

  assign rf_wb_valid_sync  = rf_wb_valid && rss_wb_ready_sync;
  assign rf_wb_ready       = rf_wb_ready_sync && rss_wb_ready_sync;
  assign rss_wb_enable     = rf_do_writeback ? rf_wb_valid_sync && rf_wb_ready_sync : 1'b1;
  assign rss_wb_valid_sync = rss_wb_valid && rss_wb_enable;
  assign rss_wb_ready      = rss_wb_ready_sync && rss_wb_enable;

  //////////////////
  // RF writeback //
  //////////////////

  stream_filter i_filter_rf_writeback (
    .valid_i(rf_wb_valid_sync),
    .ready_o(rf_wb_ready_sync),
    .drop_i (!rf_do_writeback),
    .valid_o(rf_wb_valid_o),
    .ready_i(rf_wb_ready_i)
  );
  assign rf_wb_result_o = result_i;
  assign rf_wb_tag_o    = capture_rf_wb_tag;

  /////////////////////
  // Result capture  //
  /////////////////////

  schnizo_rss_result_capture #(
    .rs_slot_t   (rs_slot_t),
    .result_t    (result_t),
    .result_tag_t(result_tag_t),
    .disp_req_t  (disp_req_t)
  ) i_result_capture (
    .clk_i,
    .rst_i,
    .slot_i               (slot_res_rsps[result_rss_sel]),
    .issue_hs_i           (issue_hs && (disp_idx_i == result_rss_sel)),
    .result_i             (result_i),
    .result_valid_i       (rss_wb_valid_sync),
    .loop_state_i         (loop_state_i),
    .is_last_result_iter_i(last_result_iter_i),
    .disp_req_i           (disp_req_i),
    .result_ready_o       (rss_wb_ready_sync),
    .retired_o            (capture_retired),
    .retired_rs_o         (capture_retired_rs),
    .rf_wb_tag_o          (capture_rf_wb_tag),
    .rf_do_writeback_o    (capture_rf_do_writeback),
    .slot_o               (slot_wb_capture)
  );

endmodule
