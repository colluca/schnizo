// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

// The dispatcher module.
//
// Accesses the RMT to augment the dispatch requests with the relevant data and routes the
// dispatch requests to the different functional units. It selects the FU type based on the
// decoded instruction. If more than one FU of the same type is available, it further selects the
// specific FU of that type to dispatch the instruction to.
// It itself instantiates the RMT and updates it based on the dispatch and write back information.
module schnova_dispatcher import schnova_pkg::*; #(
  /// If a freelist based physical register reclamation strategy is used
  /// or a refernce counting based strategy.
  parameter bit UseFreeList = 1,
  parameter int unsigned PipeWidth   = 1,
  parameter int unsigned XLEN        = 1,
  parameter bit          XFREPO      = 1,
  /// Size of both int and fp register file
  parameter int unsigned RegAddrSize = 5,
  parameter int unsigned NofAlus     = 1,
  parameter int unsigned NofLsus     = 1,
  parameter int unsigned NofFpus     = 1,
  parameter int unsigned NofAluBufEntries = 32,
  parameter int unsigned NofLsuBufEntries = 32,
  parameter int unsigned NofFpuBufEntries = 32,
  parameter int unsigned RobTagWidth = 1,
  parameter type         instr_dec_t = logic,
  parameter type         instr_tag_t = logic,
  parameter type         csr_disp_req_t = logic,
  parameter type         alu_si_disp_req_t = logic,
  parameter type         lsu_si_disp_req_t = logic,
  parameter type         fpu_si_disp_req_t = logic,
  parameter type         alu_rs_disp_req_t = logic,
  parameter type         lsu_rs_disp_req_t = logic,
  parameter type         fpu_rs_disp_req_t = logic,
  parameter type         disp_rsp_t  = logic,
  parameter type         refcnt_req_t = logic,
  parameter type         producer_id_t = logic,
  parameter type         rs_id_t       = logic,
  parameter type         reg_map_t = logic,
  parameter type         fu_data_t   = logic,
  parameter type         acc_req_t   = logic,
  parameter type         sb_disp_data_t = logic
) (
  input  logic         clk_i,
  input  logic         rst_i,
  input  logic         en_superscalar_i,
  // Handshake to dispatch instruction consisting of instr_dec_i and instr_fu_data_i
  input  instr_dec_t [PipeWidth-1:0] instr_dec_i,
  input  fu_data_t   [PipeWidth-1:0] instr_fu_data_i,
  input  logic [32*PipeWidth-1:0]    instr_fetch_data_i,
  input  logic                       dispatch_valid_i,
  output logic                       dispatch_ready_o,
  input  logic                       instr_exec_commit_i,

  input  logic [PipeWidth-1:0]         instr_valid_i,
  input  logic [PipeWidth-1:0]         instr_rename_gpr_valid_i,
  input  logic [$clog2(PipeWidth):0]   instr_rename_gpr_count_i,
  input  logic [PipeWidth-1:0]         instr_rename_fpr_valid_i,
  input  logic [$clog2(PipeWidth):0]   instr_rename_fpr_count_i,

  // From rename stage
  input  reg_map_t [PipeWidth-1:0]             reg_map_i,

  // From/to ROB
  output logic                                 first_instr_dispatched_o,
  input logic [PipeWidth-1:0][RobTagWidth-1:0] rob_idx_i,
  // Each FU has a response which must be valid at dispatch request handshake.
  // ALU
  output alu_si_disp_req_t               alu_si_disp_req_o,
  output logic                           alu_si_disp_req_valid_o,
  input  logic                           alu_si_disp_req_ready_i,
  output alu_rs_disp_req_t [NofAlus-1:0] alu_rs_disp_reqs_o,
  output logic      [NofAlus-1:0]        alu_rs_disp_req_valid_o,
  input  logic      [NofAlus-1:0]        alu_rs_disp_req_ready_i,
  input  disp_rsp_t [NofAlus-1:0]        alu_rs_disp_rsp_i,
  input  logic      [NofAlus-1:0]        alu_rs_full_i,

  // LSU
  output lsu_si_disp_req_t               lsu_si_disp_req_o,
  output logic                           lsu_si_disp_req_valid_o,
  input  logic                           lsu_si_disp_req_ready_i,
  output lsu_rs_disp_req_t [NofLsus-1:0] lsu_rs_disp_reqs_o,
  output logic      [NofLsus-1:0]        lsu_rs_disp_req_valid_o,
  input  logic      [NofLsus-1:0]        lsu_rs_disp_req_ready_i,
  input  disp_rsp_t [NofLsus-1:0]        lsu_rs_disp_rsp_i,
  input  logic      [NofLsus-1:0]        lsu_rs_full_i,

  // Handshake to the CSR FU. There is no response as it does not have a reservation station.
  output csr_disp_req_t                  csr_disp_req_o,
  output logic                           csr_disp_req_valid_o,
  input  logic                           csr_disp_req_ready_i,

  // FPU
  output fpu_si_disp_req_t               fpu_si_disp_req_o,
  output logic                           fpu_si_disp_req_valid_o,
  input  logic                           fpu_si_disp_req_ready_i,
  output fpu_rs_disp_req_t [NofFpus-1:0] fpu_rs_disp_reqs_o,
  output logic      [NofFpus-1:0]        fpu_rs_disp_req_valid_o,
  input  logic      [NofFpus-1:0]        fpu_rs_disp_req_ready_i,
  input  disp_rsp_t [NofFpus-1:0]        fpu_rs_disp_rsp_i,
  input  logic      [NofFpus-1:0]        fpu_rs_full_i,

  // Handshake to the accelerator interface
  output acc_req_t                       acc_req_o,
  output logic                           acc_disp_req_valid_o,
  input  logic                           acc_disp_req_ready_i,
  // The accelerator response is routed directly to the write back.
  output logic                           disp_buffers_empty_o,
  // RS control signals
  // Asserted if the RSS are cleared synchronously.
  input  logic                           restart_i,
  // Memory consistency mode during FREP loop
  input frep_mem_cons_mode_e             frep_mem_cons_mode_i,
  // To refcount
  output refcnt_req_t [PipeWidth-1:0]    refcnt_disp_req_o
);
  // Asserted when all the valid instruction for the current fetch block
  // are dispatched in this cycle
  logic dispatched;

  /////////////////////////////
  // Single Issue Dispatcher //
  /////////////////////////////

  logic si_dispatched;

  schnova_si_dispatcher # (
    .XLEN(XLEN),
    .NofAlus(NofAlus),
    .NofLsus(NofLsus),
    .NofFpus(NofFpus),
    .instr_dec_t(instr_dec_t),
    .instr_tag_t(instr_tag_t),
    .alu_si_disp_req_t(alu_si_disp_req_t),
    .lsu_si_disp_req_t(lsu_si_disp_req_t),
    .fpu_si_disp_req_t(fpu_si_disp_req_t),
    .csr_disp_req_t   (csr_disp_req_t),
    .acc_req_t        (acc_req_t),
    .disp_rsp_t   (disp_rsp_t),
    .producer_id_t(producer_id_t),
    .rs_id_t(rs_id_t),
    .reg_map_t(reg_map_t),
    .fu_data_t(fu_data_t)
  ) i_si_dispatcher (
    .clk_i,
    .rst_i,
    // Instruction data
    .instr_dec_i(instr_dec_i[0]),
    .instr_fu_data_i(instr_fu_data_i[0]),
    .instr_fetch_data_i(instr_fetch_data_i[31:0]),
    .instr_valid_i(instr_valid_i[0]),
    .dispatch_valid_i(dispatch_valid_i),
    .dispatched_o(si_dispatched),
    .instr_exec_commit_i(instr_exec_commit_i),
    .reg_map_i(reg_map_i[0]),
    // ALU dispatch request and responses
    .alu_si_disp_req_o(alu_si_disp_req_o),
    .alu_si_disp_req_valid_o(alu_si_disp_req_valid_o),
    .alu_si_disp_req_ready_i(alu_si_disp_req_ready_i),
    // LSU dispatch request and responses
    .lsu_si_disp_req_o(lsu_si_disp_req_o),
    .lsu_si_disp_req_valid_o(lsu_si_disp_req_valid_o),
    .lsu_si_disp_req_ready_i(lsu_si_disp_req_ready_i),
    // FPU dispatch request and responses
    .fpu_si_disp_req_o(fpu_si_disp_req_o),
    .fpu_si_disp_req_valid_o(fpu_si_disp_req_valid_o),
    .fpu_si_disp_req_ready_i(fpu_si_disp_req_ready_i),
    // CSR dispatch request and responses
    .csr_disp_req_o(csr_disp_req_o),
    .csr_disp_req_valid_o(csr_disp_req_valid_o),
    .csr_disp_req_ready_i(csr_disp_req_ready_i),
    // ACC dispatch request and responses
    .acc_req_o(acc_req_o),
    .acc_disp_req_valid_o(acc_disp_req_valid_o),
    .acc_disp_req_ready_i(acc_disp_req_ready_i)
  );

  ////////////////////////////
  // Multi Issue Dispatcher //
  ////////////////////////////
  logic rs_dispatched;

  if (XFREPO) begin : gen_rs_dispatcher
    schnova_rs_dispatcher #(
      /// If a freelist based physical register reclamation strategy is used
      /// or a refernce counting based strategy.
      .UseFreeList(UseFreeList),
      .PipeWidth(PipeWidth),
      .XLEN(XLEN),
      .NofAlus(NofAlus),
      .NofLsus(NofLsus),
      .NofFpus(NofFpus),
      .NofAluBufEntries(NofAluBufEntries),
      .NofLsuBufEntries(NofLsuBufEntries),
      .NofFpuBufEntries(NofFpuBufEntries),
      .RobTagWidth(RobTagWidth),
      .instr_dec_t(instr_dec_t),
      .instr_tag_t(instr_tag_t),
      .alu_rs_disp_req_t(alu_rs_disp_req_t),
      .lsu_rs_disp_req_t(lsu_rs_disp_req_t),
      .fpu_rs_disp_req_t(fpu_rs_disp_req_t),
      .disp_rsp_t(disp_rsp_t),
      .refcnt_req_t(refcnt_req_t),
      .reg_map_t(reg_map_t),
      .fu_data_t(fu_data_t)
    ) i_rs_dispatcher (
      .clk_i,
      .rst_i,
      .en_superscalar_i(en_superscalar_i),
      // Handshake to dispatch instruction consisting of instr_dec_i and instr_fu_data_i
      .instr_dec_i(instr_dec_i),
      .instr_fu_data_i(instr_fu_data_i),
      .instr_fetch_data_i(instr_fetch_data_i),
      .dispatch_valid_i(dispatch_valid_i),
      // Asserted inf all the instructions of this fetch block have been successfully dispatched
      // in this cycle
      .dispatched_o(rs_dispatched),
      .instr_exec_commit_i(instr_exec_commit_i),
      .instr_valid_i(instr_valid_i),
      .instr_rename_gpr_valid_i(instr_rename_gpr_valid_i),
      .instr_rename_gpr_count_i(instr_rename_gpr_count_i),
      .instr_rename_fpr_valid_i(instr_rename_fpr_valid_i),
      .instr_rename_fpr_count_i(instr_rename_fpr_count_i),
      // From rename stage
      .reg_map_i(reg_map_i),
      // From/to ROB
      .first_instr_dispatched_o(first_instr_dispatched_o),
      .rob_idx_i(rob_idx_i),
      // Each FU has a response which must be valid at dispatch request handshake.
      // ALU
      .alu_rs_disp_reqs_o(alu_rs_disp_reqs_o),
      .alu_rs_disp_req_valid_o(alu_rs_disp_req_valid_o),
      .alu_rs_disp_req_ready_i(alu_rs_disp_req_ready_i),
      .alu_rs_disp_rsp_i(alu_rs_disp_rsp_i),
      .alu_rs_full_i(alu_rs_full_i),
      // LSU
      .lsu_rs_disp_reqs_o(lsu_rs_disp_reqs_o),
      .lsu_rs_disp_req_valid_o(lsu_rs_disp_req_valid_o),
      .lsu_rs_disp_req_ready_i(lsu_rs_disp_req_ready_i),
      .lsu_rs_disp_rsp_i(lsu_rs_disp_rsp_i),
      .lsu_rs_full_i(lsu_rs_full_i),
      // FPU
      .fpu_rs_disp_reqs_o(fpu_rs_disp_reqs_o),
      .fpu_rs_disp_req_valid_o(fpu_rs_disp_req_valid_o),
      .fpu_rs_disp_req_ready_i(fpu_rs_disp_req_ready_i),
      .fpu_rs_disp_rsp_i(fpu_rs_disp_rsp_i),
      .fpu_rs_full_i(fpu_rs_full_i),
      // The accelerator response is routed directly to the write back.
      .disp_buffers_empty_o(disp_buffers_empty_o),
      // RS control signals
      // Asserted if the RSS are cleared synchronously.
      .restart_i(restart_i),
      // Memory consistency mode during FREP loop
      .frep_mem_cons_mode_i(frep_mem_cons_mode_i),
      // To refcount
      .refcnt_disp_req_o(refcnt_disp_req_o)
    );
  end else begin : gen_no_rs_dispatcher
    assign rs_dispatched            = 1'b0;
    assign first_instr_dispatched_o = 1'b0;
    assign alu_rs_disp_reqs_o       = '0;
    assign alu_rs_disp_req_valid_o  = '0;
    assign lsu_rs_disp_reqs_o       = '0;
    assign lsu_rs_disp_req_valid_o  = '0;
    assign fpu_rs_disp_reqs_o       = '0;
    assign fpu_rs_disp_req_valid_o  = '0;
    assign disp_buffers_empty_o     = 1'b0;
    assign refcnt_disp_req_o        = 1'b0;
  end

  // All instructions are successfully dispatched if all the instructions are being dispatched in this cycle
  // that are valid in the first place
  assign dispatched = en_superscalar_i ? rs_dispatched
                                       : si_dispatched;

  // Signal back the dispatch
  assign dispatch_ready_o = dispatched;

endmodule
