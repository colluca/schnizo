// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnova_refcount_synth import schnova_synth_pkg::*; #(
    parameter int unsigned PipeWidth    = 1,
    parameter int unsigned NofPhysGpr   = 64,
    parameter int unsigned NofPhysFpr   = 64,
    parameter int unsigned NofAlus      = 1,
    parameter int unsigned AluNofRss    = 3,
    parameter int unsigned NofLsus      = 1,
    parameter int unsigned LsuNofRss    = 3,
    parameter int unsigned NofFpus      = 1,
    parameter int unsigned FpuNofRss    = 2,
    parameter int unsigned NofAluBufEntries = 32,
    parameter int unsigned NofLsuBufEntries = 32,
    parameter int unsigned NofFpuBufEntries = 32
) (
    input  logic                         clk_i,
    input  logic                         rst_ni,
    // Dispatcher Interface (Set new reference for RAT)
    input  logic                         instr_exec_commit_superscalar_i,
    input  logic      [PipeWidth-1:0]    instr_valid_i,
    input  logic                         dispatched_i,
    input  refcnt_req_t [PipeWidth-1:0]  refcnt_disp_req_i,
    input  phy_id_t   [PipeWidth-1:0]    phy_reg_rd_i,
    input  phy_id_t   [PipeWidth-1:0]    phy_reg_rd_old_i,
    input  logic      [PipeWidth-1:0]    is_rd_fp_i,
    // Issue Inteface (Clear / Overwrite entries)
    input  logic        [NofAlus-1:0]    issue_alu_clr_req_valid_i,
    input  refcnt_req_t [NofAlus-1:0]    issue_alu_clr_req_i,
    input  logic        [NofLsus-1:0]    issue_lsu_clr_req_valid_i,
    input  refcnt_req_t [NofLsus-1:0]    issue_lsu_clr_req_i,
    input  logic        [NofFpus-1:0]    issue_fpu_clr_req_valid_i,
    input  refcnt_req_t [NofFpus-1:0]    issue_fpu_clr_req_i,
    // Allocation interface
    input  logic [$clog2(PipeWidth):0]   rename_gpr_count_i,
    input  logic [$clog2(PipeWidth):0]   rename_fpr_count_i,
    output phy_id_t [PipeWidth-1:0]      allocated_gpr_regs_o,
    output phy_id_t [PipeWidth-1:0]      allocated_fpr_regs_o,
    output logic                         phy_reg_alloc_ready_o,
    // From Scoreboard
    input logic [NofPhysGpr-1:0]         sbi_q_i,
    input logic [NofPhysFpr-1:0]         sbf_q_i
);

  schnova_refcount #(
    .PipeWidth        (PipeWidth),
    .NofPhysGpr       (NofPhysGpr),
    .NofPhysFpr       (NofPhysFpr),
    .NofAlus          (NofAlus), 
    .AluNofRss        (AluNofRss), 
    .NofLsus          (NofLsus), 
    .LsuNofRss        (LsuNofRss), 
    .NofFpus          (NofFpus), 
    .FpuNofRss        (FpuNofRss), 
    .NofAluBufEntries (NofAluBufEntries),
    .NofLsuBufEntries (NofLsuBufEntries),
    .NofFpuBufEntries (NofFpuBufEntries),
    .phy_id_t         (phy_id_t),
    .refcnt_req_t     (refcnt_req_t)
  ) i_refcount (
    .clk_i,
    .rst_i(~rst_ni),
    .instr_exec_commit_superscalar_i,
    .instr_valid_i,
    .dispatched_i,
    .refcnt_disp_req_i,
    .phy_reg_rd_i,
    .phy_reg_rd_old_i,
    .is_rd_fp_i,
    .issue_alu_clr_req_valid_i,
    .issue_alu_clr_req_i,
    .issue_lsu_clr_req_valid_i,
    .issue_lsu_clr_req_i,
    .issue_fpu_clr_req_valid_i,
    .issue_fpu_clr_req_i,
    .rename_gpr_count_i,
    .rename_fpr_count_i,
    .allocated_gpr_regs_o,
    .allocated_fpr_regs_o,
    .phy_reg_alloc_ready_o,
    .sbi_q_i,
    .sbf_q_i
);

endmodule