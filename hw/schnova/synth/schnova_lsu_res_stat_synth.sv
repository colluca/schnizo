// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnova_lsu_res_stat_synth import schnova_synth_pkg::*;  #(
  parameter bit           UseFreeList = 1'b0,
  parameter int unsigned  NofRss      = 4,
  localparam int unsigned NofOperands = 2,
  localparam type         disp_req_t  = lsu_rs_disp_req_t,
  localparam type         issue_req_t = lsu_si_disp_req_t
) (
  input  logic                           clk_i,
  input  logic                           rst_ni,
  input  producer_id_t                   producer_id_i,
  input  logic                           restart_i,
  input  logic                           en_superscalar_i,
  output logic                           rs_empty_o,
  output logic                           rs_full_o,
  input  disp_req_t                      disp_req_i,
  input  logic                           disp_req_valid_i,
  output logic                           disp_req_ready_o,
  output disp_rsp_t                      disp_rsp_o,
  output issue_req_t                     issue_req_o,
  output logic                           issue_req_valid_o,
  input  logic                           issue_req_ready_i,
  output logic                           instr_exec_commit_o,
  output operand_req_t [NofOperands-1:0] op_reqs_o,
  input  operand_t     [NofOperands-1:0] op_rsps_i,
  input  logic         [NofOperands-1:0] op_rsps_valid_i,
  // Refcounte issue request intefrace
  output logic                           issue_clr_req_valid_o,
  output refcnt_req_t                    issue_clr_req_o
);

  schnova_res_stat #(
    .UseFreeList    (UseFreeList),
    .NofRss         (NofRss),
    .NofOperands    (NofOperands),
    .RsType         (schnova_pkg::LSU_RS),
    .RegAddrWidth   (RegAddrSize),
    .MaxIterationsW (MaxIterationsW),
    .XLEN           (XLEN),
    .FLEN           (FLEN),
    .UseSram        (1'b0),
    .disp_req_t     (disp_req_t),
    .disp_rsp_t     (disp_rsp_t),
    .issue_req_t    (issue_req_t),
    .instr_tag_t    (instr_tag_t),
    .producer_id_t  (producer_id_t),
    .slot_id_t      (slot_id_t),
    .phy_id_t       (phy_id_t),
    .operand_req_t  (operand_req_t),
    .operand_t      (operand_t),
    .refcnt_req_t   (refcnt_req_t)
  ) i_res_stat (
    .clk_i,
    .rst_i(~rst_ni),
    .producer_id_i,
    .restart_i,
    .en_superscalar_i,
    .rs_empty_o,
    .rs_full_o,
    .disp_req_i,
    .disp_req_valid_i,
    .disp_req_ready_o,
    .disp_rsp_o,
    .issue_req_o,
    .issue_req_valid_o,
    .issue_req_ready_i,
    .instr_exec_commit_o,
    .op_reqs_o,
    .op_rsps_i,
    .op_rsps_valid_i,
    .issue_clr_req_valid_o,
    .issue_clr_req_o
  );

endmodule