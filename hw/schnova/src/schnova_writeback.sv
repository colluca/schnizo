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
module schnova_writeback import schnova_pkg::*; #(
  parameter int unsigned PipeWidth       = 1,
  parameter int unsigned RobTagWidth     = 1,
  parameter int unsigned XLEN            = 32,
  parameter int unsigned FLEN            = 64,
  parameter int unsigned NrIntWritePorts = 1,
  parameter int unsigned NrFpWritePorts  = 1,
  parameter int unsigned NrRobWritePorts  = 2,
  parameter int unsigned NofAlus           = 1,
  parameter int unsigned NofLsus           = 1,
  parameter int unsigned NofFpus           = 1,
  parameter int unsigned RegAddrSize     = 5,
  parameter type         instr_tag_t     = logic,
  parameter type         alu_result_t    = logic,
  parameter type         fpu_result_t    = logic,
  parameter type         data_t          = logic
) (
  input logic             en_superscalar_i,
  // ROB interface
  output logic [NrRobWritePorts-1:0]                  wb_valid_o,
  output logic [NrRobWritePorts-1:0][RobTagWidth-1:0] wb_rob_idx_o,
  // ALU interface
  input  alu_result_t [NofAlus-1:0] alu_results_i,
  input  instr_tag_t  [NofAlus-1:0] alu_results_tag_i,
  input  logic        [NofAlus-1:0] alu_results_valid_i,
  output logic        [NofAlus-1:0] alu_results_ready_o,
  input  logic [XLEN-1:0] consecutive_pc_i,
  // CSR interface
  input  logic [XLEN-1:0] csr_result_i,
  input  instr_tag_t      csr_result_tag_i,
  input  logic            csr_result_valid_i,
  output logic            csr_result_ready_o,

  // LSU interface
  input  data_t      [NofLsus-1:0] lsu_results_i,
  input  instr_tag_t [NofLsus-1:0] lsu_results_tag_i,
  input  logic       [NofLsus-1:0] lsu_results_valid_i,
  output logic       [NofLsus-1:0] lsu_results_ready_o,

  // FPU interface
  input  fpu_result_t [NofFpus-1:0] fpu_results_i,
  input  instr_tag_t  [NofFpus-1:0] fpu_results_tag_i,
  input  logic        [NofFpus-1:0] fpu_results_valid_i,
  output logic        [NofFpus-1:0] fpu_results_ready_o,

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

  // Control instruction retirement
  output logic ctrl_instr_retired_o,

  // Core Events
  output logic retired_single_cycle_o,
  output logic retired_load_o,
  output logic retired_acc_o
);

  // Valid/ready signal muxing
  logic [NofAlus-1:0] alu_gpr_valid; // The ALU only writes to the GPR
  logic [NofAlus-1:0] alu_gpr_ready;
  logic csr_gpr_valid; // The CSR only writes to the GPR
  logic csr_gpr_ready;
  logic [NofLsus-1:0] lsu_gpr_valid, lsu_fpr_valid;
  logic [NofLsus-1:0] lsu_gpr_ready, lsu_fpr_ready;
  logic [NofFpus-1:0] fpu_gpr_valid, fpu_fpr_valid;
  logic [NofFpus-1:0] fpu_gpr_ready, fpu_fpr_ready;
  logic acc_gpr_valid; // The accelerator only writes to the GPR
  logic acc_gpr_ready;

  logic rob_gpr_valid;
  logic rob_fpr_valid;

  logic [NrIntWritePorts-1:0]                  wb_gpr_valid;
  logic [NrIntWritePorts-1:0][RobTagWidth-1:0] wb_gpr_rob_idx;
  logic [NrFpWritePorts-1:0]                   wb_fpr_valid;
  logic [NrFpWritePorts-1:0][RobTagWidth-1:0]  wb_fpr_rob_idx;

  always_comb begin: int_regfile_vld_rdy_mux
    // ALU valid/ready muxing of GPR
    for (int unsigned alu = 0; alu < NofAlus; alu++) begin
      alu_gpr_valid[alu] = alu_results_valid_i[alu];
      alu_results_ready_o[alu] = alu_gpr_ready[alu];
    end

    // CSR valid/ready muxing of GPR register
    csr_gpr_valid = csr_result_valid_i;
    csr_result_ready_o = csr_gpr_ready;

    // LSU valid/ready muxing for GPR and FPR
    for (int unsigned lsu = 0; lsu < NofLsus; lsu++) begin
      lsu_gpr_valid[lsu] = lsu_results_tag_i[lsu].dest_reg_is_fp ? 1'b0
                                                                : lsu_results_valid_i[lsu];
      lsu_fpr_valid[lsu] = lsu_results_tag_i[lsu].dest_reg_is_fp ? lsu_results_valid_i[lsu]
                                                                : 1'b0;
      lsu_results_ready_o[lsu] = lsu_results_tag_i[lsu].dest_reg_is_fp  ? lsu_fpr_ready[lsu]
                                                                      : lsu_gpr_ready[lsu];
    end

    // FPU valid/ready muxing for GPR register
    for (int unsigned fpu = 0; fpu < NofFpus; fpu++) begin
      fpu_gpr_valid[fpu] = fpu_results_tag_i[fpu].dest_reg_is_fp ? 1'b0
                                                                : fpu_results_valid_i[fpu];
      fpu_fpr_valid[fpu] = fpu_results_tag_i[fpu].dest_reg_is_fp ? fpu_results_valid_i[fpu]
                                                                : 1'b0;
      fpu_results_ready_o[fpu] = fpu_results_tag_i[fpu].dest_reg_is_fp  ? fpu_fpr_ready[fpu]
                                                                      : fpu_gpr_ready[fpu];
    end

    // ACC valid/ready muxing for GPR
    acc_gpr_valid = acc_result_tag_i.dest_reg_is_fp ? 1'b0 : acc_result_valid_i;
    acc_result_ready_o = acc_result_tag_i.dest_reg_is_fp ? 1'b0 : acc_gpr_ready;
  end

  // ---------------------------
  // Integer Regfile Writeback
  // ---------------------------
  // Each ALU, LSU and FPU can write to the GPR
  // in addition the CSR and accelerator port can write to it
  typedef struct packed {
    logic [XLEN-1:0] data;
    logic [RegAddrSize-1:0] addr;
    logic [RobTagWidth-1:0] rob_tag;
  } gpr_data_t;

  localparam int unsigned NofGprSrcs = NofAlus + NofLsus + NofFpus + 2;
  logic      [NofGprSrcs-1:0] gpr_valid;
  logic      [NofGprSrcs-1:0] gpr_ready;
  gpr_data_t [NofGprSrcs-1:0] gpr_data;

  // The order here determines the priority of the access to the GPR
  // Currently the priority is the same as for Schnizo
  // 1) ALU
  // 2) CSR
  // 3) LSU
  // 4) FPU
  // 5) ACC
  always_comb begin: int_wb_priority_encoding
    // ALUs have the highest priority
    automatic int unsigned i = 0;

    for (int unsigned alu = 0; alu < NofAlus; alu++) begin
      gpr_valid[i] = alu_gpr_valid[alu];
      gpr_data[i]  = '{
        data: alu_results_tag_i[alu].is_jump ? consecutive_pc_i
                                            : alu_results_i[alu].result,
        addr:     alu_results_tag_i[alu].dest_reg,
        rob_tag:  alu_results_tag_i[alu].rob_tag
      };
      alu_gpr_ready[alu] = gpr_ready[i];
      i++;
    end

    gpr_valid[i] = csr_gpr_valid;
    gpr_data[i]  = '{
        data:     csr_result_i,
        addr:     csr_result_tag_i.dest_reg,
        rob_tag:  csr_result_tag_i.rob_tag
      };
    csr_gpr_ready = gpr_ready[i];
    i++;

    for (int unsigned lsu = 0; lsu < NofLsus; lsu++) begin
      gpr_valid[i] = lsu_gpr_valid[lsu];
      gpr_data[i]  = '{
        data:     lsu_results_i[lsu][XLEN-1:0],
        addr:     lsu_results_tag_i[lsu].dest_reg,
        rob_tag:  lsu_results_tag_i[lsu].rob_tag
      };
      lsu_gpr_ready[lsu] = gpr_ready[i];
      i++;
    end

    for (int unsigned fpu = 0; fpu < NofFpus; fpu++) begin
      gpr_valid[i] = fpu_gpr_valid[fpu];
      gpr_data[i]  = '{
        data:     fpu_results_i[fpu][XLEN-1:0],
        addr:     fpu_results_tag_i[fpu].dest_reg,
        rob_tag:  fpu_results_tag_i[fpu].rob_tag
      };
      fpu_gpr_ready[fpu] = gpr_ready[i];
      i++;
    end

    gpr_valid[i] = acc_gpr_valid;
    gpr_data[i]  = '{
        data:     acc_result_i[XLEN-1:0],
        addr:     acc_result_tag_i.dest_reg,
        rob_tag:  acc_result_tag_i.rob_tag
      };
    acc_gpr_ready = gpr_ready[i];
  end

  // Signal to track which FU is assigned to which Port
  logic [NofGprSrcs-1:0][NrIntWritePorts-1:0] gpr_port_grant;

  always_comb begin : int_regfile_port_allocation
      automatic int unsigned port_ptr = 0;

      gpr_port_grant = '0;
      gpr_ready      = '0;

      for (int unsigned i = 0; i < NofGprSrcs; i++) begin
        if (gpr_valid[i]) begin
          if (gpr_data[i].addr == '0) begin
            gpr_ready[i] = 1'b1; // x0 results don't need a port
          end else if (port_ptr < NrIntWritePorts) begin
            // This functional unit wins the write port the port_ptr currently points to
            gpr_port_grant[i][port_ptr] = 1'b1;
            gpr_ready[i]                = 1'b1;
            port_ptr++;
          end
        end
      end
  end

  always_comb begin: int_regfile_wb_mux
    gpr_we_o    = '0;
    gpr_waddr_o = '0;
    gpr_wdata_o = '0;
    wb_gpr_valid = '0;
    wb_gpr_rob_idx =  '0;

    for (int unsigned port = 0; port < NrIntWritePorts; port++) begin
      for (int unsigned src = 0; src < NofGprSrcs; src++) begin
        if (gpr_port_grant[src][port]) begin
          gpr_we_o[port]    = 1'b1;
          gpr_waddr_o[port] = gpr_data[src].addr;
          gpr_wdata_o[port] = gpr_data[src].data;
          // Only update the ROB in superscalar mode
          wb_gpr_valid[port]  = en_superscalar_i;
          wb_gpr_rob_idx[port] = gpr_data[src].rob_tag;
        end
      end
    end
  end

  // ---------------------------
  // Float Regfile Writeback
  // ---------------------------
  // Each LSU and FPU can potentially writeback to the
  // floating point register file
  typedef struct packed {
    logic [FLEN-1:0] data;
    logic [RegAddrSize-1:0] addr;
    logic [RobTagWidth-1:0] rob_tag;
  } fpr_data_t;

  localparam int unsigned NofFprSrcs = NofLsus + NofFpus;
  logic      [NofFprSrcs-1:0] fpr_valid;
  logic      [NofFprSrcs-1:0] fpr_ready;
  fpr_data_t [NofFprSrcs-1:0] fpr_data;

  // The order here determines the priority of the access to the GPR
  // Currently the priority is the same as for Schnizo
  // 1) LSU
  // 2) FPU
  always_comb begin: fp_wb_priority_encoding
    automatic int unsigned i = 0;

    for (int unsigned lsu = 0; lsu < NofLsus; lsu++) begin
      fpr_valid[i] = lsu_fpr_valid[lsu];
      fpr_data[i]  = '{
        data:     lsu_results_i[lsu][FLEN-1:0],
        addr:     lsu_results_tag_i[lsu].dest_reg,
        rob_tag:  lsu_results_tag_i[lsu].rob_tag
      };
      lsu_fpr_ready[lsu] = fpr_ready[i];
      i++;
    end

    for (int unsigned fpu = 0; fpu < NofFpus; fpu++) begin
      fpr_valid[i] = fpu_fpr_valid[fpu];
      fpr_data[i]  = '{
        data:     fpu_results_i[fpu][FLEN-1:0],
        addr:     fpu_results_tag_i[fpu].dest_reg,
        rob_tag:  fpu_results_tag_i[fpu].rob_tag
      };
      fpu_fpr_ready[fpu] = fpr_ready[i];
      i++;
    end
  end

  // Signal to track which FU is assigned to which Port
  logic [NofFprSrcs-1:0][NrFpWritePorts-1:0] fpr_port_grant;

  always_comb begin : fpr_regfile_port_allocation
      automatic int unsigned port_ptr = 0;
      fpr_port_grant = '0;
      fpr_ready      = '0;

      for (int i = 0; i < NofFprSrcs; i++) begin
        if (fpr_valid[i]) begin
          if (port_ptr < NrFpWritePorts) begin
            // This functional unit wins the write port the port_ptr currently points to
            fpr_port_grant[i][port_ptr] = 1'b1;
            fpr_ready[i]                = 1'b1;
            port_ptr++;
          end
        end
      end
  end

  always_comb begin: fp_regfile_wb_mux
    fpr_we_o    = '0;
    fpr_waddr_o = '0;
    fpr_wdata_o = '0;
    wb_fpr_valid = '0;
    wb_fpr_rob_idx =  '0;

    for (int unsigned port = 0; port < NrFpWritePorts; port++) begin
      for (int unsigned src = 0; src < NofFprSrcs; src++) begin
        if (fpr_port_grant[src][port]) begin
          fpr_we_o[port]    = 1'b1;
          fpr_waddr_o[port] = fpr_data[src].addr;
          fpr_wdata_o[port] = fpr_data[src].data;
          // Only update the ROB in superscalar mode
          wb_fpr_valid[port]   = en_superscalar_i;
          wb_fpr_rob_idx[port] = fpr_data[src].rob_tag;
        end
      end
    end
  end

  // Only ALU0 can retire control instructions
  always_comb begin : ctr_instr_retirement
    // Per default no control instruction is being retired
    ctrl_instr_retired_o = 1'b0;
    if (alu_gpr_valid[0] && (alu_results_tag_i[0].is_jump || alu_results_tag_i[0].is_branch)) begin
      // If we have a valid result and the tag hints to a jump or branch instruction
      // we have retired a ctrl instruction this cycle.
      ctrl_instr_retired_o = 1'b1;
    end
  end

  assign wb_valid_o = {wb_fpr_valid, wb_gpr_valid};
  assign wb_rob_idx_o = {wb_fpr_rob_idx, wb_gpr_rob_idx};

  // ---------------------------
  // Core Events
  // ---------------------------
  // Capture all retirements in regard to their type.
  // TODO: Rework core events
  assign retired_single_cycle_o = (alu_gpr_valid[0] & alu_gpr_ready[0]) ||
                                  (csr_gpr_valid & csr_gpr_ready);
  assign retired_load_o         = (lsu_gpr_valid[0] & lsu_gpr_ready[0]) ||
                                  (lsu_fpr_valid[0] & lsu_fpr_ready[0]);
  // In Snitch this signal would also capture the retired FPU instructions.
  assign retired_acc_o          = (acc_gpr_valid & acc_gpr_ready);

endmodule
