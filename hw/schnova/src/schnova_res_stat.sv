// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

// The Reservation station which handles the instruction issuing of a functional unit during
// superscalar loop execution.
//
// Abbreviations:
// FU:  Functional Unit. This is for example an ALU, FPU or LSU.
// RS:  Reservation Station. Holds multiple RSS for a single FU and controls the execution.
// RSS: Reservation Station Slot. A slot can hold one instruction with all the required
//      information for the superscalar execution.
// RF:  Register File
module schnova_res_stat import schnizo_pkg::*; #(
  parameter int unsigned NofRss         = 4,
  // The maximal number of operands
  parameter int unsigned NofOperands    = 3,
  parameter int unsigned NofResRspIfs   = 1,
  // The bits to address all registers
  parameter int unsigned RegAddrWidth   = 5,
  parameter int unsigned MaxIterationsW = 5,
  parameter bit          UseSram        = 1'b0,
  parameter type         disp_req_t     = logic,
  parameter type         disp_rsp_t     = logic,
  parameter type         issue_req_t    = logic,
  parameter type         result_t       = logic,
  parameter type         instr_tag_t   = logic,
  parameter type         producer_id_t  = logic,
  parameter type         slot_id_t      = logic,
  parameter type         phy_id_t       = logic,
  parameter type         operand_req_t  = logic,
  parameter type         operand_t      = logic
) (
  input  logic clk_i,
  input  logic rst_i,

  // The producer id of the RS and thus the first RSS. Must be static.
  input  producer_id_t              producer_id_i,
  // If restart is asserted, we initialize the RS. This will clean all RSS and reset the loop
  // handling logic. THERE MAY NOT BE ANY instruction in flight!
  // TODO(colluca): add assertion
  input  logic                      restart_i,
  input  logic                      en_superscalar_i,
  // Whether the RS if full or empty
  output logic                      rs_empty_o,
  output logic                      rs_full_o,

  // The dispatched instruction - from Dispatcher
  input  disp_req_t disp_req_i,
  input  logic      disp_req_valid_i,
  output logic      disp_req_ready_o,
  input  logic      instr_exec_commit_i,
  output disp_rsp_t disp_rsp_o,

  // The issued instruction - to FU
  output issue_req_t issue_req_o,
  output logic       issue_req_valid_o,
  input  logic       issue_req_ready_i,
  output logic       instr_exec_commit_o,

  /// Operand distribution network
  // Operand request interface - outgoing - request a result as operand
  output operand_req_t [NofOperands-1:0] op_reqs_o,
  output logic         [NofOperands-1:0] op_reqs_valid_o,
  input  logic         [NofOperands-1:0] op_reqs_ready_i,

  // Operand response interface - incoming - returning result as operand
  input  operand_t [NofOperands-1:0] op_rsps_i,
  input  logic     [NofOperands-1:0] op_rsps_valid_i,
  output logic     [NofOperands-1:0] op_rsps_ready_o
);

  /////////////////////////////////////
  // Parameters and type definitions //
  /////////////////////////////////////

  // The RSS pointer / index vector width
  localparam integer unsigned NofRssWidth    = cf_math_pkg::idx_width(NofRss);
  // We need to count from 0 to NofRss for the control logic -> +1 bit
  localparam integer unsigned NofRssWidthExt = cf_math_pkg::idx_width(NofRss+1);


  typedef logic [NofRssWidth-1:0] rss_idx_t;
  typedef logic [NofRssWidthExt-1:0] rss_cnt_t;

  typedef struct packed {
    // The physical register from where this operand will be fetched
    phy_id_t phy_reg_src;
    // If the physical register is a floating point register
    logic    is_fp;
    // If this is set, the current operand has a valid value
    // otherwise the operand has to be fetched/requested from the
    // physical register file.
    logic    is_valid;
    operand_t     value;
  } rss_operand_t;

  // Issue-side state — updated by the dispatch pipeline only.
  // TODO(colluca): put all FU-specific fields into a separate struct that is passed
  // as a parameter, and instantiated as a “user” field. Otherwise, only mandatory fields used
  // for control logic should be hardcoded here.
  typedef struct packed {
    // Whether the RSS contains an active instruction.
    logic                           is_occupied;
    // The instruction itself. Partially decoded. Depends on FU type.
    alu_op_e                        alu_op;
    lsu_op_e                        lsu_op;
    fpu_op_e                        fpu_op;
    lsu_size_e                      lsu_size;
    fpnew_pkg::fp_format_e          fpu_fmt_src;
    fpnew_pkg::fp_format_e          fpu_fmt_dst;
    fpnew_pkg::roundmode_e          fpu_rnd_mode;
    // To which physical register this instruction writes to
    instr_tag_t                     tag;

    // Data of the operands from this slot
    rss_operand_t [NofOperands-1:0] operands;
  } rs_slot_issue_t;

  //////////////////////////
  // Cut dispatch request //
  //////////////////////////

  disp_req_t disp_req_i_q;
  logic      disp_req_valid_i_q;
  logic      disp_req_ready_o_q;

  // The cut will result in delayed exceptions. If an exception occurs it will trigger the
  // exception at the next instruction.
  logic disp_req_valid_guarded;
  logic disp_req_ready_o_raw;
  // Do not accept a new dispatch request if we are currently handling one or we are full.
  // Only accept it if we commit to the dispatch.
  assign disp_req_valid_guarded = disp_req_valid_i && !disp_req_valid_i_q && !rs_full_o &&
                                  instr_exec_commit_i;
  // Do not signal ready until we are processing the request. This allows to handle branches where
  // the target address is only valid in the cycle the ALU computes it.
  // This is in the effective dispatch cycle because the ALU is single cycle.
  assign disp_req_ready_o = disp_req_ready_o_raw && !disp_req_valid_i_q && !rs_full_o &&
                            instr_exec_commit_i;

  spill_register_flushable #(
    .T     (disp_req_t),
    .Bypass(0)
  ) i_disp_cut (
    .clk_i,
    .rst_ni (~rst_i),
    .valid_i(disp_req_valid_guarded),
    .flush_i(restart_i),
    .ready_o(disp_req_ready_o_raw),
    .data_i (disp_req_i),
    .valid_o(disp_req_valid_i_q),
    .ready_i(disp_req_ready_o_q),
    .data_o (disp_req_i_q)
  );

  //////////////////////////////
  // RS allocation controller //
  //////////////////////////////

  // Generates the instruction dispatch, issue, retire & writeback control signals and handles
  // the LEP iterations.

  // TODO(colluca): why do we need counters at all for the LCPx phases? The schnizo_controller
  //                already has these, and if it needs other information this is all we should
  //                provide it with.

  logic dispatch_hs;
  assign dispatch_hs = disp_req_valid_i_q && disp_req_ready_o_q;

  // An instruction retires as soon as the result is handshaked, i.e.:
  // assign retiring = result_valid_i && result_ready_o;
  // However, a store has no result. Thus we generate this signal inside the RSS as the RSS knows
  // if the instruction is a store or any other instruction.
  logic retiring;

  // Dispatch index, points to the RSS we currently can  dispatch an instruction to
  rss_cnt_t disp_cnt;

  // Number of allocated RSS
  rss_cnt_t num_allocated_rss_d, num_allocated_rss_q;
  `FFAR(num_allocated_rss_q, num_allocated_rss_d, '0, clk_i, rst_i);

  always_comb begin : num_aloc_rss_handler
    num_allocated_rss_d = num_allocated_rss_q;
    if(dispatch_hs && !retiring) begin
      // If we are dispatching but not retiering in this cycle, we have one more
      // instruction allocated in the RSS
      num_allocated_rss_d = num_allocated_rss_q + 1'b1;
    end else if (!dispatch_hs && retiring) begin
      // If we are retireing but not dispatching, we have one less instruction
      // allocated in the RSS
      num_allocated_rss_d = num_allocated_rss_q - 1'b1;
    end
  end

  assign rs_full_o = (num_allocated_rss_q == rss_cnt_t'(NofRss));
  assign rs_empty_o = (num_allocated_rss_q != '0);

  //////////////////////////////
  // Slots datapath           //
  //////////////////////////////

  schnova_res_stat_slots #(
    .NofRss          (NofRss),
    .NofOperands     (NofOperands),
    .NofResRspIfs    (NofResRspIfs),
    .RegAddrWidth    (RegAddrWidth),
    .UseSram         (UseSram),
    .rs_slot_issue_t (rs_slot_issue_t),
    .rss_operand_t   (rss_operand_t),
    .disp_req_t      (disp_req_t),
    .issue_req_t     (issue_req_t),
    .result_t        (result_t),
    .producer_id_t   (producer_id_t),
    .slot_id_t       (slot_id_t),
    .operand_req_t   (operand_req_t),
    .operand_t       (operand_t)
  ) i_slots (
    .clk_i,
    .rst_i,
    .producer_id_i     (producer_id_i),
    .restart_i         (restart_i),
    .disp_idx_i        ('0),
    .retiring_o        (retiring),
    .disp_req_i        (disp_req_i_q),
    .disp_req_valid_i  (disp_req_valid_i_q),
    .disp_req_ready_o  (disp_req_ready_o_q),
    .disp_rsp_o        (disp_rsp_o),
    .issue_req_o,
    .issue_req_valid_o,
    .issue_req_ready_i,
    .instr_exec_commit_o,
    .op_reqs_o,
    .op_reqs_valid_o,
    .op_reqs_ready_i,
    .op_rsps_i,
    .op_rsps_valid_i,
    .op_rsps_ready_o
  );

  //////////////
  // Counters //
  //////////////

  delta_counter #(
    .WIDTH(NofRssWidthExt)
  ) i_disp_counter (
    .clk_i,
    .rst_ni  (!rst_i),
    .clear_i (restart_i),
    .en_i    (dispatch_hs),
    .load_i  (1'b0),
    .down_i  (1'b0),
    .delta_i (rss_cnt_t'(1)),
    .d_i     ('0),
    .q_o     (disp_cnt),
    .overflow_o ()
  );

endmodule
