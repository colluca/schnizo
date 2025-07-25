// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: The scoreboard module which checks for RAW and WAW conflicts

`include "common_cells/registers.svh"

module schnizo_scoreboard import schnizo_pkg::*; #(
  /// Size of both int and fp register file
  parameter int unsigned RegAddrSize = 5,
  parameter type         instr_dec_t = logic
) (
  input  logic       clk_i,
  input  logic       rst_i,
  // The decoded instruction which we should check the conflicts for.
  // Checking is performed in combinatorial manners thus we check even for invalid instructions.
  input  instr_dec_t instr_dec_i,
  output logic       operands_ready_o,
  output logic       destination_ready_o,
  input  logic       dispatched_i,
  // Register write back snooping
  input  logic                  write_enable_gpr_i,
  input  logic[RegAddrSize-1:0] waddr_gpr_i,
  input  logic                  write_enable_fpr_i,
  input  logic[RegAddrSize-1:0] waddr_fpr_i
);
  // The scoreboard keeps track of RAW and WAW dependencies.
  // It marks each register busy if an ongoing instruction will write back into it.
  // There are two separate scoreboards for each register file.
  // sbi for the integer and sbf for the floating point register, respectively.
  logic [2**RegAddrSize-1:0] sbi_d, sbi_q, sbf_d, sbf_q;
  `FFAR(sbi_q, sbi_d, '0, clk_i, rst_i)
  `FFAR(sbf_q, sbf_d, '0, clk_i, rst_i)

  // This checks the scoreboard for RAW conflicts using the decoded register addresses.
  // These addresses and the rx_is_fp signals default to zero. If a register is not used,
  // any lookup will check x0 which is always ready (hardwired to zero value, read only).
  always_comb begin : sb_raw_check
    logic op_a_has_raw, op_b_has_raw, op_c_has_raw;
    op_a_has_raw = instr_dec_i.rs1_is_fp ? sbf_q[instr_dec_i.rs1] : sbi_q[instr_dec_i.rs1];
    op_b_has_raw = instr_dec_i.rs2_is_fp ? sbf_q[instr_dec_i.rs2] : sbi_q[instr_dec_i.rs2];
    // The fused FP instruction have three source registers and the third one can only access
    // the FP regfile. For any other instruction operand c is always ready.
    op_c_has_raw = instr_dec_i.use_imm_as_rs3 ? sbf_q[instr_dec_i.imm[RegAddrSize-1:0]] :
                                                1'b0;
    operands_ready_o = ~(op_a_has_raw | op_b_has_raw | op_c_has_raw);
  end

  // Check that there is no WAW dependency to the destination register.
  always_comb begin : sb_waw_check
    logic dest_has_waw;
    logic dest_is_written;

    dest_has_waw = instr_dec_i.rd_is_fp  ? sbf_q[instr_dec_i.rd]  : sbi_q[instr_dec_i.rd];

    // Optimization: if the register is committed in this cycle, the destination is ready.
    // TODO: Problem: If the new instruction writes combinatorially, then we have a clash!
    dest_is_written = 1'b0;
    if (write_enable_fpr_i && instr_dec_i.rd_is_fp) begin
      if (waddr_fpr_i == instr_dec_i.rd) begin
        dest_is_written = 1'b1;
      end
    end

    destination_ready_o = ~dest_has_waw | dest_is_written;
  end

  logic is_single_cycle;
  always_comb begin : sb_disp_wb_update
    sbi_d = sbi_q;
    sbf_d = sbf_q;

    // Remove the reservation when a write back happens
    if (write_enable_gpr_i) begin
      sbi_d[waddr_gpr_i] = 1'b0;
    end
    if (write_enable_fpr_i) begin
      sbf_d[waddr_fpr_i] = 1'b0;
    end

    // Place a reservation if dispatched. In case there is no write, the register address
    // and rd_is_fp signal defaults to all zero. Thus we place a reservation in gpr x0.
    // However, this is hardwired to zero and thus it is always valid.
    // Any reservation for x0 is reset.
    //
    // Do not place a reservation if we have a write back in the same cycle.
    // Any ALU and CSR instruction is single cycle.

    // TODO: Improve this to snoop the actual write back handshake.
    // TODO: CAN WE SWITCH THE RESERVATION PLACING AND THE CLEARING?
    // We need to now which instruction retires. Otherwise we could clear the reservation of a
    // dispatched instruction with the write back of a previous instruction.

    is_single_cycle = instr_dec_i.fu inside {schnizo_pkg::ALU,
                                             schnizo_pkg::CSR,
                                             schnizo_pkg::CTRL_FLOW};
    if (dispatched_i && !is_single_cycle) begin
      if (instr_dec_i.rd_is_fp) begin
        sbf_d[instr_dec_i.rd] = 1'b1;
      end else begin
        sbi_d[instr_dec_i.rd] = 1'b1;
      end
    end
    sbi_d[0] = 1'b0; // x0 is always valid
    // fp0 is a regular register
  end
endmodule
