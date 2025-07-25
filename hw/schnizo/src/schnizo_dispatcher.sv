// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: The dispatcher module which accesses the RMT and selects the FU.

`include "common_cells/registers.svh"

module schnizo_dispatcher import schnizo_pkg::*; #(
  /// Size of both int and fp register file
  parameter int unsigned RegAddrSize = 5,
  parameter type         instr_dec_t = logic,
  parameter type         rmt_entry_t = logic,
  parameter type         disp_req_t = logic,
  parameter type         disp_res_t = logic,
  parameter type         fu_data_t = logic
) (
  input  logic         clk_i,
  input  logic         rst_i,
  // Handshake to dispatch instruction consisting of instr_dec_i and instr_fu_data_i
  input  instr_dec_t   instr_dec_i,
  input  fu_data_t     instr_fu_data_i,
  input  logic         instr_dec_valid_i,
  output logic         instr_dec_ready_o,

  // Handshake to all possible FUs. Each FU has own ready/valid interface.
  output disp_req_t disp_req_o,
  // Each FU has a response which must be valid at dispatch request handshake.
  // ALU
  output logic[0:0] alu_disp_req_valid_o,
  input  logic[0:0] alu_disp_req_ready_i,
  input  disp_res_t alu_disp_res_i,

  // LSU
  output logic[0:0] lsu_disp_req_valid_o,
  input  logic[0:0] lsu_disp_req_ready_i,
  input  disp_res_t lsu_disp_res_i,

  // Handshake to the CSR FU. There is no response as it does not have a reservation station.
  output logic csr_disp_req_valid_o,
  input  logic csr_disp_req_ready_i,

  // FPU
  output logic      fpu_disp_req_valid_o,
  input  logic      fpu_disp_req_ready_i,
  input  disp_res_t fpu_disp_res_i
);
  // ---------------------------
  // Register Mapping Table (RMT)
  // ---------------------------
  // Two RMT for the integer (rmti) and floating point register (rmtf) file.
  rmt_entry_t [2**RegAddrSize-1:0] rmti_d, rmti_q, rmtf_d, rmtf_q;
  `FFAR(rmti_q, rmti_d, '0, clk_i, rst_i)
  `FFAR(rmtf_q, rmtf_d, '0, clk_i, rst_i)

  // ---------------------------
  // Request generation
  // ---------------------------
  // read from RMT (register map table) and set the data

  rmt_entry_t no_mapping;
  assign no_mapping = '{
    prod_id: '0,
    is_produced: '0
  };

  always_comb begin : dispatch_generation
    disp_req_o = '0;
    disp_req_o.fu_data = instr_fu_data_i;

    // Operand A
    disp_req_o.producer_op_a = instr_dec_i.rs1_is_fp ? rmtf_q[instr_dec_i.rs1] :
                                                       rmti_q[instr_dec_i.rs1];

    // Operand B
    disp_req_o.producer_op_b = instr_dec_i.rs2_is_fp ? rmtf_q[instr_dec_i.rs2] :
                                                       rmti_q[instr_dec_i.rs2];

    // Operand C
    disp_req_o.producer_op_c = instr_dec_i.use_imm_as_rs3 ?
                                 rmtf_q[instr_dec_i.imm[RegAddrSize-1:0]] :
                                 no_mapping;

    // current destination producer
    disp_req_o.current_producer_dest = instr_dec_i.rd_is_fp ? rmtf_q[instr_dec_i.rd] :
                                                              rmti_q[instr_dec_i.rd];

    // generate the tag
    disp_req_o.tag.dest_reg = instr_dec_i.rd;
    disp_req_o.tag.dest_reg_is_fp = instr_dec_i.rd_is_fp;
    disp_req_o.tag.is_branch = instr_dec_i.is_branch;
    disp_req_o.tag.is_jump = instr_dec_i.is_jal | instr_dec_i.is_jalr;
  end

  // ---------------------------
  // FU selection
  // ---------------------------
  // Signal valid to the FU we want the instruction to dispatch into.
  // Select the appropriate response channel.
  logic       disp_req_valid;
  logic       fu_ready;
  disp_res_t  fu_response;
  logic       dispatched;
  logic [0:0] alu_disp_req_valid_raw;
  logic [0:0] lsu_disp_req_valid_raw;
  logic       csr_disp_req_valid_raw;
  logic       fpu_disp_req_valid_raw;
  logic       none_disp_req_valid_raw;
  always_comb begin : fu_selection
    alu_disp_req_valid_raw = 1'b0;
    lsu_disp_req_valid_raw = 1'b0;
    csr_disp_req_valid_raw = 1'b0;
    fpu_disp_req_valid_raw = 1'b0;
    fu_response = '0;
    fu_ready    = 1'b0;

    unique case (instr_dec_i.fu)
      schnizo_pkg::ALU,
      schnizo_pkg::CTRL_FLOW: begin
        // TODO: select the current ALU for arbitration between multiple ALUs (counter?)
        // TODO: select only one specific ALU for CTRL_FLOW
        alu_disp_req_valid_raw = 1'b1; // [i] = 1'b1;
        fu_response = alu_disp_res_i; // [i];
        fu_ready = alu_disp_req_ready_i; // [i];
      end
      schnizo_pkg::LOAD,
      schnizo_pkg::STORE: begin
        lsu_disp_req_valid_raw = 1'b1;
        fu_response = lsu_disp_res_i;
        fu_ready = lsu_disp_req_ready_i;
      end
      schnizo_pkg::CSR : begin
        csr_disp_req_valid_raw = 1'b1;
        fu_response = '0; // There is no response because there is no reservation station.
        fu_ready = csr_disp_req_ready_i;
      end
      schnizo_pkg::FPU: begin
        fpu_disp_req_valid_raw = 1'b1;
        fu_response = fpu_disp_res_i;
        fu_ready = fpu_disp_req_ready_i;
      end
      schnizo_pkg::NONE: begin
        // No FU selected, do nothing. Signal ready to controller.
        none_disp_req_valid_raw = 1'b1;
        fu_ready = 1'b1;
      end
      default: begin
        // CRASH - should never happen as long as decoder returns valid decoding.
        // TODO: handle crash
      end
    endcase
  end

  // ---------------------------
  // Dispatch logic
  // ---------------------------
  // We may only dispatch the instruction if it is valid.
  assign alu_disp_req_valid_o = instr_dec_valid_i & alu_disp_req_valid_raw;
  assign lsu_disp_req_valid_o = instr_dec_valid_i & lsu_disp_req_valid_raw;
  assign csr_disp_req_valid_o = instr_dec_valid_i & csr_disp_req_valid_raw;
  assign fpu_disp_req_valid_o = instr_dec_valid_i & fpu_disp_req_valid_raw;

  // The NONE FU always dispatches
  logic none_disp_req_valid;
  assign none_disp_req_valid = instr_dec_valid_i & none_disp_req_valid_raw;

  // The instruction is dispatched when the FU handshakes the request
  assign disp_req_valid = alu_disp_req_valid_o | lsu_disp_req_valid_o |
                          csr_disp_req_valid_o | fpu_disp_req_valid_o |
                          none_disp_req_valid;
  assign dispatched = disp_req_valid & fu_ready;
  // Signal back the dispatch
  assign instr_dec_ready_o = dispatched; // valid signal is factored in via disp_req_valid

  // ---------------------------
  // RMT Update
  // ---------------------------
  // Each time an instruction is dispatched successfully, we need to capture the new producer.
  always_comb begin : rmt_update
    automatic rmt_entry_t rmt_entry;
    rmt_entry = '0;

    rmti_d = rmti_q;
    rmtf_d = rmtf_q;

    // create / update entry for dispatched instruction
    if (dispatched) begin
      rmt_entry.prod_id = fu_response.prod_id;
      rmt_entry.is_produced = 1'b1;
      if (instr_dec_i.rd_is_fp) begin
        rmtf_d[instr_dec_i.rd] = rmt_entry;
      end else begin
        rmti_d[instr_dec_i.rd] = rmt_entry;
      end
    end
  end

endmodule
