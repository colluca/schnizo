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
  parameter int unsigned AluLsuNofResPorts = 2,
  parameter type         instr_tag_t     = logic,
  parameter type         alu_result_t    = logic,
  parameter type         data_t          = logic,
  parameter type         alu_lsu_result_t = logic
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
  input  data_t           lsu_result_i,
  input  instr_tag_t      lsu_result_tag_i,
  input  logic            lsu_result_valid_i,
  output logic            lsu_result_ready_o,

  // ALU+LSU interface
  input  alu_lsu_result_t [AluLsuNofResPorts-1:0] alu_lsu_results_i,
  input  instr_tag_t      [AluLsuNofResPorts-1:0] alu_lsu_result_tags_i,
  input  logic            [AluLsuNofResPorts-1:0] alu_lsu_results_valid_i,
  output logic            [AluLsuNofResPorts-1:0] alu_lsu_results_ready_o,

  // FPU interface
  input  logic [FLEN-1:0] fpu_result_i,
  input  instr_tag_t      fpu_result_tag_i,
  input  logic            fpu_result_valid_i,
  output logic            fpu_result_ready_o,

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
  output logic retired_acc_o
);

  logic alu_gpr_valid, alu_gpr_ready;
  logic csr_gpr_valid, csr_gpr_ready;
  logic lsu_gpr_valid, lsu_fpr_valid, lsu_gpr_ready, lsu_fpr_ready;
  logic [1:0] alu_lsu_gpr_valids, alu_lsu_fpr_valids;
  logic [1:0] alu_lsu_gpr_readys, alu_lsu_fpr_readys;
  logic fpu_gpr_valid, fpu_fpr_valid, fpu_gpr_ready, fpu_fpr_ready;
  logic acc_gpr_valid, acc_gpr_ready;
  logic gpr_port_used, fpr_port_used;

  // -------------------------------
  // Demultiplex Valid/Ready Signals
  // -------------------------------
  // MUX the valid/ready signals to the correct register file.

  // ALU (Integer only)
  assign alu_gpr_valid = alu_result_valid_i;
  assign alu_result_ready_o = alu_gpr_ready;

  // CSR (Integer only)
  assign csr_gpr_valid = csr_result_valid_i;
  assign csr_result_ready_o = csr_gpr_ready;

  // LSU
  assign lsu_gpr_valid      = !lsu_result_tag_i.dest_reg_is_fp ? lsu_result_valid_i : 1'b0;
  assign lsu_fpr_valid      =  lsu_result_tag_i.dest_reg_is_fp ? lsu_result_valid_i : 1'b0;
  assign lsu_result_ready_o =  lsu_result_tag_i.dest_reg_is_fp ? lsu_fpr_ready      : lsu_gpr_ready;

  // ALU_LSU Port 0
  assign alu_lsu_gpr_valids[0]      = !alu_lsu_result_tags_i[0].dest_reg_is_fp ?
                                      alu_lsu_results_valid_i[0] : 1'b0;
  assign alu_lsu_fpr_valids[0]      =  alu_lsu_result_tags_i[0].dest_reg_is_fp ?
                                       alu_lsu_results_valid_i[0] : 1'b0;
  assign alu_lsu_results_ready_o[0] =  alu_lsu_result_tags_i[0].dest_reg_is_fp ?
                                       alu_lsu_fpr_readys[0] : alu_lsu_gpr_readys[0];

  // ALU_LSU Port 1
  if (AluLsuNofResPorts == 2) begin: gen_two_alu_lsu_wb_ports
    assign alu_lsu_gpr_valids[1]      = !alu_lsu_result_tags_i[1].dest_reg_is_fp ?
                                        alu_lsu_results_valid_i[1] : 1'b0;
    assign alu_lsu_fpr_valids[1]      =  alu_lsu_result_tags_i[1].dest_reg_is_fp ?
                                         alu_lsu_results_valid_i[1] : 1'b0;
    assign alu_lsu_results_ready_o[1] =  alu_lsu_result_tags_i[1].dest_reg_is_fp ?
                                         alu_lsu_fpr_readys[1] : alu_lsu_gpr_readys[1];
  end else begin: gen_one_alu_lsu_wb_ports
    assign alu_lsu_gpr_valids[1]      = '0;
    assign alu_lsu_fpr_valids[1]      = '0;
  end

  // FPU
  assign fpu_gpr_valid      = !fpu_result_tag_i.dest_reg_is_fp ? fpu_result_valid_i : 1'b0;
  assign fpu_fpr_valid      =  fpu_result_tag_i.dest_reg_is_fp ? fpu_result_valid_i : 1'b0;
  assign fpu_result_ready_o =  fpu_result_tag_i.dest_reg_is_fp ? fpu_fpr_ready      : fpu_gpr_ready;

  // Accelerator (Integer only)
  assign acc_gpr_valid      = acc_result_valid_i;
  assign acc_result_ready_o = acc_gpr_ready;

  // -------------------------------
  // Integer Register File Writeback
  // -------------------------------
  always_comb begin : int_regfile_writeback
    // Default assignments
    gpr_we_o           = 1'b0;
    gpr_waddr_o        = '0;
    gpr_wdata_o        = '0;

    alu_gpr_ready      = 1'b0;
    csr_gpr_ready      = 1'b0;
    lsu_gpr_ready      = 1'b0;
    alu_lsu_gpr_readys = '0;
    fpu_gpr_ready      = 1'b0;
    acc_gpr_ready      = 1'b0;

    gpr_port_used      = 1'b0;

    // ALU Priority
    if (alu_gpr_valid) begin
      if (alu_result_tag_i.dest_reg != '0) begin
        gpr_we_o      = 1'b1;
        gpr_waddr_o   = alu_result_tag_i.dest_reg;
        gpr_wdata_o   = alu_result_tag_i.is_jump ? consecutive_pc_i : alu_result_i.result;
        alu_gpr_ready = 1'b1;
        gpr_port_used = 1'b1;
      end else begin
        alu_gpr_ready = 1'b1;
      end
    end

    // CSR Priority
    if (!gpr_port_used && csr_gpr_valid) begin
      if (csr_result_tag_i.dest_reg != '0) begin
        gpr_we_o      = 1'b1;
        gpr_waddr_o   = csr_result_tag_i.dest_reg;
        gpr_wdata_o   = csr_result_i;
        csr_gpr_ready = 1'b1;
        gpr_port_used = 1'b1;
      end else begin
        csr_gpr_ready = 1'b1;
      end
    end

    // LSU Priority
    if (!gpr_port_used && lsu_gpr_valid) begin
      if (lsu_result_tag_i.dest_reg != '0) begin
        gpr_we_o      = 1'b1;
        gpr_waddr_o   = lsu_result_tag_i.dest_reg;
        gpr_wdata_o   = lsu_result_i[XLEN-1:0];
        lsu_gpr_ready = 1'b1;
        gpr_port_used = 1'b1;
      end else begin
        lsu_gpr_ready = 1'b1;
      end
    end

    // ALU_LSU Port 0 Priority
    if (!gpr_port_used && alu_lsu_gpr_valids[0]) begin
      if (alu_lsu_result_tags_i[0].dest_reg != '0) begin
        gpr_we_o              = 1'b1;
        gpr_waddr_o           = alu_lsu_result_tags_i[0].dest_reg;
        gpr_wdata_o           = alu_lsu_result_tags_i[0].is_jump ?
                                consecutive_pc_i : alu_lsu_results_i[0];
        alu_lsu_gpr_readys[0] = 1'b1;
        gpr_port_used         = 1'b1;
      end else begin
        alu_lsu_gpr_readys[0] = 1'b1;
      end
    end

    // ALU_LSU Port 1 Priority
    if (AluLsuNofResPorts == 2) begin
      if (!gpr_port_used && alu_lsu_gpr_valids[1]) begin
        if (alu_lsu_result_tags_i[1].dest_reg != '0) begin
          gpr_we_o              = 1'b1;
          gpr_waddr_o           = alu_lsu_result_tags_i[1].dest_reg;
          gpr_wdata_o           = alu_lsu_result_tags_i[1].is_jump ?
                                  consecutive_pc_i : alu_lsu_results_i[1];
          alu_lsu_gpr_readys[1] = 1'b1;
          gpr_port_used         = 1'b1;
        end else begin
          alu_lsu_gpr_readys[1] = 1'b1;
        end
      end
    end

    // FPU Priority
    if (!gpr_port_used && fpu_gpr_valid) begin
      if (fpu_result_tag_i.dest_reg != '0) begin
        gpr_we_o      = 1'b1;
        gpr_waddr_o   = fpu_result_tag_i.dest_reg;
        gpr_wdata_o   = fpu_result_i[XLEN-1:0];
        fpu_gpr_ready = 1'b1;
        gpr_port_used = 1'b1;
      end else begin
        fpu_gpr_ready = 1'b1;
      end
    end

    // Accelerator Priority
    if (!gpr_port_used && acc_gpr_valid) begin
      if (acc_result_tag_i.dest_reg != '0) begin
        gpr_we_o      = 1'b1;
        gpr_waddr_o   = acc_result_tag_i.dest_reg;
        gpr_wdata_o   = acc_result_i[XLEN-1:0];
        acc_gpr_ready = 1'b1;
        gpr_port_used = 1'b1;
      end else begin
        acc_gpr_ready = 1'b1;
      end
    end
  end

  // --------------------------------------
  // Floating-Point Register File Writeback
  // --------------------------------------
  always_comb begin : fp_regfile_writeback
    fpr_we_o    = '0;
    fpr_waddr_o = '0;
    fpr_wdata_o = '0;

    alu_lsu_fpr_readys = '0;
    lsu_fpr_ready      = '0;
    fpu_fpr_ready      = '0;

    fpr_port_used = 1'b0;

    // No hardwired x0 equivalent in FPRs, standard priority routing
    if (alu_lsu_fpr_valids[0]) begin
      fpr_we_o              = 1'b1;
      fpr_waddr_o           = alu_lsu_result_tags_i[0].dest_reg;
      fpr_wdata_o           = alu_lsu_results_i[0][FLEN-1:0];
      alu_lsu_fpr_readys[0] = 1'b1;
      fpr_port_used = 1'b1;
    end

    if (!fpr_port_used && AluLsuNofResPorts == 2) begin
      if (alu_lsu_fpr_valids[1]) begin
        fpr_we_o              = 1'b1;
        fpr_waddr_o           = alu_lsu_result_tags_i[1].dest_reg;
        fpr_wdata_o           = alu_lsu_results_i[1][FLEN-1:0];
        alu_lsu_fpr_readys[1] = 1'b1;
        fpr_port_used = 1'b1;
      end
    end

    if (!fpr_port_used && lsu_fpr_valid) begin
      fpr_we_o              = 1'b1;
      fpr_waddr_o           = lsu_result_tag_i.dest_reg;
      fpr_wdata_o           = lsu_result_i[FLEN-1:0];
      lsu_fpr_ready         = 1'b1;
      fpr_port_used = 1'b1;
    end

    if (!fpr_port_used && fpu_fpr_valid) begin
      fpr_we_o              = 1'b1;
      fpr_waddr_o           = fpu_result_tag_i.dest_reg;
      fpr_wdata_o           = fpu_result_i[FLEN-1:0];
      fpu_fpr_ready         = 1'b1;
      fpr_port_used = 1'b1;
    end
  end

  // -----------
  // Core Events
  // -----------

  if (AluLsuNofResPorts == 2) begin: gen_core_events_assignments_two_ports
    assign retired_single_cycle_o = (alu_gpr_valid & alu_gpr_ready) ||
                                    (csr_gpr_valid & csr_gpr_ready) ||
                                    (alu_lsu_gpr_valids[0] & alu_lsu_gpr_readys[0]);

    assign retired_load_o         = (lsu_gpr_valid & lsu_gpr_ready) ||
                                    (lsu_fpr_valid & lsu_fpr_ready) ||
                                    (alu_lsu_gpr_valids[1] & alu_lsu_gpr_readys[1]) ||
                                    (alu_lsu_fpr_valids[1] & alu_lsu_fpr_readys[1]);
  end else begin: gen_core_events_assignments_one_port
    // TODO(lnoussi): Find way to add alu_lsu to core events. How to distinguish between
    // alu or lsu writeback?
    assign retired_single_cycle_o = (alu_gpr_valid & alu_gpr_ready) ||
                                    (csr_gpr_valid & csr_gpr_ready);

    assign retired_load_o         = (lsu_gpr_valid & lsu_gpr_ready) ||
                                    (lsu_fpr_valid & lsu_fpr_ready);
  end

  assign retired_acc_o          = (acc_gpr_valid & acc_gpr_ready);

endmodule
