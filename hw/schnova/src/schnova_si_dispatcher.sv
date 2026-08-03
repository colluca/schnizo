// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

// Single Issue Dispatcher
// Dispatches instructions to the first functional unit of a type.
// Is used in single-issue mode.
module schnova_si_dispatcher import schnova_pkg::*; #(
  parameter int unsigned XLEN        = 1,
  parameter int unsigned NofAlus     = 1,
  parameter int unsigned NofLsus     = 1,
  parameter int unsigned NofFpus     = 1,
  parameter type         instr_dec_t = logic,
  parameter type         instr_tag_t = logic,
  parameter type         csr_disp_req_t = logic,
  parameter type         alu_si_disp_req_t = logic,
  parameter type         lsu_si_disp_req_t = logic,
  parameter type         fpu_si_disp_req_t = logic,
  parameter type         disp_rsp_t    = logic,
  parameter type         producer_id_t = logic,
  parameter type         rs_id_t       = logic,
  parameter type         reg_map_t = logic,
  parameter type         fu_data_t   = logic,
  parameter type         acc_req_t   = logic
) (
  input  logic            clk_i,
  input  logic            rst_i,
  // Handshake to dispatch instruction consisting of instr_dec_i and instr_fu_data_i
  input  instr_dec_t      instr_dec_i,
  input  fu_data_t        instr_fu_data_i,
  input  logic [31:0]     instr_fetch_data_i,
  input  logic            instr_valid_i,
  input  logic            dispatch_valid_i,
  output logic            dispatched_o,
  input  logic            instr_exec_commit_i,
  // From rename stage
  input  reg_map_t        reg_map_i,
  // Each FU has a response which must be valid at dispatch request handshake.
  // ALU
  output alu_si_disp_req_t alu_si_disp_req_o,
  output logic             alu_si_disp_req_valid_o,
  input  logic             alu_si_disp_req_ready_i,
  // LSU
  output lsu_si_disp_req_t lsu_si_disp_req_o,
  output logic             lsu_si_disp_req_valid_o,
  input  logic             lsu_si_disp_req_ready_i,
  // Handshake to the CSR FU. There is no response as it does not have a reservation station.
  output csr_disp_req_t    csr_disp_req_o,
  output logic             csr_disp_req_valid_o,
  input  logic             csr_disp_req_ready_i,

  // FPU
  output fpu_si_disp_req_t fpu_si_disp_req_o,
  output logic             fpu_si_disp_req_valid_o,
  input  logic             fpu_si_disp_req_ready_i,
  // Handshake to the accelerator interface
  output acc_req_t         acc_req_o,
  output logic             acc_disp_req_valid_o,
  input  logic             acc_disp_req_ready_i
);

  // Each RS needs a globally unique ID. We simply count all RS.
  localparam integer unsigned AluRsIdOffset = 0;
  localparam integer unsigned LsuRsIdOffset = AluRsIdOffset + NofAlus;
  localparam integer unsigned FpuRsIdOffset = LsuRsIdOffset + NofLsus;

  // Generate generic alu responses, in Single Issue Mode we never dispatch to the Reservation stations
  // And dispatch is always targeting the first FU of a type so the fu response is constant
  producer_id_t alu0_producer_id;
  producer_id_t lsu0_producer_id;
  producer_id_t fpu0_producer_id;

  assign alu0_producer_id = '{
    slot_id: '0,
    rs_id  : rs_id_t'(AluRsIdOffset)
  };

  assign lsu0_producer_id = '{
    slot_id: '0,
    rs_id  : rs_id_t'(LsuRsIdOffset)
  };

  assign fpu0_producer_id = '{
    slot_id: '0,
    rs_id  : rs_id_t'(FpuRsIdOffset)
  };


  instr_tag_t tag;
  logic       fu_ready;
  disp_rsp_t  fu_response;

  // Dispatch requeset generation
  always_comb begin : si_dispatch_generation
    acc_req_o         = '0;
    csr_disp_req_o    = '0;
    alu_si_disp_req_o = '0;
    lsu_si_disp_req_o = '0;
    fpu_si_disp_req_o = '0;

    // We only ever have to consider the first instruction
    // pragma translate_off
    tag.producer_id = fu_response.producer; // Only needed for the tracer
    // pragma translate_on
    tag.dest_reg       = reg_map_i.phy_reg_rd_old;
    tag.dest_reg_is_fp = instr_dec_i.rd_is_fp;
    tag.is_branch      = instr_dec_i.is_branch;
    tag.is_jump        = instr_dec_i.is_jal | instr_dec_i.is_jalr;
    tag.rob_tag        = '0;

    // ACC
    acc_req_o.id        = tag.dest_reg;
    acc_req_o.data_op   = instr_fetch_data_i;
    acc_req_o.addr      = (instr_dec_i.fu == schnova_pkg::MULDIV) ? snitch_pkg::IPU
                                                                  : snitch_pkg::DMA_SS;
    acc_req_o.data_arga = instr_fu_data_i.operand_a;
    acc_req_o.data_argb = instr_fu_data_i.operand_b;
    acc_req_o.data_argc = '0; // Unused

    // CSR
    csr_disp_req_o.csr_op    = instr_fu_data_i.csr_op;
    csr_disp_req_o.operand_a = instr_fu_data_i.operand_a;
    csr_disp_req_o.imm       = instr_fu_data_i.imm[11:0];
    csr_disp_req_o.tag       = tag;

    // ALU
    alu_si_disp_req_o.alu_op    = instr_fu_data_i.alu_op;
    alu_si_disp_req_o.operand_a = instr_fu_data_i.operand_a[XLEN-1:0];
    alu_si_disp_req_o.operand_b = instr_fu_data_i.operand_b[XLEN-1:0];
    alu_si_disp_req_o.tag       = tag;

    // LSU
    lsu_si_disp_req_o.lsu_op    = instr_fu_data_i.lsu_op;
    lsu_si_disp_req_o.operand_a = instr_fu_data_i.operand_a[XLEN-1:0];
    lsu_si_disp_req_o.operand_b = instr_fu_data_i.operand_b;
    lsu_si_disp_req_o.imm       = instr_fu_data_i.imm[XLEN-1:0];
    lsu_si_disp_req_o.lsu_size  = instr_fu_data_i.lsu_size;
    lsu_si_disp_req_o.tag       = tag;

    // FPR
    fpu_si_disp_req_o.fpu_op       = instr_fu_data_i.fpu_op;
    fpu_si_disp_req_o.operand_a    = instr_fu_data_i.operand_a;
    fpu_si_disp_req_o.operand_b    = instr_fu_data_i.operand_b;
    fpu_si_disp_req_o.imm          = instr_fu_data_i.imm;
    fpu_si_disp_req_o.fpu_fmt_src  = instr_fu_data_i.fpu_fmt_src;
    fpu_si_disp_req_o.fpu_fmt_dst  = instr_fu_data_i.fpu_fmt_dst;
    fpu_si_disp_req_o.fpu_rnd_mode = instr_fu_data_i.fpu_rnd_mode;
    fpu_si_disp_req_o.tag          = tag;
  end

  // Dispatch request and response muxing
  always_comb begin: si_disp_req_rsp_mux
    // Default assignments
    acc_disp_req_valid_o    = 1'b0;
    csr_disp_req_valid_o    = 1'b0;
    alu_si_disp_req_valid_o = 1'b0;
    lsu_si_disp_req_valid_o = 1'b0;
    fpu_si_disp_req_valid_o = 1'b0;

    fu_response          = '0;
    fu_ready             = 1'b0;

    unique case (instr_dec_i.fu)
      schnova_pkg::MUL,
      schnova_pkg::CTRL_FLOW,
      schnova_pkg::ALU: begin
        alu_si_disp_req_valid_o = dispatch_valid_i;
        fu_ready             = alu_si_disp_req_ready_i;
        fu_response.producer = alu0_producer_id;
      end
      schnova_pkg::LOAD,
      schnova_pkg::STORE: begin
        lsu_si_disp_req_valid_o = dispatch_valid_i;
        fu_ready             = lsu_si_disp_req_ready_i;
        fu_response.producer = lsu0_producer_id;
      end
      schnova_pkg::CSR : begin
        // There is no response because there is no reservation station.
        csr_disp_req_valid_o = dispatch_valid_i;
        fu_ready          = csr_disp_req_ready_i;
      end
      schnova_pkg::FPU: begin
        fpu_si_disp_req_valid_o = dispatch_valid_i;
        fu_ready             = fpu_si_disp_req_ready_i;
        fu_response.producer = fpu0_producer_id;
      end
      schnova_pkg::MULDIV,
      schnova_pkg::DMA: begin
        acc_disp_req_valid_o = dispatch_valid_i;
        fu_ready          = acc_disp_req_ready_i;
      end
      schnova_pkg::NONE: begin
        // There is no FU, so we always signal ready
        fu_ready         = 1'b1;
      end
    endcase
  end

  assign dispatched_o = instr_valid_i & fu_ready & instr_exec_commit_i;

endmodule
