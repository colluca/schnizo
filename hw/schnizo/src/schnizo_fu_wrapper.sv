// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: A wrapper for a functional unit to match the dispatch interface.

`include "common_cells/registers.svh"

module schnizo_fu_wrapper import schnizo_pkg::*; #(
  parameter int unsigned XLEN         = 32,
  parameter type         issue_req_t  = logic,
  parameter type         result_t     = logic,
  parameter type         result_tag_t = logic,
  parameter fu_t         Fu,

  /// ALU specific
  // Enable the branch comparison logic
  parameter bit          HasBranch = 0,

  /// LSU specific
  // Physical Address width of the core.
  parameter int unsigned AddrWidth = 48,
  // Data width of memory interface.
  parameter int unsigned DataWidth = 64,
  // Data port request type.
  parameter type         dreq_t    = logic,
  // Data port response type.
  parameter type         drsp_t    = logic,
  parameter int unsigned NumIntOutstandingLoads = 0,
  parameter int unsigned NumIntOutstandingMem   = 0,
  // Consistency Address Queue (CAQ) parameters
  parameter bit          CaqEn       = 0,
  parameter int unsigned CaqDepth    = 0,
  parameter int unsigned CaqTagWidth = 0,
  // Derived parameter *Do not override*
  parameter type         addr_t = logic [AddrWidth-1:0],

  /// LSU and FPU specific *Do not override*
  parameter int unsigned FLEN         = DataWidth,

  /// FPU specific
  parameter fpnew_pkg::fpu_implementation_t FPUImplementation = '0,
  parameter bit          RVF     = 0,
  parameter bit          RVD     = 0,
  parameter bit          XF16    = 0,
  parameter bit          XF16ALT = 0,
  parameter bit          XF8     = 0,
  parameter bit          XF8ALT  = 0,
  // Vectors are not implemented! Here for compatibility with Snitch.
  parameter bit          XFVEC   = 0,
  parameter bit          RegisterFPUIn  = 0,
  parameter bit          RegisterFPUOut = 0
) (
  input  logic        clk_i,
  input  logic        rst_i,
  input  issue_req_t  issue_req_i,
  input  logic        issue_req_valid_i,
  output logic        issue_req_ready_o,

  // LSU memory interface
  output dreq_t       lsu_data_req_o,
  input  drsp_t       lsu_data_rsp_i,
  output logic        lsu_empty_o,
  output logic        lsu_addr_misaligned_o,

  // Consistency address queue interface
  input  addr_t       caq_addr_i,
  input  logic        caq_is_fp_store_i,
  input  logic        caq_req_valid_i,
  output logic        caq_req_ready_o,
  // Answer from other LSU
  input  logic        caq_rsp_valid_i,
  output logic        caq_rsp_valid_o,

  // FPU signals
  input  logic [31:0]        hart_id_i,
  output fpnew_pkg::status_t fpu_status_o,

  // Write back port
  output result_t     result_o,
  output result_tag_t result_tag_o,
  output logic        result_valid_o,
  input  logic        result_ready_i,

  // Asserted if valid data is in flight
  output logic        busy_o
);
  // ---------------------------
  // ALU
  // ---------------------------
  if (Fu == schnizo_pkg::ALU) begin : gen_alu
    schnizo_alu #(
      .XLEN       (XLEN),
      .HasBranch  (HasBranch),
      .issue_req_t(issue_req_t),
      .instr_tag_t(result_tag_t)
    ) i_rs_alu (
      .clk_i,
      .rst_i,
      .issue_req_i      (issue_req_i),
      .issue_req_valid_i(issue_req_valid_i),
      .issue_req_ready_o(issue_req_ready_o),
      .result_o         (result_o.result),
      .compare_res_o    (result_o.compare_res),
      .tag_o            (result_tag_o),
      .result_valid_o   (result_valid_o),
      .result_ready_i   (result_ready_i),
      .busy_o           (busy_o)
    );
  end // no signals to tie off for ALU

  // ---------------------------
  // LSU
  // ---------------------------
  if (Fu == schnizo_pkg::LOAD || Fu == schnizo_pkg::STORE) begin : gen_lsu
    schnizo_lsu #(
      .XLEN               (XLEN),
      .issue_req_t        (issue_req_t),
      .result_tag_t       (result_tag_t),
      .AddrWidth          (AddrWidth),
      .DataWidth          (DataWidth),
      .dreq_t             (dreq_t),
      .drsp_t             (drsp_t),
      .tag_t              (result_tag_t),
      .NumOutstandingMem  (NumIntOutstandingMem),
      .NumOutstandingLoads(NumIntOutstandingLoads),
      .Caq                (CaqEn),
      .CaqDepth           (CaqDepth),
      .CaqTagWidth        (CaqTagWidth),
      .CaqRespSrc         (1'b0),
      .CaqRespTrackSeq    (1'b0)
    ) i_rs_lsu (
      .clk_i,
      .rst_i,
      // Instruction stream
      .issue_req_i      (issue_req_i),
      .issue_req_valid_i(issue_req_valid_i),
      .issue_req_ready_o(issue_req_ready_o),
      .result_o         (result_o),
      .tag_o            (result_tag_o),
      .result_error_o   (), // ignored for now
      .result_valid_o   (result_valid_o),
      .result_ready_i   (result_ready_i),
      .busy_o           (busy_o),
      .empty_o          (lsu_empty_o),
      .addr_misaligned_o(lsu_addr_misaligned_o),
      // LSU memory interface
      .data_req_o(lsu_data_req_o),
      .data_rsp_i(lsu_data_rsp_i),
      // Consistency address queue snoop channel.
      .caq_addr_i       (caq_addr_i),
      .caq_track_write_i(caq_is_fp_store_i),
      .caq_req_valid_i  (caq_req_valid_i),
      .caq_req_ready_o  (caq_req_ready_o),
      // Incoming CAQ response snoop channel.
      .caq_rsp_valid_i  (caq_rsp_valid_i),
      // Outgoing CAQ response snoop channel.
      .caq_rsp_valid_o  (caq_rsp_valid_o)
    );
  end else begin : gen_tieoff_lsu
    assign lsu_addr_misaligned_o = 1'b0;
    assign lsu_empty_o = 1'b0;
    assign caq_rsp_valid_o = 1'b0;
    assign caq_req_ready_o = 1'b0;
  end

  // ---------------------------
  // FPU
  // ---------------------------
  if (Fu == schnizo_pkg::FPU) begin : gen_fpu
    schnizo_fpu #(
      .FPUImplementation(FPUImplementation),
      .RVF              (RVF),
      .RVD              (RVD),
      .XF16             (XF16),
      .XF16ALT          (XF16ALT),
      .XF8              (XF8),
      .XF8ALT           (XF8ALT),
      .XFVEC            (XFVEC),
      .FLEN             (FLEN),
      .RegisterFPUIn    (RegisterFPUIn),
      .RegisterFPUOut   (RegisterFPUOut),
      .issue_req_t      (issue_req_t),
      .instr_tag_t      (result_tag_t)
    ) i_rs_fpu (
      .clk_i,
      .rst_ni           (~rst_i),
      .hart_id_i        (hart_id_i),
      .issue_req_i      (issue_req_i),
      .issue_req_valid_i(issue_req_valid_i),
      .issue_req_ready_o(issue_req_ready_o),
      .result_o         (result_o),
      .result_valid_o   (result_valid_o),
      .result_ready_i   (result_ready_i),
      .status_o         (fpu_status_o),
      .tag_o            (result_tag_o),
      .busy_o           (busy_o)
    );

  end // no signals to tie off for FPU

endmodule
