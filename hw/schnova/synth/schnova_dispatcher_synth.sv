// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnova_dispatcher_synth import schnova_synth_pkg::*; #(
  parameter int unsigned PipeWidth   = 1,
  parameter int unsigned NofAlus     = 1,
  parameter int unsigned NofLsus     = 1,
  parameter int unsigned NofFpus     = 1,
  parameter int unsigned NofAluBufEntries = 32,
  parameter int unsigned NofLsuBufEntries = 32,
  parameter int unsigned NofFpuBufEntries = 32
) (
  input  logic                                 clk_i,
  input  logic                                 rst_ni,
  input  logic                                 en_superscalar_i,
  // Handshake to dispatch instruction consisting of instr_dec_i and instr_fu_data_i
  input  instr_dec_t [PipeWidth-1:0]           instr_dec_i,
  input  fu_data_t   [PipeWidth-1:0]           instr_fu_data_i,
  input  logic       [32*PipeWidth-1:0]        instr_fetch_data_i,
  input  logic                                 dispatch_valid_i,
  output logic                                 dispatch_ready_o,
  input  logic                                 instr_exec_commit_i,
  input  logic [PipeWidth-1:0]                 instr_valid_i,
  input  logic [PipeWidth-1:0]                 instr_rename_gpr_valid_i,
  input  logic [$clog2(PipeWidth):0]           instr_rename_gpr_count_i,
  input  logic [PipeWidth-1:0]                 instr_rename_fpr_valid_i,
  input  logic [$clog2(PipeWidth):0]           instr_rename_fpr_count_i,
  // From rename stage
  input  reg_map_t [PipeWidth-1:0]             reg_map_i,
  // From/to ROB
  output logic                                 first_instr_dispatched_o,
  input logic [PipeWidth-1:0][RobTagWidth-1:0] rob_idx_i,
  // Each FU has a response which must be valid at dispatch request handshake.
  // ALU
  output alu_si_disp_req_t                     alu_si_disp_req_o,
  output logic                                 alu_si_disp_req_valid_o,
  input  logic                                 alu_si_disp_req_ready_i,
  output alu_rs_disp_req_t [NofAlus-1:0]       alu_rs_disp_reqs_o,
  output logic             [NofAlus-1:0]       alu_rs_disp_req_valid_o,
  input  logic             [NofAlus-1:0]       alu_rs_disp_req_ready_i,
  input  disp_rsp_t        [NofAlus-1:0]       alu_rs_disp_rsp_i,
  input  logic             [NofAlus-1:0]       alu_rs_full_i,

  // LSU
  output lsu_si_disp_req_t                     lsu_si_disp_req_o,
  output logic                                 lsu_si_disp_req_valid_o,
  input  logic                                 lsu_si_disp_req_ready_i,
  output lsu_rs_disp_req_t [NofLsus-1:0]       lsu_rs_disp_reqs_o,
  output logic             [NofLsus-1:0]       lsu_rs_disp_req_valid_o,
  input  logic             [NofLsus-1:0]       lsu_rs_disp_req_ready_i,
  input  disp_rsp_t        [NofLsus-1:0]       lsu_rs_disp_rsp_i,
  input  logic             [NofLsus-1:0]       lsu_rs_full_i,

  // Handshake to the CSR FU. There is no response as it does not have a reservation station.
  output csr_disp_req_t                        csr_disp_req_o,
  output logic                                 csr_disp_req_valid_o,
  input  logic                                 csr_disp_req_ready_i,
  // FPU
  output fpu_si_disp_req_t                     fpu_si_disp_req_o,
  output logic                                 fpu_si_disp_req_valid_o,
  input  logic                                 fpu_si_disp_req_ready_i,
  output fpu_rs_disp_req_t [NofFpus-1:0]       fpu_rs_disp_reqs_o,
  output logic             [NofFpus-1:0]       fpu_rs_disp_req_valid_o,
  input  logic             [NofFpus-1:0]       fpu_rs_disp_req_ready_i,
  input  disp_rsp_t        [NofFpus-1:0]       fpu_rs_disp_rsp_i,
  input  logic             [NofFpus-1:0]       fpu_rs_full_i,
  // Handshake to the accelerator interface
  output acc_req_t                             acc_req_o,
  output logic                                 acc_disp_req_valid_o,
  input  logic                                 acc_disp_req_ready_i,
  // The accelerator response is routed directly to the write back.
  output logic                                 disp_buffers_empty_o,
  // RS control signals
  // Asserted if the RSS are cleared synchronously.
  input  logic                                 restart_i,
  // Memory consistency mode during FREP loop
  input schnova_pkg::frep_mem_cons_mode_e      frep_mem_cons_mode_i,
  // To refcount
  output refcnt_req_t [PipeWidth-1:0]          refcnt_disp_req_o
);

  schnova_dispatcher # (
    .UseFreeList        (1'b0),
    .PipeWidth          (PipeWidth),
    .XLEN               (XLEN),
    .XFREPO             (1'b1),
    .NofAlus            (NofAlus),
    .NofLsus            (NofLsus),
    .NofFpus            (NofFpus),
    .NofAluBufEntries   (NofAluBufEntries),
    .NofLsuBufEntries   (NofLsuBufEntries),
    .NofFpuBufEntries   (NofFpuBufEntries),
    .RobTagWidth        (RobTagWidth),
    .instr_dec_t        (instr_dec_t),
    .instr_tag_t        (instr_tag_t),
    .csr_disp_req_t     (csr_disp_req_t),
    .alu_si_disp_req_t  (alu_si_disp_req_t),
    .lsu_si_disp_req_t  (lsu_si_disp_req_t),
    .fpu_si_disp_req_t  (fpu_si_disp_req_t),
    .alu_rs_disp_req_t  (alu_rs_disp_req_t),
    .lsu_rs_disp_req_t  (lsu_rs_disp_req_t),
    .fpu_rs_disp_req_t  (fpu_rs_disp_req_t),
    .disp_rsp_t         (disp_rsp_t),
    .refcnt_req_t       (refcnt_req_t),
    .producer_id_t      (producer_id_t),
    .rs_id_t            (rs_id_t),
    .reg_map_t          (reg_map_t),
    .fu_data_t          (fu_data_t),
    .acc_req_t          (acc_req_t ),
    .sb_disp_data_t     (sb_disp_data_t)
  ) i_dispatcher (
    .clk_i,
    .rst_i(~rst_ni),
    .en_superscalar_i,
    .instr_dec_i,
    .instr_fu_data_i,
    .instr_fetch_data_i,
    .dispatch_valid_i,
    .dispatch_ready_o,
    .instr_exec_commit_i,
    .instr_valid_i,
    .instr_rename_gpr_valid_i,
    .instr_rename_gpr_count_i,
    .instr_rename_fpr_valid_i,
    .instr_rename_fpr_count_i,
    .reg_map_i,
    .first_instr_dispatched_o,
    .rob_idx_i,
    .alu_si_disp_req_o,
    .alu_si_disp_req_valid_o,
    .alu_si_disp_req_ready_i,
    .alu_rs_disp_reqs_o,
    .alu_rs_disp_req_valid_o,
    .alu_rs_disp_req_ready_i,
    .alu_rs_disp_rsp_i,
    .alu_rs_full_i,
    .lsu_si_disp_req_o,
    .lsu_si_disp_req_valid_o,
    .lsu_si_disp_req_ready_i,
    .lsu_rs_disp_reqs_o,
    .lsu_rs_disp_req_valid_o,
    .lsu_rs_disp_req_ready_i,
    .lsu_rs_disp_rsp_i,
    .lsu_rs_full_i,
    .csr_disp_req_o,
    .csr_disp_req_valid_o,
    .csr_disp_req_ready_i,
    .fpu_si_disp_req_o,
    .fpu_si_disp_req_valid_o,
    .fpu_si_disp_req_ready_i,
    .fpu_rs_disp_reqs_o,
    .fpu_rs_disp_req_valid_o,
    .fpu_rs_disp_req_ready_i,
    .fpu_rs_disp_rsp_i,
    .fpu_rs_full_i,
    .acc_req_o,
    .acc_disp_req_valid_o,
    .acc_disp_req_ready_i,
    .disp_buffers_empty_o,
    .restart_i,
    .frep_mem_cons_mode_i,
    .refcnt_disp_req_o
  );

endmodule
