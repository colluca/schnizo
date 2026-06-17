// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnizo_alu_lsu_synth #(
  parameter int unsigned NofResPorts         = 2,
  parameter bit          HasBranch             = 1'b1,
  parameter bit          HasMultiplier         = 1'b0,
  parameter bit          PostIncrement = 1'b0
) (
  input  logic                                          clk_i,
  input  logic                                          rst_i,

  input  schnizo_synth_pkg::issue_req_two_tags_t        issue_req_i,
  input  logic                                          issue_req_valid_i,
  input  logic                                          issue_commit_i,
  output logic                                          issue_req_ready_o,
  
  output schnizo_synth_pkg::alu_lsu_result_t [NofResPorts-1:0] result_o,
  output logic                                          compare_res_o,
  output schnizo_pkg::instr_tag_t        [NofResPorts-1:0] tag_o,
  output logic                                          result_error_o,
  output logic                           [NofResPorts-1:0] result_valid_o,
  input  logic                           [NofResPorts-1:0] result_ready_i,
  
  output logic                                          busy_o,
  output logic                                          empty_o,
  output logic                                          addr_misaligned_o,

  output schnizo_synth_pkg::data_req_t                  data_req_o,
  input  schnizo_synth_pkg::data_rsp_t                  data_rsp_i,

  input  logic [schnizo_synth_pkg::AddrWidth-1:0]       caq_addr_i,
  input  logic                                          caq_track_write_i,
  input  logic                                          caq_req_valid_i,
  output logic                                          caq_req_ready_o,
  input  logic                                          caq_rsp_valid_i,
  output logic                                          caq_rsp_valid_o
);

  schnizo_alu_lsu #(
    .alu_lsu_result_t    (schnizo_synth_pkg::alu_lsu_result_t),
    .alu_lsu_instr_tag_t (schnizo_pkg::instr_tag_t),
    .alu_lsu_issue_req_t (schnizo_synth_pkg::issue_req_two_tags_t),
    .fu_issue_req_t      (schnizo_synth_pkg::issue_req_t),
    .NofResPorts         (NofResPorts),
    .PostIncrement       (PostIncrement),
    .XLEN                (schnizo_synth_pkg::XLEN),
    .HasBranch           (HasBranch),
    .HasMultiplier       (HasMultiplier),
    .alu_res_val_t       (schnizo_synth_pkg::alu_res_val_t),
    .AddrWidth           (schnizo_synth_pkg::AddrWidth),
    .DataWidth           (schnizo_synth_pkg::DataWidth),
    .NumOutstandingMem   (schnizo_synth_pkg::NumIntOutstandingMem),
    .NumOutstandingLoads (schnizo_synth_pkg::NumIntOutstandingLoads),
    .Caq                 (0),
    .CaqDepth            (8),
    .CaqTagWidth         (16),
    .CaqRespSrc          (0),
    .CaqRespTrackSeq     (0),
    .dreq_t              (schnizo_synth_pkg::data_req_t),
    .drsp_t              (schnizo_synth_pkg::data_rsp_t)
  ) i_alu_lsu (
    .clk_i,
    .rst_i,
    .trace_o             (),
    .issue_req_i,
    .issue_req_valid_i,
    .issue_commit_i,
    .issue_req_ready_o,
    .result_o,
    .compare_res_o,
    .tag_o,
    .result_error_o,
    .result_valid_o,
    .result_ready_i,
    .busy_o,
    .empty_o,
    .addr_misaligned_o,
    .data_req_o,
    .data_rsp_i,
    .caq_addr_i,
    .caq_track_write_i,
    .caq_req_valid_i,
    .caq_req_ready_o,
    .caq_rsp_valid_i,
    .caq_rsp_valid_o
  );

endmodule
