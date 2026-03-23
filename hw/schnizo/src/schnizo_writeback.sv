// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// The Schnizo write back logic.
//
// Handle the write back of all FUs.
// Branch results are directly returned to the controller.
//
// Prio for GPR
// - ALU
//   - if ALU result is a branch -> process branch and handle next write back
//   - if ALU result is a CSR bypass -> write back ALU result
// - CSR
// - LSU
// - FPU
// - Accelerator interface
// Prio for FPR
// - FPU
// - LSU
// - Accelerator interface (not implemented / there is no tag to select FP register)
//
// !!! WARNING !!!
// The accelerator request only contains an ID to specify the destination register.
// Due to this we cannot distinguish between floating point and integer registers!
// As of now, all accelerator responses target the integer register file.
// This should not be a problem, as the Snitch FPR is only in the FP_SS present.
module schnizo_writeback import schnizo_pkg::*; #(
  parameter int unsigned XLEN            = 32,
  parameter int unsigned FLEN            = 64,
  parameter int unsigned NrIntWritePorts = 1,
  parameter int unsigned NrFpWritePorts  = 1,
  parameter int unsigned RegAddrSize     = 5,
  parameter type         instr_tag_t     = logic,
  parameter type         alu_result_t    = logic,
  parameter type         data_t          = logic,
  parameter type         spatz_result_t  = logic [FLEN-1:0] // Spatz can give fp results up to 64 bit
) (
  // ALU interface
  input  alu_result_t     alu_result_i,
  input  instr_tag_t      alu_result_tag_i,
  input  logic            alu_result_valid_i,
  output logic            alu_result_ready_o,
  input  logic [XLEN-1:0] consecutive_pc_i,
  // CSR interface
  input  logic [XLEN-1:0] csr_result_i,
  input  instr_tag_t      csr_result_tag_i,
  input  logic            csr_result_valid_i,
  output logic            csr_result_ready_o,

  // LSU interface
  input  data_t      lsu_result_i,
  input  instr_tag_t lsu_result_tag_i,
  input  logic       lsu_result_valid_i,
  output logic       lsu_result_ready_o,

  // FPU interface
  input  logic [FLEN-1:0] fpu_result_i,
  input  instr_tag_t      fpu_result_tag_i,
  input  logic            fpu_result_valid_i,
  output logic            fpu_result_ready_o,

  // SPATZ interface
  input  spatz_result_t spatz_result_i,
  input  instr_tag_t    spatz_result_tag_i,
  input  logic          spatz_result_valid_i,
  output logic          spatz_result_ready_o,

  // Accelerator interface
  input  logic [XLEN-1:0] acc_result_i,
  input  instr_tag_t      acc_result_tag_i,
  input  logic            acc_result_valid_i,
  output logic            acc_result_ready_o,

  // Register file interface
  output logic [NrIntWritePorts-1:0][RegAddrSize-1:0] gpr_waddr_o,
  output logic [NrIntWritePorts-1:0][XLEN-1:0]        gpr_wdata_o,
  output logic [NrIntWritePorts-1:0]                  gpr_we_o,
  output logic [NrFpWritePorts-1:0][RegAddrSize-1:0]  fpr_waddr_o,
  output logic [NrFpWritePorts-1:0][FLEN-1:0]         fpr_wdata_o,
  output logic [NrFpWritePorts-1:0]                   fpr_we_o,

  // Core Events
  output logic retired_single_cycle_o,
  output logic retired_load_o,
  output logic retired_acc_o,
  output logic retired_spatz_o
);
  logic alu_gpr_valid; // The ALU only writes to the GPR
  logic alu_gpr_ready;
  logic csr_gpr_valid; // The CSR only writes to the GPR
  logic csr_gpr_ready;
  logic lsu_gpr_valid, lsu_fpr_valid;
  logic lsu_gpr_ready, lsu_fpr_ready;
  logic fpu_gpr_valid, fpu_fpr_valid;
  logic fpu_gpr_ready, fpu_fpr_ready;
  logic acc_gpr_valid; // The accelerator only writes to the GPR
  logic acc_gpr_ready;
  logic spatz_gpr_valid, spatz_fpr_valid;
  logic spatz_gpr_ready, spatz_fpr_ready;

  // MUX the valid/ready signals to the correct register file.
  // TODO: This is probably unnecessary and stalls the core. However, the ALU should never
  //        write to the FPR. How should we handle this case? -> Assertion?
  assign alu_gpr_valid = alu_result_tag_i.dest_reg_is_fp ? 1'b0 : alu_result_valid_i;
  // The ALU cannot write to the FPR -> no alu_valid_fpr
  assign alu_result_ready_o = alu_result_tag_i.dest_reg_is_fp ? 1'b0 : alu_gpr_ready;

  // TODO: Same case as ALU. The CSR should never write to the FPR. -> Assertion?
  assign csr_gpr_valid = csr_result_tag_i.dest_reg_is_fp ? 1'b0 : csr_result_valid_i;
  assign csr_result_ready_o = csr_result_tag_i.dest_reg_is_fp ? 1'b0 : csr_gpr_ready;

  assign lsu_gpr_valid = lsu_result_tag_i.dest_reg_is_fp ? 1'b0               : lsu_result_valid_i;
  assign lsu_fpr_valid = lsu_result_tag_i.dest_reg_is_fp ? lsu_result_valid_i : 1'b0;
  assign lsu_result_ready_o = lsu_result_tag_i.dest_reg_is_fp ? lsu_fpr_ready : lsu_gpr_ready;

  assign fpu_gpr_valid = fpu_result_tag_i.dest_reg_is_fp ? 1'b0               : fpu_result_valid_i;
  assign fpu_fpr_valid = fpu_result_tag_i.dest_reg_is_fp ? fpu_result_valid_i : 1'b0;
  assign fpu_result_ready_o = fpu_result_tag_i.dest_reg_is_fp ? fpu_fpr_ready : fpu_gpr_ready;

  assign spatz_gpr_valid = spatz_result_tag_i.dest_reg_is_fp ? 1'b0               : spatz_result_valid_i;
  assign spatz_fpr_valid = spatz_result_tag_i.dest_reg_is_fp ? spatz_result_valid_i : 1'b0;
  assign spatz_result_ready_o = spatz_result_tag_i.dest_reg_is_fp ? spatz_fpr_ready : spatz_gpr_ready;

  // TODO: The Accelerator should never write to the FPR. -> Assertion?
  assign acc_gpr_valid = acc_result_tag_i.dest_reg_is_fp ? 1'b0 : acc_result_valid_i;
  assign acc_result_ready_o = acc_result_tag_i.dest_reg_is_fp ? 1'b0 : acc_gpr_ready;

  // Note: The register file must always be ready.
  // Otherwise the valid/ready handshaking is not AXI conform anymore.
  always_comb begin : int_regfile_writeback
    gpr_we_o = 1'b0;
    gpr_waddr_o = '0;
    gpr_wdata_o = '0;

    // interfaces to FU writing back to the integer RF
    alu_gpr_ready = '0;
    csr_gpr_ready = '0;
    lsu_gpr_ready = '0;
    fpu_gpr_ready = '0;
    acc_gpr_ready = '0;
    spatz_gpr_ready = '0;

    // If we have a valid request from the ALU, we have to check whether we actually want to write
    // to a register. Any instruction which is retiring without a register write has the
    // destination register set to rd = x0 (rd = 0, rd_is_fp = 0) as this register is not
    // writeable.
    // However, these requests still have to be acknowledged (assert the ready signal) as any
    // combinatorial FU direclty feeds through the ready signal from the write back to the
    // dispatcher. If these were not acknowledged the whole pipeline would stall forever.
    if (alu_gpr_valid && alu_result_tag_i.dest_reg != '0) begin
      gpr_we_o = 1'b1;
      gpr_waddr_o = alu_result_tag_i.dest_reg;
      // Select the data to write into rd.
      // This can either be the ALU result or the consecutive PC (for JAL / JALR)
      if (alu_result_tag_i.is_jump) begin
        gpr_wdata_o = consecutive_pc_i;
      end else begin
        gpr_wdata_o = alu_result_i.result;
      end

      alu_gpr_ready = 1'b1;
    end else begin
      // We have no actual write request from the ALU but we still have to handle any ALU request
      // without a write back (i.e. rd = 0 or branch instr).
      if (alu_gpr_valid && alu_result_tag_i.dest_reg == '0) begin
        alu_gpr_ready = 1'b1;
      end
      // The CSR writeback is similar to the ALU write back. Handle actual write requests and
      // always acknowledge all other requests.
      if (csr_gpr_valid && csr_result_tag_i.dest_reg != '0) begin
        gpr_we_o = 1'b1;
        gpr_waddr_o = csr_result_tag_i.dest_reg;
        gpr_wdata_o = csr_result_i;
        csr_gpr_ready = 1'b1;
      end else begin
      // If there is no actual write request, we can serve a LSU or FPU request.
        if (csr_gpr_valid && csr_result_tag_i.dest_reg == '0) begin
          csr_gpr_ready = 1'b1;
        end
        if (lsu_gpr_valid) begin
          gpr_we_o = 1'b1;
          gpr_waddr_o = lsu_result_tag_i.dest_reg;
          gpr_wdata_o = lsu_result_i[XLEN-1:0];
          lsu_gpr_ready = 1'b1;
        end else if (fpu_gpr_valid) begin
          gpr_we_o = 1'b1;
          gpr_waddr_o = fpu_result_tag_i.dest_reg;
          gpr_wdata_o = fpu_result_i[XLEN-1:0];
          fpu_gpr_ready = 1'b1;
        end else if (acc_gpr_valid) begin
          gpr_we_o = 1'b1;
          gpr_waddr_o = acc_result_tag_i.dest_reg;
          gpr_wdata_o = acc_result_i[XLEN-1:0];
          acc_gpr_ready = 1'b1;
        end else if (spatz_gpr_valid) begin
          gpr_we_o = 1'b1;
          gpr_waddr_o = spatz_result_tag_i.dest_reg;
          gpr_wdata_o = spatz_result_i[XLEN-1:0]; //TODO: Check size, why this clamping to 32 bits? Maybe it is just to avoid overflows but it should be enforced by the architecture
          spatz_gpr_ready = 1'b1;
        end
      end
    end
  end

  always_comb begin : fp_regfile_writeback
    fpr_we_o = 1'b0;
    fpr_waddr_o = '0;
    fpr_wdata_o = '0;

    // interfaces to FU writing back to the integer RF
    lsu_fpr_ready = '0;
    fpu_fpr_ready = '0;
    spatz_fpr_ready = '0;

    if (lsu_fpr_valid) begin
      fpr_we_o = 1'b1;
      fpr_waddr_o = lsu_result_tag_i.dest_reg;
      fpr_wdata_o = lsu_result_i[FLEN-1:0];
      lsu_fpr_ready = 1'b1;
    end else if (fpu_fpr_valid) begin
      fpr_we_o = 1'b1;
      fpr_waddr_o = fpu_result_tag_i.dest_reg;
      fpr_wdata_o = fpu_result_i[FLEN-1:0];
      fpu_fpr_ready = 1'b1;
    end else if (spatz_fpr_valid) begin
      fpr_we_o = 1'b1;
      fpr_waddr_o = spatz_result_tag_i.dest_reg;
      fpr_wdata_o = spatz_result_i[FLEN-1:0];
    end
  end

  // ---------------------------
  // Core Events
  // ---------------------------
  // Capture all retirements in regard to their type.
  assign retired_single_cycle_o = (alu_gpr_valid & alu_gpr_ready) ||
                                  (csr_gpr_valid & csr_gpr_ready);
  assign retired_load_o         = (lsu_gpr_valid & lsu_gpr_ready) ||
                                  (lsu_fpr_valid & lsu_fpr_ready);
  // In Snitch this signal would also capture the retired FPU instructions.
  assign retired_acc_o          = (acc_gpr_valid & acc_gpr_ready);

endmodule
