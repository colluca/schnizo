// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// The module hosting a Reservation Station and selecting between regular and superscalar
// instruction issue paths.
//
// In superscalar execution mode, dispatch requests are routed into the RS, which in turn produces
// issue requests. Similarly results from the FU are routed into the RS, which in turn produces
// writeback requests. In regular or single-issue execution mode, the RS is bypassed: dispatch
// requests are directly issued to the FUs and FU results are directly sent to the writeback.
// This module instantiates the RS and performs the necessary demuxing and muxing to bypass or go
// through the RS.
module schnova_fu_block import schnova_pkg::*; #(
  /// Instruction stream parameters
  parameter type         disp_req_t     = logic,
  parameter type         disp_rsp_t     = logic,
  parameter type         issue_req_t    = logic,
  parameter type         result_t       = logic,
  parameter type         instr_tag_t    = logic,
  /// Reservation Station parameters
  parameter int unsigned NofRss         = 4,
  // The maximal number of operands
  parameter int unsigned NofOperands    = 3,
  // The bits to address all registers
  parameter int unsigned RegAddrWidth   = 5,
  parameter int unsigned MaxIterationsW = 5,
  parameter type         producer_id_t  = logic,
  parameter type         slot_id_t      = logic,
  parameter type         operand_req_t  = logic,
  parameter type         operand_t      = logic,
  parameter type         phy_id_t       = logic
) (
  input  logic clk_i,
  input  logic rst_i,

  /// RS control signals
  // The producer id of the RS and thus the first RSS. Must be static.
  input  producer_id_t              producer_id_i,
  input  logic                      en_superscalar_i,
  // If restart is asserted, we initialize the RS. This will clean all RSS and reset the loop
  // handling logic.
  input  logic                      restart_i,

  output logic                      rs_full_o,
  output logic                      rs_empty_o,

  /// Instruction Stream
  // TODO(colluca): use generic_reqrsp interfaces for all of these. Would then reduce to four signals:
  // disp_req_i, disp_rsp_o, issue_req_o, issue_rsp_i, result_req_i, result_rsp_o, wb_req_o, wb_rsp_i
  //
  // From dispatcher to dispatch MUX
  input  disp_req_t disp_req_i,
  input  logic      disp_req_valid_i,
  output logic      disp_req_ready_o,
  input  logic      instr_exec_commit_i,
  output disp_rsp_t disp_rsp_o,
  // From issue MUX to FU
  output issue_req_t issue_req_o,
  output logic       issue_req_valid_o,
  input  logic       issue_req_ready_i,
  output logic       instr_exec_commit_o,

  // Operand request interface - outgoing - request a result as operand
  output operand_req_t [NofOperands-1:0] op_reqs_o,
  output logic         [NofOperands-1:0] op_reqs_valid_o,
  input  logic         [NofOperands-1:0] op_reqs_ready_i,

  // Operand response interface - incoming - returning result as operand
  input  operand_t [NofOperands-1:0] op_rsps_i,
  input  logic     [NofOperands-1:0] op_rsps_valid_i,
  output logic     [NofOperands-1:0] op_rsps_ready_o
);

  ////////////////////////
  // Datapath selection //
  ////////////////////////

  // There are two paths between dispatch and issue:
  // - a path for superscalar execution, which routes dispatch requests into the reservation
  //   station, which in turn produces issue requests (signals on this path have prefix "rs")
  // - a direct path for single issue or regular execution, which bypasses the reservation
  //   station and feeds through dispatch requests to issue requests (signals on this path have
  //   prefix "si")
  // This datapath selection block demuxes dispatch requests to the two paths and muxes issue
  // requests from the two paths.

  // From dispatch interface DEMUX to RS
  disp_req_t rs_disp_req;
  logic      rs_disp_req_valid;
  logic      rs_disp_req_ready;
  disp_rsp_t rs_disp_rsp;
  // From dispatch interface DEMUX to dispatch2issue converter
  disp_req_t si_disp_req;
  logic      si_disp_req_valid;
  logic      si_disp_req_ready;

  // From the RS to the Issue MUX
  issue_req_t rs_issue_req;
  logic       rs_issue_req_valid;
  logic       rs_issue_req_ready;
  logic       rs_instr_exec_commit;
  // From dispatch2issue converter to issue MUX
  issue_req_t si_issue_req;
  logic       si_issue_req_valid;
  logic       si_issue_req_ready;

  // Dispatch DEMUX
  assign rs_disp_req = disp_req_i;
  assign si_disp_req = disp_req_i;
  stream_demux #(
    .N_OUP (2)
  ) i_disp_demux (
    .inp_valid_i(disp_req_valid_i),
    .inp_ready_o(disp_req_ready_o),
    .oup_sel_i  (en_superscalar_i),
    .oup_valid_o({rs_disp_req_valid, si_disp_req_valid}),
    .oup_ready_i({rs_disp_req_ready, si_disp_req_ready})
  );
  // The dispatch response is always returned. The dispatcher must check when it is valid.
  // TODO(colluca): why not assign this to zero on the SI path and mux it here?
  assign disp_rsp_o = rs_disp_rsp;

  // Issue MUX
  // There is no logic in the regular dispatch and issue path. We can directly use the dispatch
  // valid/ready signals.
  // TODO(colluca): dispatch2issue converter for single-issue path is the same as the one
  //                in the gen_scalar block. Could maybe be reused.
  assign si_issue_req.fu_data = si_disp_req.fu_data;
  assign si_issue_req.tag     = si_disp_req.tag;
  assign si_issue_req_valid = si_disp_req_valid;
  assign si_disp_req_ready  = si_issue_req_ready;

  stream_mux #(
    .DATA_T(issue_req_t),
    .N_INP (2)
  ) i_fu_issue_mux (
    .inp_data_i ({rs_issue_req,       si_issue_req}),
    .inp_valid_i({rs_issue_req_valid, si_issue_req_valid}),
    .inp_ready_o({rs_issue_req_ready, si_issue_req_ready}),
    .inp_sel_i  (en_superscalar_i),
    .oup_data_o (issue_req_o),
    .oup_valid_o(issue_req_valid_o),
    .oup_ready_i(issue_req_ready_i)
  );

  assign instr_exec_commit_o = en_superscalar_i ? rs_instr_exec_commit : instr_exec_commit_i;

  // ---------------------------
  // Reservation Station
  // ---------------------------

  schnova_res_stat #(
    .NofRss        (NofRss),
    .NofOperands   (NofOperands),
    .RegAddrWidth  (RegAddrWidth),
    .MaxIterationsW(MaxIterationsW),
    .disp_req_t    (disp_req_t),
    .disp_rsp_t    (disp_rsp_t),
    .issue_req_t   (issue_req_t),
    .result_t      (result_t),
    .instr_tag_t   (instr_tag_t),
    .producer_id_t (producer_id_t),
    .slot_id_t     (slot_id_t),
    .phy_id_t      (phy_id_t),
    .operand_req_t (operand_req_t),
    .operand_t     (operand_t)
  ) i_res_stat (
    .clk_i,
    .rst_i,
    // Control signals
    .producer_id_i      (producer_id_i),
    .restart_i          (restart_i),
    .en_superscalar_i   (en_superscalar_i),
    .rs_full_o          (rs_full_o),
    .rs_empty_o         (rs_empty_o),
    // The dispatched instruction - from Dispatcher
    .disp_req_i         (rs_disp_req),
    .disp_req_valid_i   (rs_disp_req_valid),
    .disp_req_ready_o   (rs_disp_req_ready),
    .instr_exec_commit_i(instr_exec_commit_i),
    .disp_rsp_o         (rs_disp_rsp),
    // The issued instruction - to FU
    .issue_req_o        (rs_issue_req),
    .issue_req_valid_o  (rs_issue_req_valid),
    .issue_req_ready_i  (rs_issue_req_ready),
    .instr_exec_commit_o(rs_instr_exec_commit),
    // Operand request interface - outgoing - request a result as operand
    .op_reqs_o          (op_reqs_o),
    .op_reqs_valid_o    (op_reqs_valid_o),
    .op_reqs_ready_i    (op_reqs_ready_i),
    // Operand response interface - incoming - returning result as operand
    .op_rsps_i          (op_rsps_i),
    .op_rsps_valid_i    (op_rsps_valid_i),
    .op_rsps_ready_o    (op_rsps_ready_o)
  );

endmodule
