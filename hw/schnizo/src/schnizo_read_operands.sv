// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: The read operand module which accesses the RF.
// All read values are stored in OpLen bits (defined by fu_data_t) and are
// NOT sign extended! When computing values with the operands, make sure to use
// only the relevant bits!

module schnizo_read_operands import schnizo_pkg::*; #(
  parameter int unsigned XLEN,
  parameter int unsigned FLEN,
  parameter int unsigned RegAddrSize,
  parameter int unsigned NrIntReadPorts,
  parameter int unsigned NrFpReadPorts,
  parameter type         instr_dec_t = logic,
  parameter type         fu_data_t = logic
) (
  input  logic [XLEN-1:0] pc_i,
  input  instr_dec_t      instr_dec_i,
  input  logic [XLEN-1:0]     instr_fetch_data_i, // Raw instruction bits

  output logic [NrIntReadPorts-1:0][RegAddrSize-1:0] gpr_raddr_o,
  input  logic [NrIntReadPorts-1:0][XLEN-1:0]        gpr_rdata_i,
  output logic [NrFpReadPorts-1:0][RegAddrSize-1:0]  fpr_raddr_o,
  input  logic [NrFpReadPorts-1:0][FLEN-1:0]         fpr_rdata_i,

  output fu_data_t        fu_data_o
);

  always_comb begin
    fu_data_o              = '0;
    fu_data_o.fu           = instr_dec_i.fu;
    fu_data_o.raw_instr   =  instr_fetch_data_i; // Pass the raw instruction to the FU (needed by Spatz)
    fu_data_o.alu_op       = instr_dec_i.alu_op;
    fu_data_o.lsu_op       = instr_dec_i.lsu_op;
    fu_data_o.csr_op       = instr_dec_i.csr_op;
    fu_data_o.fpu_op       = instr_dec_i.fpu_op;
    fu_data_o.lsu_size     = instr_dec_i.lsu_size;
    fu_data_o.fpu_rnd_mode = instr_dec_i.fpu_rnd_mode;
    fu_data_o.fpu_fmt_src  = instr_dec_i.fpu_fmt_src;
    fu_data_o.fpu_fmt_dst  = instr_dec_i.fpu_fmt_dst;

    // Set the addresses
    gpr_raddr_o[0] = instr_dec_i.rs1;
    fpr_raddr_o[0] = instr_dec_i.rs1;
    gpr_raddr_o[1] = instr_dec_i.rs2;
    fpr_raddr_o[1] = instr_dec_i.rs2;
    fpr_raddr_o[2] = instr_dec_i.imm[RegAddrSize-1:0];

    // Operand A
    // Select the source.
    // - JAL and JALR use the PC as operand A.
    // - CSRRxI use the rs1 address as operand A.
    if (instr_dec_i.use_pc_as_op_a) begin
      fu_data_o.operand_a[XLEN-1:0] = pc_i;
    end else if (instr_dec_i.use_rs1addr_as_op_a) begin
      fu_data_o.operand_a[XLEN-1:0] = {{XLEN-5{1'b0}}, instr_dec_i.rs1[4:0]};
    end else begin
      if (instr_dec_i.rs1_is_fp) begin
        fu_data_o.operand_a[FLEN-1:0] = fpr_rdata_i[0];
      end else begin
        fu_data_o.operand_a[XLEN-1:0] = gpr_rdata_i[0];
      end
    end

    // Operand B
    // We must select the correct operand b value based on the FU and the instruction.
    // - ALU can have the immediate value as operand b.
    // - For all other FUs the use_imm_as_op_b is set (if a imm is selected) but must be ignored.
    if ((instr_dec_i.fu == schnizo_pkg::ALU || instr_dec_i.fu == schnizo_pkg::CTRL_FLOW) &&
        instr_dec_i.use_imm_as_op_b && !instr_dec_i.is_branch) begin
      fu_data_o.operand_b[XLEN-1:0] = instr_dec_i.imm;
    end else begin
      if (instr_dec_i.rs2_is_fp) begin
        fu_data_o.operand_b[FLEN-1:0] = fpr_rdata_i[1];
      end else begin
        fu_data_o.operand_b[XLEN-1:0] = gpr_rdata_i[1];
      end
    end

    // Operand C - reuses imm field
    if (instr_dec_i.use_imm_as_rs3) begin
      fu_data_o.imm[FLEN-1:0] = fpr_rdata_i[2];
    end else begin
      fu_data_o.imm[XLEN-1:0] = instr_dec_i.imm;
    end
  end

endmodule
