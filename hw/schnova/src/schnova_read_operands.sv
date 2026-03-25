// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// The read operand module which accesses the RF.
//
// Produces addresses to access the RFs and packs the received data into the fu_data_t struct
// for the FUs.
// All read values are stored in OpLen bits (defined by fu_data_t) and are
// NOT sign extended! When computing values with the operands, make sure to use
// only the relevant bits!
module schnova_read_operands import schnizo_pkg::*; #(
  parameter int unsigned XLEN,
  parameter int unsigned FLEN,
  parameter int unsigned PipeWidth       = 1,
  parameter int unsigned RegAddrSize,
  parameter int unsigned NrIntReadPorts,
  parameter int unsigned NrFpReadPorts,
  parameter type         instr_dec_t = logic,
  parameter type         reg_map_t   = logic,
  parameter type         fu_data_t = logic
) (
  input  logic [XLEN-1:0] jump_pc_i,
  /// From decoder
  input  instr_dec_t [PipeWidth-1:0]                 instr_dec_i,
  /// From rename
  input  reg_map_t                                   reg_map_i,
  output logic [NrIntReadPorts-1:0][RegAddrSize-1:0] gpr_raddr_o,
  input  logic [NrIntReadPorts-1:0][XLEN-1:0]        gpr_rdata_i,
  output logic [NrFpReadPorts-1:0][RegAddrSize-1:0]  fpr_raddr_o,
  input  logic [NrFpReadPorts-1:0][FLEN-1:0]         fpr_rdata_i,
  output fu_data_t [PipeWidth-1:0] fu_data_o
);

  always_comb begin
    for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
      fu_data_o[instr_idx]              = '0;
      fu_data_o[instr_idx].fu           = instr_dec_i[instr_idx].fu;
      fu_data_o[instr_idx].alu_op       = instr_dec_i[instr_idx].alu_op;
      fu_data_o[instr_idx].lsu_op       = instr_dec_i[instr_idx].lsu_op;
      fu_data_o[instr_idx].csr_op       = instr_dec_i[instr_idx].csr_op;
      fu_data_o[instr_idx].fpu_op       = instr_dec_i[instr_idx].fpu_op;
      fu_data_o[instr_idx].lsu_size     = instr_dec_i[instr_idx].lsu_size;

      // Cast here is necessary to remove Questa 2025.3 warning
      // (probably a bug on Questa's side)
      fu_data_o[instr_idx].fpu_rnd_mode = fpnew_pkg::roundmode_e'(instr_dec_i[instr_idx].fpu_rnd_mode);
      fu_data_o[instr_idx].fpu_fmt_src  = fpnew_pkg::fp_format_e'(instr_dec_i[instr_idx].fpu_fmt_src);
      fu_data_o[instr_idx].fpu_fmt_dst  = fpnew_pkg::fp_format_e'(instr_dec_i[instr_idx].fpu_fmt_dst);

      // Set the addresses
      // TODO(colluca): currently always reads from both register files and then MUXes.
      //                We could probably save power by only reading from the relevant register file.
      if (instr_idx == 0) begin
        // We only need to read the register file for the scalar mode, otherwise the values are fetched
        // via operand requests.
        gpr_raddr_o[0]   = reg_map_i.phy_reg_rs1;
        gpr_raddr_o[1] = reg_map_i.phy_reg_rs2;
        fpr_raddr_o[0]   = reg_map_i.phy_reg_rs1;
        fpr_raddr_o[1] = reg_map_i.phy_reg_rs2;
        fpr_raddr_o[2] = instr_dec_i[0].imm[RegAddrSize-1:0];
      end

      // Operand A
      // Select the source.
      // - JAL and JALR use the PC as operand A.
      // - CSRRxI use the rs1 address as operand A.
      if (instr_dec_i[instr_idx].use_pc_as_op_a) begin
        // In case we have a JAL or JALR instruction, the blk_ctrl_info will point to that isnstruction
        // we can use this information to calculate the pc/address of the JAL instruction.
        fu_data_o[instr_idx].operand_a[XLEN-1:0] = jump_pc_i;
      end else if (instr_dec_i[instr_idx].use_rs1addr_as_op_a) begin
        fu_data_o[instr_idx].operand_a[XLEN-1:0] = {{XLEN-5{1'b0}}, instr_dec_i[instr_idx].rs1[4:0]};
      end else begin
        if (instr_idx == 0) begin
          if (instr_dec_i[instr_idx].rs1_is_fp) begin
            fu_data_o[instr_idx].operand_a[FLEN-1:0] = fpr_rdata_i[0];
          end else begin
            fu_data_o[instr_idx].operand_a[XLEN-1:0] = gpr_rdata_i[0];
          end
        end else begin
          // For all other instructions we just assign a dummy value
          fu_data_o[instr_idx].operand_a[XLEN-1:0] = '0;
        end
      end

      // Operand B
      // We must select the correct operand b value based on the FU and the instruction.
      // - ALU can have the immediate value as operand b.
      // - For all other FUs the use_imm_as_op_b is set (if a imm is selected) but must be ignored.
      if ((instr_dec_i[instr_idx].fu == schnizo_pkg::ALU ||
           instr_dec_i[instr_idx].fu == schnizo_pkg::CTRL_FLOW) &&
          instr_dec_i[instr_idx].use_imm_as_op_b && !instr_dec_i[instr_idx].is_branch) begin
          fu_data_o[instr_idx].operand_b[XLEN-1:0] = instr_dec_i[instr_idx].imm;
      end else begin
        if (instr_idx == 0) begin
          if (instr_dec_i[instr_idx].rs2_is_fp) begin
            fu_data_o[instr_idx].operand_b[FLEN-1:0] = fpr_rdata_i[1];
          end else begin
            fu_data_o[instr_idx].operand_b[XLEN-1:0] = gpr_rdata_i[1];
          end
        end else begin
          // For all other instructions we just assign a dummy value
          fu_data_o[instr_idx].operand_a[XLEN-1:0] = '0;
        end
      end

      // Operand C - reuses imm field
      if (instr_dec_i[instr_idx].use_imm_as_rs3) begin
        if (instr_idx == 0) begin
        fu_data_o[instr_idx].imm[FLEN-1:0] = fpr_rdata_i[2];
        end else begin
          // For all other instructions we just assign a dummy value
          fu_data_o[instr_idx].imm[FLEN-1:0] = '0;
        end
      end else begin
        fu_data_o[instr_idx].imm[XLEN-1:0] = instr_dec_i[instr_idx].imm;
      end
      end
  end

endmodule
