// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: The Reservation station which handles the instruction issuing of a functional
// unit during superscalar loop execution.

// Abbreviations:
// FU:  Functional Unit. This is for example an ALU, FPU or LSU.
// RS:  Reservation Station. Holds multiple RSS for a single FU and controls the execution.
// RSS: Reservation Station Slot. A slot can hold one instruction with all the required
//      information for the superscalar execution.
// RF:  Register File

`include "common_cells/registers.svh"

module schnizo_res_stat import schnizo_pkg::*; #(
  // Bits to address all other producers
  parameter int unsigned NofRs         = 5,
  parameter int unsigned NofRss        = 4,
  // The bits to address all registers
  parameter int unsigned RegAddrWidth  = 5,
  parameter int unsigned OpLen         = 32,
  parameter type         disp_req_t    = logic,
  parameter type         disp_rsp_t    = logic,
  parameter type         issue_req_t   = logic,
  parameter type         result_t      = logic,
  parameter type         result_tag_t  = logic
) (
  input  logic clk_i,
  input  logic rst_i,

  // The dispatched instruction - from Dispatcher
  input  disp_req_t disp_req_i,
  input  logic      disp_req_valid_i,
  output logic      disp_req_ready_o,
  output disp_rsp_t disp_rsp_o,

  // The issued instruction - to FU
  output issue_req_t issue_req_o,
  output logic       issue_req_valid_o,
  input  logic       issue_req_ready_i,

  // Result from FU
  input  result_t result_i,
  input  logic    result_valid_i,
  output logic    result_ready_o,

  // RF writeback
  output result_t     rf_wb_result,
  output result_tag_t rf_wb_tag_o,
  output logic        rf_wb_valid_o,
  input  logic        rf_wb_ready_i
);
  // ---------------------------
  // Reservation Station definitions
  // ---------------------------
  localparam integer unsigned NofRsWidth  = cf_math_pkg::idx_width(NofRs);
  localparam integer unsigned NofRssWidth = cf_math_pkg::idx_width(NofRss);
  // The maximal number of operands.
  localparam int NofOperands = 3;

  typedef logic [OpLen-1:0] operand_t;

  typedef logic [NofRsWidth-1:0]  rs_id_t;
  typedef logic [NofRssWidth-1:0] rss_id_t;
  typedef logic [NofOperands-1:0] op_id_t; // onehot encoded operands to fuse response requests.

  typedef struct packed {
    rs_id_t  rs;
    rss_id_t rss;
  } producer_id_t;

  typedef struct packed {
    rs_id_t  rs;
    rss_id_t rss;
    op_id_t  operand;
  } consumer_id_t;

  // In theory each other RSS in the system and the RSS itself could be a consumer. Thus use full width.
  // TODO: optimize to a useful number
  localparam integer unsigned ConsumerCount = 2**$bits(consumer_id_t);

  typedef struct packed {
    result_tag_t  tag;
    producer_id_t producer;
  } rs_result_tag_t;

  typedef struct packed {
    producer_id_t producer;
    logic         requested_iter;
  } operand_req_t;

  typedef struct packed {
    logic         requested_iter;
    consumer_id_t consumer;
  } result_req_t;

  typedef struct packed {
    consumer_id_t consumer;
    operand_t     operand;
  } result_rsp_t;

  // ---------------------------
  // Reservation Station
  // ---------------------------
  rs_id_t rs_id; // this module's id

  disp_req_t [NofRss-1:0] disp_reqs;
  logic      [NofRss-1:0] disps_valid;
  logic      [NofRss-1:0] disps_ready;

  // Operand distribution network
  operand_req_t [NofRss-1:0][NofOperands-1:0] op_reqs;
  logic         [NofRss-1:0][NofOperands-1:0] op_reqs_valid;
  logic         [NofRss-1:0][NofOperands-1:0] op_reqs_ready;
  result_req_t  [NofRss-1:0]                  res_reqs;
  logic         [NofRss-1:0]                  res_reqs_valid;
  logic         [NofRss-1:0]                  res_reqs_ready;
  result_rsp_t  [NofRss-1:0]                  res_rsps;
  logic         [NofRss-1:0]                  res_rsps_valid;
  logic         [NofRss-1:0]                  res_rsps_ready;
  operand_t     [NofRss-1:0][NofOperands-1:0] op_rsps;
  logic         [NofRss-1:0][NofOperands-1:0] op_rsps_valid;
  logic         [NofRss-1:0][NofOperands-1:0] op_rsps_ready;

  // To / from FU and RF writeback
  issue_req_t  [NofRss-1:0] issue_reqs;
  logic        [NofRss-1:0] issues_valid;
  logic        [NofRss-1:0] issues_ready;
  result_t     [NofRss-1:0] results;
  logic        [NofRss-1:0] results_valid;
  logic        [NofRss-1:0] results_ready;
  result_t     [NofRss-1:0] rf_wb_results;
  result_tag_t [NofRss-1:0] rf_wb_tags;
  logic        [NofRss-1:0] rf_wbs_valid;
  logic        [NofRss-1:0] rf_wbs_ready;

  for (genvar rss = 0; rss < NofRss; rss = rss + 1) begin : gen_operand_req_rss
    producer_id_t rss_id;
    assign rss_id.rs = rs_id;
    assign rss_id.rss = rss_id_t'(rss);

    schnizo_res_stat_slot #(
      .NofOperands  (NofOperands),
      .ConsumerCount(ConsumerCount),
      .RegAddrWidth (RegAddrWidth),
      .disp_req_t   (disp_req_t),
      .producer_id_t(producer_id_t),
      .operand_req_t(operand_req_t),
      .operand_t    (operand_t),
      .result_req_t (result_req_t),
      .result_rsp_t(result_rsp_t),
      .issue_req_t  (issue_req_t),
      .result_t     (result_t),
      .result_tag_t (result_tag_t)
    ) i_rss (
      .clk_i,
      .rst_i,

      // TODO: Add reset
      .is_last_lep_i    (),
      .own_producer_id_i(rss_id),

      .disp_req_i      (disp_reqs[rss]),
      .disp_req_valid_i(disps_valid[rss]),
      .disp_req_ready_o(disps_ready[rss]),

      .op_reqs_o      (op_reqs[rss]),
      .op_reqs_valid_o(op_reqs_valid[rss]),
      .op_reqs_ready_i(op_reqs_ready[rss]),

      .res_req_i      (res_reqs[rss]),
      .res_req_valid_i(res_reqs_valid[rss]),
      .res_req_ready_o(res_reqs_ready[rss]),

      .res_rsp_o      (res_rsps[rss]),
      .res_rsp_valid_o(res_rsps_valid[rss]),
      .res_rsp_ready_i(res_rsps_ready[rss]),

      .op_rsps_i      (op_rsps[rss]),
      .op_rsps_valid_i(op_rsps_valid[rss]),
      .op_rsps_ready_o(op_rsps_ready[rss]),

      .issue_req_o      (issue_reqs[rss]),
      .issue_req_valid_o(issues_valid[rss]),
      .issue_req_ready_i(issues_ready[rss]),

      .result_i      (results[rss]),
      .result_valid_i(results_valid[rss]),
      .result_ready_o(results_ready[rss]),

      .rf_wb_result_o(rf_wb_results[rss]),
      .rf_wb_tag_o   (rf_wb_tags[rss]),
      .rf_wb_valid_o (rf_wbs_valid[rss]),
      .rf_wb_ready_i (rf_wbs_ready[rss])
    );

  end














  // TODO: we must add a RSS tag to the result. -> No, step the DEMUX only when a handshake happened

endmodule
