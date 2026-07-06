// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// Author: Stefan Odermatt <soderma@ethz.ch>
// The scoreboard keeps track of RAW and WAW dependencies.
// It marks each register busy if an ongoing instruction will write back into it.
// There are two separate scoreboards for each register file.
// sbi for the integer and sbf for the floating point register, respectively.
module schnova_scoreboard #(
  parameter bit          XFREPO       = 1'b1,
  parameter int unsigned PipeWidth    = 1,
  parameter int unsigned NrReadPorts  = 2,
  parameter int unsigned NrIntWritePorts = 1,
  parameter int unsigned NrFpWritePorts  = 1,
  parameter int unsigned PhysAddrWidth    = 6,
  parameter int unsigned GprAddrWidth     = 6,
  parameter int unsigned FprAddrWidth     = 6,
  parameter int unsigned NofPhysGpr       = 64,
  parameter int unsigned NofPhysFpr       = 64,
  parameter type         sb_disp_data_t = logic
) (
  // clock and reset
  input  logic                                    clk_i,
  input  logic                                    rst_i,
  input  logic                                    en_superscalar_i,
  // Dispatched instruction
  input  logic                                    dispatched_i,
  input  logic [PipeWidth-1:0]                    instr_valid_i,
  input  sb_disp_data_t [PipeWidth-1:0]           disp_data_i,
  // Read port for the physical register file
  input  logic [NrReadPorts-1:0][PhysAddrWidth-1:0] raddr_i,
  input  logic [NrReadPorts-1:0]                    read_fp_i,
  output logic [NrReadPorts-1:0]                    rdata_o,
  // Register writeback snooping
  input  logic [NrIntWritePorts-1:0][GprAddrWidth-1:0] wb_gpr_addr_i,
  input  logic [NrIntWritePorts-1:0]                   wb_gpr_en_i,
  input  logic [NrFpWritePorts-1:0][FprAddrWidth-1:0]  wb_fpr_addr_i,
  input  logic [NrFpWritePorts-1:0]                    wb_fpr_en_i,
  // To controller
  output logic                                    registers_ready_o,
  output logic                                    sb_busy_o,
  // To Refcount
  output logic [NofPhysGpr-1:0]                   sbi_q_o,
  output logic [NofPhysFpr-1:0]                   sbf_q_o
);

  logic [NofPhysGpr-1:0] sbi_d, sbi_q;
  logic [NofPhysFpr-1:0] sbf_d, sbf_q;
  logic [NofPhysGpr-1:0] sbi_set, sbi_clr;
  logic [NofPhysFpr-1:0] sbf_set, sbf_clr;
  // Decoders specialized for each file size
  logic [PipeWidth-1:0][NofPhysGpr-1:0] disp_gpr_dec;
  logic [PipeWidth-1:0][NofPhysFpr-1:0] disp_fpr_dec;
  logic [NrIntWritePorts-1:0][NofPhysGpr-1:0] wb_gpr_dec;
  logic [NrFpWritePorts-1:0][NofPhysFpr-1:0] wb_fpr_dec;

  `FFAR(sbi_q, sbi_d, '0, clk_i, rst_i)
  `FFAR(sbf_q, sbf_d, '0, clk_i, rst_i)

  // --- Decoders ---
  for (genvar j = 0; j < PipeWidth; j++) begin : gen_disp_dec
    assign disp_gpr_dec[j] = (instr_valid_i[j] & dispatched_i & ~disp_data_i[j].rd_is_fp) ?
                             (NofPhysGpr'(1) << disp_data_i[j].rd[GprAddrWidth-1:0]) : '0;
    assign disp_fpr_dec[j] = (instr_valid_i[j] & dispatched_i &  disp_data_i[j].rd_is_fp) ?
                             (NofPhysFpr'(1) << disp_data_i[j].rd[FprAddrWidth-1:0]) : '0;
  end

  for (genvar j = 0; j < NrIntWritePorts; j++) begin : gen_gpr_dec
    assign wb_gpr_dec[j] = (wb_gpr_en_i[j]) ? (NofPhysGpr'(1) << wb_gpr_addr_i[j]) : '0;
  end

  for (genvar j = 0; j < NrFpWritePorts; j++) begin : gen_fpr_dec
    assign wb_fpr_dec[j] = (wb_fpr_en_i[j]) ? (NofPhysFpr'(1) << wb_fpr_addr_i[j]) : '0;
  end

  // --- Update Logic ---
  always_comb begin : scoreboard_update
    sbi_set = '0; sbi_clr = '0;
    sbf_set = '0; sbf_clr = '0;

    for (int j = 0; j < PipeWidth; j++) begin
        sbi_set |= disp_gpr_dec[j];
        sbf_set |= disp_fpr_dec[j];
    end

    for (int j = 0; j < NrIntWritePorts; j++) sbi_clr |= wb_gpr_dec[j];
    for (int j = 0; j < NrFpWritePorts; j++)  sbf_clr |= wb_fpr_dec[j];

    sbi_d = (sbi_q | sbi_set) & ~sbi_clr;
    sbf_d = (sbf_q | sbf_set) & ~sbf_clr;

    sbi_d[0] = 1'b0; // x0 is never busy

    // Assign the scoreboard as an output
    sbi_q_o = sbi_q;
    sbf_q_o = sbf_q;
  end

  ///////////////////////////
  // Scoreboard read ports //
  ///////////////////////////
  if (XFREPO) begin : gen_sb_read_ports
    // We must truncate the global PhysAddrWidth to the specific regfile width
    always_comb begin
      for (int unsigned i = 0; i < NrReadPorts; i++) begin
        if (read_fp_i[i]) begin
          rdata_o[i] = sbf_q[raddr_i[i][FprAddrWidth-1:0]];
        end else begin
          rdata_o[i] = sbi_q[raddr_i[i][GprAddrWidth-1:0]];
        end
      end
    end
  end else begin: gen_no_read_ports
    assign rdata_o = '0;
  end

  //////////////////////
  // RAW dependencies //
  //////////////////////

  // This checks the scoreboard for RAW conflicts using the decoded register addresses.
  // These addresses and the rx_is_fp signals default to zero. If a register is not used,
  // any lookup will check x0 which is always ready (hardwired to zero value, read only).

  // --- RAW / WAW Ready Checks (Scalar Mode) ---
  logic op_a_has_raw, op_b_has_raw, op_c_has_raw, dest_has_waw;

  assign op_a_has_raw = disp_data_i[0].rs1_is_fp ? sbf_q[disp_data_i[0].rs1[FprAddrWidth-1:0]] :
                                                   sbi_q[disp_data_i[0].rs1[GprAddrWidth-1:0]];

  assign op_b_has_raw = disp_data_i[0].rs2_is_fp ? sbf_q[disp_data_i[0].rs2[FprAddrWidth-1:0]] :
                                                   sbi_q[disp_data_i[0].rs2[GprAddrWidth-1:0]];

  assign op_c_has_raw = disp_data_i[0].use_imm_as_rs3 ? sbf_q[disp_data_i[0].rs3[FprAddrWidth-1:0]] :
                                                        1'b0;

  assign dest_has_waw = disp_data_i[0].rd_is_fp  ? sbf_q[disp_data_i[0].rd[FprAddrWidth-1:0]]  :
                                                   sbi_q[disp_data_i[0].rd[GprAddrWidth-1:0]];

  assign registers_ready_o = en_superscalar_i ? 1'b1 : !(op_a_has_raw || op_b_has_raw || op_c_has_raw || dest_has_waw);
  assign sb_busy_o = (|sbf_q) | (|sbi_q);

endmodule
