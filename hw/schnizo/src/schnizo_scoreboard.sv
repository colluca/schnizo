// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// TODO(colluca): what does this mean? Is it still valid?

`include "common_cells/registers.svh"

// Scoreboard of the Schnizo Core.
//
// Important: This module assumes that all functional units writing to the floating point register
//            file are multi cycle instructions! Otherwise an optimization would lead to wrongly
//            ordered commits.
module schnizo_scoreboard import schnizo_pkg::*; #(
  /// Size of both int and fp register file
  parameter int unsigned RegAddrSize = 5,
  parameter type         instr_dec_t = logic
) (
  input  logic       clk_i,
  input  logic       rst_i,
  // The decoded instruction which we should check the conflicts for.
  // Checking is performed in a combinatorial manner thus we check even for invalid instructions.
  input  instr_dec_t instr_dec_i,
  output logic       operands_ready_o,
  output logic       destination_ready_o,
  // If the following signals are asserted at least one register of the corresponding register
  // file is currently waiting on a result.
  output logic       fpr_busy_o,
  output logic       gpr_busy_o,
  output logic       vrf_busy_o,
  input  logic       dispatched_i,
  // Register write back snooping (GPR / FPR)
  input  logic                  write_enable_gpr_i,
  input  logic[RegAddrSize-1:0] waddr_gpr_i,
  input  logic                  write_enable_fpr_i,
  input  logic[RegAddrSize-1:0] waddr_fpr_i,
  // VRF retire snooping: cleared when the VFU completes an instruction writing to a vector reg
  input  logic                  write_enable_vrf_i,
  input  logic[RegAddrSize-1:0] waddr_vrf_i
);

  /////////////////
  // Scoreboards //
  /////////////////

  // The scoreboard keeps track of RAW and WAW dependencies.
  // It marks each register busy if an ongoing instruction will write back into it.
  // There are separate scoreboards for each register file.
  // sbi = integer, sbf = floating-point, sbv = vector.

  logic [2**RegAddrSize-1:0] sbi_d, sbi_q, sbf_d, sbf_q, sbv_d, sbv_q;

  `FFAR(sbi_q, sbi_d, '0, clk_i, rst_i)
  `FFAR(sbf_q, sbf_d, '0, clk_i, rst_i)
  `FFAR(sbv_q, sbv_d, '0, clk_i, rst_i)

  always_comb begin : sb_disp_wb_update
    sbi_d = sbi_q;
    sbf_d = sbf_q;
    sbv_d = sbv_q;

    // Place a reservation if dispatched. In case there is no write, the register address
    // and rd_is_fp/rd_is_vec signals default to all zero. Thus we place a reservation in
    // gpr x0 which is hardwired to zero and always valid; any reservation for x0 is reset.
    if (dispatched_i) begin
      if (instr_dec_i.rd_is_vec) begin
        sbv_d[instr_dec_i.rd] = 1'b1;
      end else if (instr_dec_i.rd_is_fp) begin
        sbf_d[instr_dec_i.rd] = 1'b1;
      end else begin
        sbi_d[instr_dec_i.rd] = 1'b1;
      end
    end

    // Remove the GPR reservation when a write back happens. This also catches the case of
    // instructions writing back in the same cycle (single cycle instruction like ALU, CTRL_FLOW
    // or CSR).
    if (write_enable_gpr_i) begin
      sbi_d[waddr_gpr_i] = 1'b0;
    end
    if (write_enable_fpr_i) begin
      sbf_d[waddr_fpr_i] = 1'b0;
    end
    // Remove the VRF reservation when the VFU retires (result valid/ready handshake fires).
    if (write_enable_vrf_i) begin
      sbv_d[waddr_vrf_i] = 1'b0;
    end

    // x0 is always valid
    sbi_d[0] = 1'b0;
    // v0 can be a real destination (mask register), so no forced clear for sbv[0]
    // fp0 is a regular register
  end

  // Check if any register is awaiting a write.
  assign fpr_busy_o = |sbf_q;
  assign gpr_busy_o = |sbi_q;
  assign vrf_busy_o = |sbv_q;

  //////////////////////
  // RAW dependencies //
  //////////////////////

  // Check the scoreboard for RAW conflicts using the decoded register addresses.
  // Addresses and the rx_is_fp/rx_is_vec signals default to zero. If a register is not used,
  // any lookup checks x0 (always ready) or v0/f0.

  logic op_a_has_raw, op_b_has_raw, op_c_has_raw, op_d_has_raw;

  assign op_a_has_raw = instr_dec_i.rs1_is_vec ? sbv_q[instr_dec_i.rs1] :
                        instr_dec_i.rs1_is_fp  ? sbf_q[instr_dec_i.rs1] :
                                                  sbi_q[instr_dec_i.rs1];
  assign op_b_has_raw = instr_dec_i.rs2_is_vec ? sbv_q[instr_dec_i.rs2] :
                        instr_dec_i.rs2_is_fp  ? sbf_q[instr_dec_i.rs2] :
                                                  sbi_q[instr_dec_i.rs2];
  // The fused FP instructions have three source registers; the third can only access the FPR.
  // For any other instruction operand c is always ready.
  assign op_c_has_raw = instr_dec_i.use_imm_as_rs3 ? sbf_q[instr_dec_i.imm[RegAddrSize-1:0]] :
                        1'b0;
  // Accumulate instructions (e.g. vfmacc.vf) read rd as a source in addition to writing it.
  assign op_d_has_raw = instr_dec_i.use_rd_as_src ? (
                        instr_dec_i.rd_is_vec ? sbv_q[instr_dec_i.rd] :
                        instr_dec_i.rd_is_fp  ? sbf_q[instr_dec_i.rd] :
                                                sbi_q[instr_dec_i.rd]) :
                        1'b0;

  assign operands_ready_o = !(op_a_has_raw || op_b_has_raw || op_c_has_raw || op_d_has_raw);

  //////////////////////
  // WAW dependencies //
  //////////////////////

  // Check that there is no WAW dependency to the destination register.

  logic dest_has_waw;

  assign dest_has_waw = instr_dec_i.rd_is_vec ? sbv_q[instr_dec_i.rd] :
                        instr_dec_i.rd_is_fp  ? sbf_q[instr_dec_i.rd] :
                                                sbi_q[instr_dec_i.rd];
  assign destination_ready_o = !dest_has_waw;

endmodule
