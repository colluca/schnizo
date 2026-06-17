// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnizo_alu_synth #(
  parameter bit          HasBranch     = 1'b1,
  parameter bit          HasMultiplier = 1'b0
) (
  input  logic                                  clk_i,
  input  logic                                  rst_i,

  input  schnizo_synth_pkg::issue_req_t         issue_req_i,
  input  logic                                  issue_req_valid_i,
  output logic                                  issue_req_ready_o,
  
  output logic [schnizo_synth_pkg::XLEN-1:0]                       result_o,
  output logic                                  compare_res_o,
  output schnizo_pkg::instr_tag_t               tag_o,
  output logic                                  result_valid_o,
  input  logic                                  result_ready_i,
  output logic                                  busy_o
);

  schnizo_alu #(
    .XLEN          (schnizo_synth_pkg::XLEN),
    .HasBranch     (HasBranch),
    .HasMultiplier (HasMultiplier),
    .issue_req_t   (schnizo_synth_pkg::issue_req_t),
    .instr_tag_t   (schnizo_pkg::instr_tag_t)
  ) i_alu (
    .clk_i,
    .rst_i,
    // Trace port omitted for synthesis
    .trace_o         (), 
    .issue_req_i,
    .issue_req_valid_i,
    .issue_req_ready_o,
    .result_o,
    .compare_res_o,
    .tag_o,
    .result_valid_o,
    .result_ready_i,
    .busy_o
  );

endmodule
