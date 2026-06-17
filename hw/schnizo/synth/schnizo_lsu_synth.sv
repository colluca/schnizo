// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnizo_lsu_synth #(
) (
  input  logic                                  clk_i,
  input  logic                                  rst_i,

  // Instruction stream
  input  schnizo_synth_pkg::issue_req_t         issue_req_i,
  input  logic                                  issue_req_valid_i,
  input  logic                                  issue_commit_i,
  output logic                                  issue_req_ready_o,
  
  output logic [schnizo_synth_pkg::DataWidth-1:0] result_o,
  output schnizo_pkg::instr_tag_t               tag_o,
  output logic                                  result_error_o,
  output logic                                  result_valid_o,
  input  logic                                  result_ready_i,

  output logic                                  busy_o,
  output logic                                  empty_o,
  output logic                                  addr_misaligned_o,

  // LSU memory interface
  output schnizo_synth_pkg::data_req_t          data_req_o,
  input  schnizo_synth_pkg::data_rsp_t          data_rsp_i,

  // CAQ interface
  input  logic [schnizo_synth_pkg::AddrWidth-1:0] caq_addr_i,
  input  logic                                  caq_track_write_i,
  input  logic                                  caq_req_valid_i,
  output logic                                  caq_req_ready_o,
  input  logic                                  caq_rsp_valid_i,
  output logic                                  caq_rsp_valid_o
);

  schnizo_lsu #(
    .XLEN                (schnizo_synth_pkg::XLEN),
    .issue_req_t         (schnizo_synth_pkg::issue_req_t),
    .AddrWidth           (schnizo_synth_pkg::AddrWidth),
    .DataWidth           (schnizo_synth_pkg::DataWidth),
    .dreq_t              (schnizo_synth_pkg::data_req_t),
    .drsp_t              (schnizo_synth_pkg::data_rsp_t),
    .tag_t               (schnizo_pkg::instr_tag_t),
    .NumOutstandingMem   (schnizo_synth_pkg::NumIntOutstandingMem),
    .NumOutstandingLoads (schnizo_synth_pkg::NumIntOutstandingLoads),
    .Caq                 ('0),
    .CaqDepth            (8),
    .CaqTagWidth         (16),
    .CaqRespSrc          ('0),
    .CaqRespTrackSeq     ('0)
  ) i_lsu (
    .clk_i,
    .rst_i,
    .issue_req_i,
    .issue_req_valid_i,
    .issue_commit_i,
    .issue_req_ready_o,
    .result_o,
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
