// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// Datapath of the Reservation Station.
// Contains the slot registers, dispatch pipeline, result capture, and RF writeback path.
module schnova_res_stat_slots import schnova_pkg::*; #(
  parameter  int unsigned     NofRss           = 4,
  parameter  int unsigned     NofOperands      = 3,
  parameter  int unsigned     RegAddrWidth     = 5,
  parameter  bit              UseSram          = 1'b0,
  parameter  type             rs_slot_issue_t  = logic,
  parameter  type             rs_slot_result_t = logic,
  parameter  type             rss_operand_t    = logic,
  parameter  type             disp_req_t       = logic,
  parameter  type             issue_req_t      = logic,
  parameter  type             result_t         = logic,
  parameter  type             producer_id_t    = logic,
  parameter  type             slot_id_t        = logic,
  parameter  type             phy_id_t         = logic,
  parameter  type             operand_req_t    = logic,
  parameter  type             operand_t        = logic,
  localparam integer unsigned NofRssWidth      = cf_math_pkg::idx_width(NofRss),
  localparam type             rss_idx_t        = logic [NofRssWidth-1:0]
) (
  input  logic clk_i,
  input  logic rst_i,

  // Control
  input  producer_id_t producer_id_i,
  input  logic         restart_i,
  input  rss_idx_t     disp_idx_i,
  input  rss_idx_t     issue_idx_i,
  output logic         retiring_o,

  // Dispatch
  input  disp_req_t    disp_req_i,
  input  logic         disp_req_valid_i,
  output logic         disp_req_ready_o,
  // producer id of the slot that was dispatched to
  output producer_id_t disp_rsp_o,
  output logic         disp_hs_o,
  input logic          rs_full_i,

  // Issue
  output issue_req_t issue_req_o,
  output logic       issue_req_valid_o,
  input  logic       issue_req_ready_i,
  output logic       instr_exec_commit_o,

  // Operand request
  output operand_req_t [NofOperands-1:0] op_reqs_o,
  output logic         [NofOperands-1:0] op_reqs_valid_o,
  input  logic         [NofOperands-1:0] op_reqs_ready_i,

  // Operand response
  input  operand_t [NofOperands-1:0] op_rsps_i,
  input  logic     [NofOperands-1:0] op_rsps_valid_i,
  output logic     [NofOperands-1:0] op_rsps_ready_o
);

  /////////////////
  // Connections //
  /////////////////


  rs_slot_issue_t               slot_issue_rdata;      // registered issue state for the selected slot
  rs_slot_issue_t               slot_disp_wdata;      // post-dispatch-pipeline issue state for the selected slot
  logic                         issue_hs;          // issue handshake from the dispatch pipeline

  // We retire the current slot, as soon as we successfully
  // issue the instruction from it.
  assign retiring_o = issue_hs;

  ///////////
  // Slots //
  ///////////

  slot_id_t     [NofRss-1:0] slot_ids;
  producer_id_t [NofRss-1:0] rss_ids;

  logic rs_write_entry_enable;
  logic rs_clear_entry_enable;

  // Issue slots
  schnova_res_stat_memory #(
    .NofRss         (NofRss),
    .UseSram        (UseSram),
    .rs_slot_issue_t(rs_slot_issue_t)
  ) i_issue_slots (
    .clk_i,
    .rst_i,
    .raddr_i(issue_idx_i),
    .rdata_o(slot_issue_rdata),
    .clear_entry_i(issue_hs),
    .wen_i  (disp_hs_o),
    .waddr_i(disp_idx_i),
    .wdata_i(slot_disp_wdata)
  );

  // Generate the ids of all the reservation station slots
  for (genvar rss = 0; rss < NofRss; rss++) begin : gen_rss
    assign slot_ids[rss] = slot_id_t'(rss);
    assign rss_ids[rss] = producer_id_t'{
      slot_id: slot_ids[rss],
      rs_id:   producer_id_i.rs_id
    };
  end

  ///////////////////////
  // Dispatch pipeline //
  ///////////////////////

  logic       issue_req_valid_raw;
  issue_req_t issue_req_raw;

  schnova_rss_dispatch_pipeline #(
    .NofOperands     (NofOperands),
    .disp_req_t      (disp_req_t),
    .producer_id_t   (producer_id_t),
    .rs_slot_issue_t (rs_slot_issue_t),
    .rs_slot_result_t(rs_slot_result_t),
    .rss_operand_t   (rss_operand_t),
    .operand_req_t   (operand_req_t),
    .operand_t       (operand_t),
    .issue_req_t     (issue_req_t),
    .rss_idx_t       (rss_idx_t)
  ) i_dispatch_pipeline (
    .restart_i              (restart_i),
    .disp_producer_id_i     (rss_ids[disp_idx_i]),
    .issue_producer_id_i    (rss_ids[issue_idx_i]),
    .disp_idx_i             (disp_idx_i),
    .issue_idx_i            (issue_idx_i),
    .disp_req_i             (disp_req_i),
    .disp_req_valid_i       (disp_req_valid_i),
    .disp_req_ready_o       (disp_req_ready_o),
    .rs_full_i              (rs_full_i),
    .disp_hs_o              (disp_hs_o),
    .slot_issue_i           (slot_issue_rdata),
    .slot_disp_o            (slot_disp_wdata),
    .op_reqs_o              (op_reqs_o),
    .op_reqs_valid_o        (op_reqs_valid_o),
    .op_reqs_ready_i        (op_reqs_ready_i),
    .op_rsps_i              (op_rsps_i),
    .op_rsps_valid_i        (op_rsps_valid_i),
    .op_rsps_ready_o        (op_rsps_ready_o),
    .issue_req_o            (issue_req_raw),
    .issue_req_valid_o      (issue_req_valid_raw),
    .issue_req_ready_i      (issue_req_ready_i),
    .issue_hs_o             (issue_hs)
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

endmodule
