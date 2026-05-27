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
  parameter bit          UseFreeList = 1'b1,
  /// Instruction stream parameters
  parameter type         disp_req_t     = logic,
  parameter type         disp_rsp_t     = logic,
  parameter type         issue_req_t    = logic,
  parameter type         instr_tag_t    = logic,
  /// Reservation Station parameters
  parameter int unsigned NofRss         = 4,
  // The maximal number of operands
  parameter rs_type_e    RsType         = ALU_RS,
  // Whether the constant/immediate is an integer (32 bit) value
  parameter bit          ConstIsInt     = 1,
  // The bits to address all registers
  parameter int unsigned RegAddrWidth   = 5,
  parameter int unsigned MaxIterationsW = 5,
  parameter int unsigned XLEN           = 32,
  parameter int unsigned FLEN           = 64,
  parameter type         producer_id_t  = logic,
  parameter type         slot_id_t      = logic,
  parameter type         operand_req_t  = logic,
  parameter type         operand_t      = logic,
  parameter type         phy_id_t       = logic,
  parameter type         refcnt_req_t   = logic,
  localparam integer unsigned NofOperands = (RsType == FPU_RS) ? 3 : 2
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
  output logic       rs_instr_exec_commit_o,

  // Operand request interface - outgoing - request a result as operand
  output operand_req_t [NofOperands-1:0] op_reqs_o,

  // Operand response interface - incoming - returning result as operand
  input  operand_t [NofOperands-1:0] op_rsps_i,
  input  logic     [NofOperands-1:0] op_rsps_valid_i,
  // Refcounte issue request intefrace
  output logic        issue_clr_req_valid_o,
  output refcnt_req_t issue_clr_req_o
);

  // ---------------------------
  // Reservation Station
  // ---------------------------

  schnova_res_stat #(
    .UseFreeList   (UseFreeList),
    .NofRss        (NofRss),
    .NofOperands   (NofOperands),
    .RsType        (RsType),
    .RegAddrWidth  (RegAddrWidth),
    .MaxIterationsW(MaxIterationsW),
    .XLEN          (XLEN),
    .FLEN          (FLEN),
    .disp_req_t    (disp_req_t),
    .disp_rsp_t    (disp_rsp_t),
    .issue_req_t   (issue_req_t),
    .instr_tag_t   (instr_tag_t),
    .producer_id_t (producer_id_t),
    .slot_id_t     (slot_id_t),
    .phy_id_t      (phy_id_t),
    .operand_req_t (operand_req_t),
    .operand_t     (operand_t),
    .refcnt_req_t  (refcnt_req_t)
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
    .disp_req_i         (disp_req_i),
    .disp_req_valid_i   (disp_req_valid_i),
    .disp_req_ready_o   (disp_req_ready_o),
    .instr_exec_commit_i(instr_exec_commit_i),
    .disp_rsp_o         (disp_rsp_o),
    // The issued instruction - to FU
    .issue_req_o        (issue_req_o),
    .issue_req_valid_o  (issue_req_valid_o),
    .issue_req_ready_i  (issue_req_ready_i),
    .instr_exec_commit_o(rs_instr_exec_commit_o),
    // Operand request interface - outgoing - request a result as operand
    .op_reqs_o          (op_reqs_o),
    // Operand response interface - incoming - returning result as operand
    .op_rsps_i          (op_rsps_i),
    .op_rsps_valid_i    (op_rsps_valid_i),
    // Refcount issue request interface
    .issue_clr_req_valid_o(issue_clr_req_valid_o),
    .issue_clr_req_o    (issue_clr_req_o)
  );

endmodule
