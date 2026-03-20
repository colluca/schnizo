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
  parameter int unsigned PipeWidth    = 1,
  parameter int unsigned NrReadPorts  = 2,
  parameter int unsigned NrWritePorts = 1,
  parameter int unsigned AddrWidth    = 4,
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
  // Register writeback snooping
  input  logic [NrWritePorts-1:0][AddrWidth-1:0]  wb_gpr_addr_i,
  input  logic [NrWritePorts-1:0]                 wb_gpr_en_i,
  input  logic [NrWritePorts-1:0][AddrWidth-1:0]  wb_fpr_addr_i,
  input  logic [NrWritePorts-1:0]                 wb_fpr_en_i,
  // To controller
  output logic                                    registers_ready_o,
  output logic                                    sb_busy_o
);

  localparam int unsigned NumRegs  = 2**AddrWidth;

  logic [NumRegs-1:0] sbi_d, sbi_q, sbf_d, sbf_q;
  logic [PipeWidth-1:0][NumRegs-1:0] disp_dec;
  logic [NrWritePorts-1:0][NumRegs-1:0] wb_gpr_dec;
  logic [NrWritePorts-1:0][NumRegs-1:0] wb_fpr_dec;

  `FFAR(sbi_q, sbi_d, '0, clk_i, rst_i)
  `FFAR(sbf_q, sbf_d, '0, clk_i, rst_i)

  always_comb begin : disp_decoder
    for (int unsigned j = 0; j < PipeWidth; j++) begin
      for (int unsigned i = 0; i < NumRegs; i++) begin
        if (disp_data_i[j].rd == i) disp_dec[j][i] = instr_valid_i[j] & dispatched_i;
        else disp_dec[j][i] = 1'b0;
      end
    end
  end

  always_comb begin : wb_gpr_decoder
    for (int unsigned j = 0; j < NrWritePorts; j++) begin
      for (int unsigned i = 0; i < NumRegs; i++) begin
        if (wb_gpr_addr_i[j] == i) wb_gpr_dec[j][i] = wb_gpr_en_i[j];
        else wb_gpr_dec[j][i] = 1'b0;
      end
    end
  end

  always_comb begin : wb_fpr_decoder
    for (int unsigned j = 0; j < NrWritePorts; j++) begin
      for (int unsigned i = 0; i < NumRegs; i++) begin
        if (wb_fpr_addr_i[j] == i) wb_fpr_dec[j][i] = wb_fpr_en_i[j];
        else wb_fpr_dec[j][i] = 1'b0;
      end
    end
  end

  always_comb begin : scoreboard_update
    sbi_d = sbi_q;
    sbf_d = sbf_q;

    // For every dispatched instruction we have to set the scoreboard entry
    // this means that this register currently is busy (waiting on the result)
    for (int unsigned j = 0; j < PipeWidth; j++) begin
        for (int unsigned i = 0; i < NumRegs; i++) begin
          if (disp_dec[j][i]) begin
            if (disp_data_i[j].rd_is_fp) begin
              sbf_d[i] = 1'b1;
            end else begin
              sbi_d[i] = 1'b1;
            end
          end
        end
    end

    // We remove the busy bit for every write back that happens
    for (int unsigned j = 0; j < NrWritePorts; j++) begin
        for (int unsigned i = 0; i < NumRegs; i++) begin
          if (wb_fpr_dec[j][i]) begin
            sbf_d[i] = 1'b0;
          end
        end
    end
  
    for (int unsigned j = 0; j < NrWritePorts; j++) begin
        for (int unsigned i = 0; i < NumRegs; i++) begin
          if (wb_gpr_dec[j][i]) begin
            sbi_d[i] = 1'b0;
          end
        end
    end

    // x0 is always not busy, we can't write to that register
    sbi_d[0] = 1'b0;
  end

  ///////////////////////////
  // Registers ready check //
  ///////////////////////////

  // This is only needed in scalar execution mode, and in that case only the first instruction
  // is relevant.

  //////////////////////
  // RAW dependencies //
  //////////////////////

  // This checks the scoreboard for RAW conflicts using the decoded register addresses.
  // These addresses and the rx_is_fp signals default to zero. If a register is not used,
  // any lookup will check x0 which is always ready (hardwired to zero value, read only).

  logic op_a_has_raw, op_b_has_raw, op_c_has_raw;
  logic operands_ready;

  assign op_a_has_raw = disp_data_i[0].rs1_is_fp ? sbf_q[disp_data_i[0].rs1] : sbi_q[disp_data_i[0].rs1];
  assign op_b_has_raw = disp_data_i[0].rs2_is_fp ? sbf_q[disp_data_i[0].rs2] : sbi_q[disp_data_i[0].rs2];
  // The fused FP instruction have three source registers and the third one can only access
  // the FP regfile. For any other instruction operand c is always ready.
  assign op_c_has_raw = disp_data_i[0].use_imm_as_rs3 ? sbf_q[disp_data_i[0].rs3] :
                        1'b0;

  assign operands_ready = !(op_a_has_raw || op_b_has_raw || op_c_has_raw);

  //////////////////////
  // WAW dependencies //
  //////////////////////

  // Check that there is no WAW dependency to the destination register.

  logic dest_has_waw;
  logic destination_ready;

  assign dest_has_waw = disp_data_i[0].rd_is_fp  ? sbf_q[disp_data_i[0].rd]  : sbi_q[disp_data_i[0].rd];
  assign destination_ready = !dest_has_waw;

  // The registers are ready if both the operands and destination are ready
  assign registers_ready_o = en_superscalar_i ? 1'b1 : operands_ready & destination_ready;
  // The scoreboard is busy as soon as one entry is busy in either of the registers
  logic fpr_busy, gpr_busy;

  assign fpr_busy = |sbf_q;
  assign gpr_busy = |sbi_q;
  assign sb_busy_o = fpr_busy | gpr_busy;
endmodule
