// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: The dispatcher module which accesses the RMT and selects the FU.

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

module schnizo_dispatcher import schnizo_pkg::*; #(
  // Enable the superscalar feature
  parameter bit          FREP_EN     = 1,
  /// Size of both int and fp register file
  parameter int unsigned RegAddrSize = 5,
  parameter int unsigned NofAlus     = 1,
  parameter int unsigned NofLsus     = 1,
  parameter int unsigned NofFpus     = 1,
  parameter type         instr_dec_t = logic,
  parameter type         rmt_entry_t = logic,
  parameter type         disp_req_t  = logic,
  parameter type         disp_rsp_t  = logic,
  parameter type         fu_data_t   = logic,
  parameter type         acc_req_t   = logic
) (
  input  logic         clk_i,
  input  logic         rst_i,
  // Handshake to dispatch instruction consisting of instr_dec_i and instr_fu_data_i
  input  instr_dec_t   instr_dec_i,
  input  fu_data_t     instr_fu_data_i,
  input  logic [31:0]  instr_fetch_data_i,
  input  logic         dispatch_valid_i,
  output logic         dispatch_ready_o,
  input  logic         instr_exec_commit_i,

  // Handshake to all possible FUs. Each FU has own ready/valid interface.
  output disp_req_t disp_req_o,
  // Each FU has a response which must be valid at dispatch request handshake.
  // ALU
  output logic      [NofAlus-1:0] alu_disp_req_valid_o,
  input  logic      [NofAlus-1:0] alu_disp_req_ready_i,
  input  disp_rsp_t [NofAlus-1:0] alu_disp_rsp_i,
  input  logic      [NofAlus-1:0] alu_rs_full_i,

  // LSU
  output logic      [NofLsus-1:0] lsu_disp_req_valid_o,
  input  logic      [NofLsus-1:0] lsu_disp_req_ready_i,
  input  disp_rsp_t [NofLsus-1:0] lsu_disp_rsp_i,
  input  logic      [NofLsus-1:0] lsu_rs_full_i,

  // Handshake to the CSR FU. There is no response as it does not have a reservation station.
  output logic csr_disp_req_valid_o,
  input  logic csr_disp_req_ready_i,

  // FPU
  output logic      [NofFpus-1:0] fpu_disp_req_valid_o,
  input  logic      [NofFpus-1:0] fpu_disp_req_ready_i,
  input  disp_rsp_t [NofFpus-1:0] fpu_disp_rsp_i,
  input  logic      [NofFpus-1:0] fpu_rs_full_i,

  // Handshake to the accelerator interface
  output acc_req_t acc_req_o,
  output logic     acc_disp_req_valid_o,
  input  logic     acc_disp_req_ready_i,
  // The accelerator response is routed directly to the write back.

  // RS control signals
  // Asserted if the RSS are cleared synchronously.
  input  logic        restart_i,
  input  loop_state_e loop_state_i,
  // Asserted in the last LCP1 cycle (the cycle before we start LCP2)
  input  logic        goto_lcp2_i,
  // Memory consistency mode during FREP loop
  input frep_mem_cons_mode_e frep_mem_cons_mode_i,
  // Asserted if the currently selected FU for the instruction does not have an empty RSS.
  output logic        rs_full_o
);
  localparam int unsigned NofAlusW = cf_math_pkg::idx_width(NofAlus);
  localparam int unsigned NofLsusW = cf_math_pkg::idx_width(NofLsus);
  localparam int unsigned NofFpusW = cf_math_pkg::idx_width(NofFpus);

  // ---------------------------
  // Register Mapping Table (RMT)
  // ---------------------------
  // Two RMT for the integer (rmti) and floating point register (rmtf) file.
  rmt_entry_t [2**RegAddrSize-1:0] rmti_d, rmti_q, rmtf_d, rmtf_q;
if (FREP_EN) begin : gen_rmt_ff
  `FFAR(rmti_q, rmti_d, '0, clk_i, rst_i)
  `FFAR(rmtf_q, rmtf_d, '0, clk_i, rst_i)
end else begin : gen_no_rmt_ff
  assign rmti_q = '0;
  assign rmti_d = '0;
  assign rmtf_q = '0;
  assign rmtf_d = '0;
end

  // ---------------------------
  // Request generation
  // ---------------------------
  // read from RMT (register map table) and set the data

  rmt_entry_t no_mapping;
  assign no_mapping = '{
    producer:    '0,
    is_produced: '0
  };

  always_comb begin : dispatch_generation
    disp_req_o = '0;
    disp_req_o.fu_data = instr_fu_data_i;

    // Producer fields are only used if FREP_EN
    if (FREP_EN) begin
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
    end else begin
      disp_req_o.producer_op_a         = '0;
      disp_req_o.producer_op_b         = '0;
      disp_req_o.producer_op_c         = '0;
      disp_req_o.current_producer_dest = '0;
    end

    // generate the tag
    disp_req_o.tag.dest_reg       = instr_dec_i.rd;
    disp_req_o.tag.dest_reg_is_fp = instr_dec_i.rd_is_fp;
    disp_req_o.tag.is_branch      = instr_dec_i.is_branch;
    disp_req_o.tag.is_jump        = instr_dec_i.is_jal | instr_dec_i.is_jalr;
  end

  // ---------------------------
  // FU selection
  // ---------------------------
  // Signal valid to the FU we want the instruction to dispatch into.
  // Select the appropriate response channel.
  logic       fu_ready;
  logic       fu_rs_full;
  disp_rsp_t  fu_response;
  logic       dispatched;
  logic [NofAlus-1:0] alu_disp_req_valid_raw;
  logic [NofLsus-1:0] lsu_disp_req_valid_raw;
  logic               csr_disp_req_valid_raw;
  logic [NofFpus-1:0] fpu_disp_req_valid_raw;
  logic               acc_disp_req_valid_raw;

  // FU selection counters
  logic [NofAlusW-1:0] alu_idx;
  logic [NofAlusW-1:0] alu_idx_raw;
  logic [NofLsusW-1:0] lsu_idx;
  logic [NofLsusW-1:0] lsu_idx_raw;
  logic [NofFpusW-1:0] fpu_idx;
  logic [NofFpusW-1:0] fpu_idx_raw;

  // This FU selection must occur always independently of the validity of the instruction and it
  // may never combine any signals with the valid signal. This is required because this block can
  // generate errors which will kill the instruction and therefore a loop would be created.
  always_comb begin : fu_selection_disp
    alu_disp_req_valid_raw = '0;
    lsu_disp_req_valid_raw = '0;
    csr_disp_req_valid_raw = 1'b0;
    fpu_disp_req_valid_raw = '0;
    acc_disp_req_valid_raw = 1'b0;

    acc_req_o         = '0;
    acc_req_o.id      = instr_dec_i.rd; // TODO: currently only GPR address supported
    acc_req_o.data_op = instr_fetch_data_i;

    unique case (instr_dec_i.fu)
      schnizo_pkg::CTRL_FLOW: begin
        // always select ALU0 for branch instructions
        alu_disp_req_valid_raw[0] = 1'b1;
      end
      schnizo_pkg::ALU: begin
        alu_disp_req_valid_raw[alu_idx] = 1'b1;
      end
      schnizo_pkg::LOAD,
      schnizo_pkg::STORE: begin
        lsu_disp_req_valid_raw[lsu_idx] = 1'b1;
      end
      schnizo_pkg::CSR : begin
        csr_disp_req_valid_raw = 1'b1;
      end
      schnizo_pkg::FPU: begin
        fpu_disp_req_valid_raw[fpu_idx] = 1'b1;
      end
      schnizo_pkg::MULDIV: begin
        acc_disp_req_valid_raw = 1'b1;
        acc_req_o.addr         = snitch_pkg::SHARED_MULDIV; // TODO: use schnizo defined address.
        acc_req_o.data_arga    = instr_fu_data_i.operand_a;
        acc_req_o.data_argb    = instr_fu_data_i.operand_b;
        acc_req_o.data_argc    = '0; // unused for shared muldiv
      end
      schnizo_pkg::DMA: begin
        acc_disp_req_valid_raw = 1'b1;
        acc_req_o.addr         = snitch_pkg::DMA_SS; // TODO: use schnizo defined address.
        acc_req_o.data_arga    = instr_fu_data_i.operand_a;
        acc_req_o.data_argb    = instr_fu_data_i.operand_b;
        acc_req_o.data_argc    = '0; // unused for DMA
      end
      schnizo_pkg::NONE, schnizo_pkg::SPATZ: begin //TODO: add spatz handling
        // No FU selected, do nothing.
      end
      default: begin
        // CRASH - should never happen as long as decoder returns valid decoding.
        // TODO: handle crash
      end
    endcase
  end

  // We may not dispatch any None-FU instruction during LEP
  logic in_lep;
  assign in_lep = loop_state_i inside {LoopLep};

  always_comb begin : fu_selection_ready
    fu_response = '0;
    fu_ready    = 1'b0;
    fu_rs_full  = 1'b0;

    unique case(instr_dec_i.fu)
      schnizo_pkg::CTRL_FLOW: begin
        // always select ALU0 for branch instructions
        fu_response = alu_disp_rsp_i[0];
        fu_ready    = alu_disp_req_ready_i[0];
        fu_rs_full  = alu_rs_full_i[0];
      end
      schnizo_pkg::ALU: begin
        fu_response = alu_disp_rsp_i[alu_idx];
        fu_ready    = alu_disp_req_ready_i[alu_idx];
        fu_rs_full  = alu_rs_full_i[alu_idx];
      end
      schnizo_pkg::LOAD,
      schnizo_pkg::STORE: begin
        // per default take the non consistent mode.
        fu_response = lsu_disp_rsp_i[lsu_idx];
        fu_ready    = lsu_disp_req_ready_i[lsu_idx];
        fu_rs_full  = lsu_rs_full_i[lsu_idx];
      end
      schnizo_pkg::CSR : begin
        // There is no response because there is no reservation station.
        fu_ready = csr_disp_req_ready_i;
      end
      schnizo_pkg::FPU: begin
        fu_response = fpu_disp_rsp_i[fpu_idx];
        fu_ready    = fpu_disp_req_ready_i[fpu_idx];
        fu_rs_full  = fpu_rs_full_i[fpu_idx];
      end
      schnizo_pkg::MULDIV: begin
        // no dispatch response
        fu_ready = acc_disp_req_ready_i;
      end
      schnizo_pkg::DMA: begin
        // no dispatch response
        fu_ready = acc_disp_req_ready_i;
      end
      schnizo_pkg::NONE: begin
        // No FU selected, do nothing. Signal ready to controller.
        // But we must stall if there is an ongoing FREP loop.
        fu_ready = in_lep ? 1'b0 : 1'b1;
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
  assign alu_disp_req_valid_o = {NofAlus{dispatch_valid_i}} & alu_disp_req_valid_raw;
  assign lsu_disp_req_valid_o = {NofLsus{dispatch_valid_i}} & lsu_disp_req_valid_raw;
  assign csr_disp_req_valid_o =          dispatch_valid_i   & csr_disp_req_valid_raw;
  assign fpu_disp_req_valid_o = {NofFpus{dispatch_valid_i}} & fpu_disp_req_valid_raw;
  assign acc_disp_req_valid_o =          dispatch_valid_i   & acc_disp_req_valid_raw;
  // The NONE FU always dispatches

  assign dispatched = instr_exec_commit_i & fu_ready;

  // Signal back the dispatch
  assign dispatch_ready_o = dispatched;

  // Asserted if the currently selected FU has no empty RSS.
  assign rs_full_o = fu_rs_full;

if (FREP_EN) begin : gen_fu_sel_cnts
  // ---------------------------
  // FU selection counters
  // ---------------------------
  logic alu_idx_inc;
  logic lsu_idx_inc;
  logic fpu_idx_inc;
  logic alu_idx_reset;
  logic lsu_idx_reset;
  logic fpu_idx_reset;

  // Only select the counters during FREP. Without this the first instruction after LEP would be
  // executed on the "next" FU instead of the zero-th.
  assign alu_idx = (loop_state_i inside {LoopLcp1, LoopLcp2, LoopLep}) ? alu_idx_raw : '0;
  assign lsu_idx = (loop_state_i inside {LoopLcp1, LoopLcp2, LoopLep}) ? lsu_idx_raw : '0;
  assign fpu_idx = (loop_state_i inside {LoopLcp1, LoopLcp2, LoopLep}) ? fpu_idx_raw : '0;

  // Reset at wrap around at dispatch or when switching to LCP2 or when restarting LxP
  assign alu_idx_reset = ((alu_idx_raw == ((NofAlus[NofAlusW-1:0])-1)) && alu_idx_inc)
                         || goto_lcp2_i || restart_i;
  assign lsu_idx_reset = ((lsu_idx_raw == ((NofLsus[NofLsusW-1:0])-1)) && lsu_idx_inc)
                         || goto_lcp2_i || restart_i;
  assign fpu_idx_reset = ((fpu_idx_raw == ((NofFpus[NofFpusW-1:0])-1)) && fpu_idx_inc)
                         || goto_lcp2_i || restart_i;

  always_comb begin : dispatch_fu_selection
    alu_idx_inc = 1'b0;
    lsu_idx_inc = 1'b0;
    fpu_idx_inc = 1'b0;

    unique case(loop_state_i)
      LoopRegular,
      LoopHwLoop: begin
        alu_idx_inc = 1'b0;
        lsu_idx_inc = 1'b0;
        fpu_idx_inc = 1'b0;
      end
      LoopLcp1,
      LoopLcp2: begin
        // Increment the counter if we dispatched into the FU during LCP
        alu_idx_inc = (|(alu_disp_req_valid_o & alu_disp_req_ready_i));
        lsu_idx_inc = (|(lsu_disp_req_valid_o & lsu_disp_req_ready_i));
        // Do not increment index if we want serialized memory accesses
        if (frep_mem_cons_mode_i inside {FREP_MEM_SERIALIZED}) begin
          lsu_idx_inc = 1'b0;
        end
        fpu_idx_inc = (|(fpu_disp_req_valid_o & fpu_disp_req_ready_i));
      end
      LoopLep: ; // do nothing
      default: ; // do nothing
    endcase
  end

  counter #(
    .WIDTH          (NofAlusW),
    .STICKY_OVERFLOW(0)
  ) i_alu_idx_counter (
    .clk_i,
    .rst_ni    (~rst_i),
    .clear_i   (alu_idx_reset),
    .en_i      (alu_idx_inc),
    .load_i    ('0),
    .down_i    ('0),
    .d_i       ('0),
    .q_o       (alu_idx_raw),
    .overflow_o()
  );

  counter #(
    .WIDTH          (NofLsusW),
    .STICKY_OVERFLOW(0)
  ) i_lsu_idx_counter (
    .clk_i,
    .rst_ni    (~rst_i),
    .clear_i   (lsu_idx_reset),
    .en_i      (lsu_idx_inc),
    .load_i    ('0),
    .down_i    ('0),
    .d_i       ('0),
    .q_o       (lsu_idx_raw),
    .overflow_o()
  );

  counter #(
    .WIDTH          (NofFpusW),
    .STICKY_OVERFLOW(0)
  ) i_fpu_idx_counter (
    .clk_i,
    .rst_ni    (~rst_i),
    .clear_i   (fpu_idx_reset),
    .en_i      (fpu_idx_inc),
    .load_i    ('0),
    .down_i    ('0),
    .d_i       ('0),
    .q_o       (fpu_idx_raw),
    .overflow_o()
  );
end else begin : gen_fix_fu_sel
  // Always take the first FU
  assign alu_idx     = '0;
  assign lsu_idx     = '0;
  assign fpu_idx     = '0;
  assign alu_idx_raw = '0;
  assign lsu_idx_raw = '0;
  assign fpu_idx_raw = '0;
end

if (FREP_EN) begin : gen_rmt
  // ---------------------------
  // Register mapping table (RMT) Update
  // ---------------------------
  // The RMT captures which RSS produces a value such that dependent instructions know from where
  // to fetch their operands. We create or update a mapping depending on the LxP state.
  // - In LCP1 we always create or update the mapping.
  // - In LCP2 we may only create new mappings.
  //     -> I.e., if there is already a mapping, we may not update the mapping.
  // - In LEP there should be no dispatching.. For debug purposes we don't reset the mapping in LEP
  // - In any other state we can reset the RMT.
  always_comb begin : rmt_update
    automatic rmt_entry_t new_entry;
    automatic rmt_entry_t current_entry;
    automatic rmt_entry_t reset_entry;

    rmti_d = rmti_q;
    rmtf_d = rmtf_q;

    new_entry.producer    = fu_response.producer;
    new_entry.is_produced = 1'b1;

    reset_entry.producer    = '0;
    reset_entry.is_produced = 1'b0;

    current_entry = instr_dec_i.rd_is_fp ? rmtf_q[instr_dec_i.rd] : rmti_q[instr_dec_i.rd];

    unique case(loop_state_i)
      LoopRegular,
      LoopHwLoop: begin
        // Reset the RMT
        rmti_d = '0;
        rmtf_d = '0;
      end
      LoopLcp1: begin
        // Always create or update the mapping at dispatch
        if (dispatched) begin
          if (instr_dec_i.rd_is_fp) begin
            rmtf_d[instr_dec_i.rd] = new_entry;
          end else begin
            rmti_d[instr_dec_i.rd] = new_entry;
          end
        end
      end
      LoopLcp2: begin
        // Create a mapping if no mapping exists yet at dispatch
        if (dispatched && !current_entry.is_produced) begin
          if (instr_dec_i.rd_is_fp) begin
            rmtf_d[instr_dec_i.rd] = new_entry;
          end else begin
            rmti_d[instr_dec_i.rd] = new_entry;
          end
        end
      end
      LoopLep: ; // do nothing
      default: begin
        // Reset the RMT
        rmti_d = '0;
        rmtf_d = '0;
      end
    endcase

    // register x0 can never be produced.
    rmti_d[0] = reset_entry;
  end
end

  // Assert that only one dispatch request is set at a time
  // TODO: How to suppress spikes at beginning of cycle?
  // `ASSERT(MoreThanOneValid, !$onehot0({alu_disp_req_valid_o, lsu_disp_req_valid_o,
  //                                      csr_disp_req_valid_o, fpu_disp_req_valid_o,
  //                                      acc_disp_req_valid_o}),
  //         clk_i, rst_i, "Only one dispatch request may be valid at a time");
endmodule
