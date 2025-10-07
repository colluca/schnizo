// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Giulio Ferraro <gferraro@student.ethz.ch>
// Description: Accelerator interface wrapper for the Schnizo Core.
//  This module wraps around a user-defined accelerator and provides an interface
//  compatible with the Schnizo Core. It handles the valid/ready handshake and
//  passes through the operands and results.

import schnizo_pkg::*; 
import spatz_pkg::*;

module schnizo_acc #(
  parameter int unsigned XLEN        = 32,
  parameter bit          HasBranch   = 1'b1,
  parameter type         issue_req_t = logic,
  parameter type         instr_tag_t = logic
)
(
  input  logic            clk_i,
  input  logic            rst_i,
  input  issue_req_t      issue_req_i,
  input  logic            issue_req_valid_i,
  output logic            issue_req_ready_o,
  output logic [XLEN-1:0] result_o,
  /// Set if the comparison is true
  output logic            compare_res_o,
  output instr_tag_t      tag_o,
  output logic            result_valid_o,
  input  logic            result_ready_i,
  output logic            busy_o
);









endmodule
