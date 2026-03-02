// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Stefan Odermatt <soderma@ethz.ch>

module schnova_decoder import schnizo_pkg::*; #(
  parameter int unsigned XLEN        = 32,
  parameter bit          Xdma        = 0,
  parameter bit          Xfrep       = 1,
  /// Enable F Extension (single).
  parameter bit          RVF         = 1,
  /// Enable D Extension (double).
  parameter bit          RVD         = 0,
  parameter bit          XF16        = 0,
  parameter bit          XF16ALT     = 0,
  parameter bit          XF8         = 0,
  parameter bit          XF8ALT      = 0,
  parameter type         instr_dec_t = logic
) (
  // For assertions only.
  input logic                   clk_i,
  input logic                   rst_i,

  input  logic [31:0]           instr_fetch_data_i,
  input  logic                  instr_fetch_data_valid_i,
  input  fpnew_pkg::roundmode_e fpu_round_mode_i,
  input  fpnew_pkg::fmt_mode_t  fpu_fmt_mode_i,
  output logic                  instr_valid_o,
  output logic                  instr_illegal_o,
  output instr_dec_t            instr_dec_o
);

endmodule 