// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnova_res_stat_synth import schnova_synth_pkg::*; # (
  parameter int unsigned  NofRss = 4,
  parameter rs_type_e     RsType = ALU_RS,
  parameter int unsigned  RegAddrWidth   = 6,
  parameter int unsigned  NofRobEntries  = 32,
  localparam int unsigned RobTagWidth    = $clog2(NofRobEntries),
  localparam int unsigned NofOperands = (RsType == ALU_RS) ? 2 : 3,
  localparam type         phy_id_t       = logic [RegAddrWidth-1:0],
  localparam type         instr_tag_t    = struct packed {
    logic [RegAddrWidth-1:0]         dest_reg;
    logic [RobTagWidth-1:0]          rob_tag;
    logic                            dest_reg_is_fp;
    logic                            is_branch;
    logic                            is_jump;
  },
  localparam type        disp_req_t    = struct packed {
    fu_data_t  fu_data;
    phy_id_t                      phy_reg_op_a;
    logic                         is_op_a_fp;
    logic                         is_op_a_valid;
    phy_id_t                      phy_reg_op_b;
    logic                         is_op_b_fp;
    logic                         is_op_b_valid;
    phy_id_t                      phy_reg_op_c;
    logic                         is_op_c_valid;
    phy_id_t                      phy_reg_dest;
    instr_tag_t                   tag;
  },
  localparam type        issue_req_t  = struct packed {
    fu_data_t fu_data;
    instr_tag_t tag;
  },
  localparam type        operand_req_t = struct packed {
    phy_id_t  phy_reg; // which physical register we request
    logic     is_fp;   // if the physical register is a FPR
  }
) (
  input  logic                                              clk_i,
  input  logic                                              rst_ni,
  input  schnova_synth_pkg::producer_id_t                   producer_id_i,
  input  logic                                              restart_i,
  input  logic                                              en_superscalar_i,
  output logic                                              rs_empty_o,
  output logic                                              rs_full_o,
  input  disp_req_t                                         disp_req_i,
  input  logic                                              disp_req_valid_i,
  output logic                                              disp_req_ready_o,
  input  logic                                              instr_exec_commit_i,
  output schnova_synth_pkg::disp_rsp_t                      disp_rsp_o,
  output issue_req_t                                        issue_req_o,
  output logic                                              issue_req_valid_o,
  input  logic                                              issue_req_ready_i,
  output logic                                              instr_exec_commit_o,
  output operand_req_t                    [NofOperands-1:0] op_reqs_o,
  output logic                            [NofOperands-1:0] op_reqs_valid_o,
  input  logic                            [NofOperands-1:0] op_reqs_ready_i,
  input  schnova_synth_pkg::operand_t     [NofOperands-1:0] op_rsps_i,
  input  logic                            [NofOperands-1:0] op_rsps_valid_i,
  output logic                            [NofOperands-1:0] op_rsps_ready_o
);

  schnova_res_stat #(
    .NofRss(NofRss),
    .RsType(RsType),
    .RegAddrWidth(RegAddrWidth),
    .MaxIterationsW(schnova_synth_pkg::MaxIterationsW),
    .XLEN(schnova_synth_pkg::XLEN),
    .FLEN(schnova_synth_pkg::FLEN),
    .disp_req_t(disp_req_t),
    .disp_rsp_t(schnova_synth_pkg::disp_rsp_t),
    .issue_req_t(issue_req_t),
    .instr_tag_t(instr_tag_t),
    .producer_id_t(schnova_synth_pkg::producer_id_t),
    .slot_id_t(schnova_synth_pkg::slot_id_t),
    .phy_id_t(phy_id_t),
    .operand_req_t(operand_req_t),
    .operand_t(schnova_synth_pkg::operand_t)
  ) i_res_stat (
    .clk_i(clk_i),
    .rst_i(rst_ni),
    .producer_id_i(producer_id_i),
    .restart_i(restart_i),
    .en_superscalar_i(en_superscalar_i),
    .rs_empty_o(rs_empty_o),
    .rs_full_o(rs_full_o),
    .disp_req_i(disp_req_i),
    .disp_req_valid_i(disp_req_valid_i),
    .disp_req_ready_o(disp_req_ready_o),
    .instr_exec_commit_i(instr_exec_commit_i),
    .disp_rsp_o(disp_rsp_o),
    .issue_req_o(issue_req_o),
    .issue_req_valid_o(issue_req_valid_o),
    .issue_req_ready_i(issue_req_ready_i),
    .instr_exec_commit_o(instr_exec_commit_o),
    .op_reqs_o(op_reqs_o),
    .op_reqs_valid_o(op_reqs_valid_o),
    .op_reqs_ready_i(op_reqs_ready_i),
    .op_rsps_i(op_rsps_i),
    .op_rsps_valid_i(op_rsps_valid_i),
    .op_rsps_ready_o(op_rsps_ready_o)
  );

endmodule