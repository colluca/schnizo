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
  parameter int unsigned ConsumerCount  = 4,
  // The bits to address all registers
  parameter int unsigned RegAddrWidth   = 5,
  parameter int unsigned MaxIterationsW = 5,
  parameter bit          UseSram        = 1'b0,
  parameter type         disp_req_t     = logic,
  parameter type         disp_rsp_t     = logic,
  parameter type         issue_req_t    = logic,
  parameter type         result_t       = logic,
  parameter type         result_tag_t   = logic,
  parameter type         producer_id_t  = logic,
  parameter type         slot_id_t      = logic,
  parameter type         operand_req_t  = logic,
  parameter type         operand_t      = logic,
  parameter type         res_req_t      = logic,
  parameter type         dest_mask_t    = logic,
  parameter type         res_rsp_t      = logic
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

  // Result from FU
  input  result_t     result_i,
  input  result_tag_t result_tag_i,
  input  logic        result_valid_i,
  output logic        result_ready_o,

  // RF writeback
  output result_t     rf_wb_result_o,
  output result_tag_t rf_wb_tag_o,
  output logic        rf_wb_valid_o,
  input  logic        rf_wb_ready_i,

  /// Operand distribution network
  // Info required for arbitration in request XBAR
  // TODO(colluca): constrain NofRss and NofResRspIfs to be equal
  output operand_req_t [NofRss-1:0] available_results_o,

  // Operand request interface - outgoing - request a result as operand
  output operand_req_t [NofOperands-1:0] op_reqs_o,
  output logic         [NofOperands-1:0] op_reqs_valid_o,
  input  logic         [NofOperands-1:0] op_reqs_ready_i,

  // Result request interface - incoming - from each possible requester
  input  dest_mask_t [NofResRspIfs-1:0] res_reqs_i,
  input  logic       [NofResRspIfs-1:0] res_reqs_valid_i,
  output logic       [NofResRspIfs-1:0] res_reqs_ready_o,

  // Result response interface - outgoing - result as operand response
  // Shared port for all slots.
  output res_rsp_t [NofResRspIfs-1:0] res_rsps_o,
  output logic     [NofResRspIfs-1:0] res_rsps_valid_o,
  input  logic     [NofResRspIfs-1:0] res_rsps_ready_i,

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
    // The ID of the producer. Only valid if the isProduced flag is set. Otherwise this operand is
    // constant and fetched during LCP1 and LCP2.
    producer_id_t producer;
    // Signaling whether this operand is produced or not. If set, the value has to be fetched from
    // the producer defined by producer_id. If reset, this operand is constant and is fetched in
    // LCP1 and again in LCP2 and kept for the rest of the loop execution. A constant value can
    // either be a value read once from a register or an immediate of the instruction.
    logic         is_produced;
    operand_t     value;
    logic         is_valid;
    // Set if we placed a request to the producer
    logic         requested;
  } rss_operand_t;

  typedef struct packed {
    result_t value;
    // If set, the result is valid.
    logic    is_valid;
  } rss_result_t;

  // Result metadata and counters — updated by res_req_handling and result_capture.
  typedef struct packed {
    // The most recent result.
    rss_result_t                    result;
    // Some instructions (e.g. stores) don't have a destination register, i.e. never generate a result.
    // Thus, we immediately retire the instruction when it's issued.
    logic                           has_dest;
    // The register ID where this instruction does commit into during regular execution.
    logic [RegAddrWidth-1:0]        dest_id;
    // Whether the destination register is a floating point or integer register.
    logic                           dest_is_fp;
  } rs_slot_result_t;

  // Issue-side state — updated by the dispatch pipeline only.
  // TODO(colluca): put all FU-specific fields into a separate struct that is passed
  // as a parameter, and instantiated as a “user” field. Otherwise, only mandatory fields used
  // for control logic should be hardcoded here.
  typedef struct packed {
    // Whether the RSS contains an active instruction.
    logic                           is_occupied;
    // The instruction itself. Partially decoded. Depends on FU type.
    // TODO: Can we rely on the synthesis optimization to remove unused signals even if they are
    //       registered here?
    alu_op_e                        alu_op;
    lsu_op_e                        lsu_op;
    fpu_op_e                        fpu_op;
    lsu_size_e                      lsu_size;
    fpnew_pkg::fp_format_e          fpu_fmt_src;
    fpnew_pkg::fp_format_e          fpu_fmt_dst;
    fpnew_pkg::roundmode_e          fpu_rnd_mode;
    // All operands
    // TODO(colluca): optimize by pulling out of RS. Only one RSS per RS will anyways fetch
    // operands at any time. One exception is for immediate values, those need to be always
    // stored, but don't need any of the fields in rss_operand_t beyond `value`.
    // The other exception is actually for operands that are not produced by other FUs, e.g.
    // operands that just keep the value from the RF at the time of dispatch.
    // If we don't buffer these, then we have to be able to fetch them from the RF. Probably
    // a good compromise would be to have a few registers (less than #operands x #slots) in the
    // RS to buffer these "non-produced" operands, and fallback to HW loop mode if we run out.
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
    .ConsumerCount   (ConsumerCount),
    .RegAddrWidth    (RegAddrWidth),
    .UseSram         (UseSram),
    .rs_slot_issue_t (rs_slot_issue_t),
    .rs_slot_result_t(rs_slot_result_t),
    .rss_operand_t   (rss_operand_t),
    .rss_result_t    (rss_result_t),
    .disp_req_t      (disp_req_t),
    .issue_req_t     (issue_req_t),
    .result_t        (result_t),
    .result_tag_t    (result_tag_t),
    .producer_id_t   (producer_id_t),
    .slot_id_t       (slot_id_t),
    .operand_req_t   (operand_req_t),
    .operand_t       (operand_t),
    .res_req_t       (res_req_t),
    .dest_mask_t     (dest_mask_t),
    .res_rsp_t       (res_rsp_t)
  ) i_slots (
    .clk_i,
    .rst_i,
    .producer_id_i     (producer_id_i),
    .restart_i         (restart_i),
    .disp_idx_i        (disp_cnt[NofRssWidth-1:0]),
    .retiring_o        (retiring),
    .disp_req_i        (disp_req_i_q),
    .disp_req_valid_i  (disp_req_valid_i_q),
    .disp_req_ready_o  (disp_req_ready_o_q),
    .disp_rsp_o        (disp_rsp_o),
    .issue_req_o,
    .issue_req_valid_o,
    .issue_req_ready_i,
    .instr_exec_commit_o,
    .result_i,
    .result_tag_i,
    .result_valid_i,
    .result_ready_o,
    .rf_wb_result_o,
    .rf_wb_tag_o,
    .rf_wb_valid_o,
    .rf_wb_ready_i,
    .available_results_o,
    .op_reqs_o,
    .op_reqs_valid_o,
    .op_reqs_ready_i,
    .res_reqs_i,
    .res_reqs_valid_i,
    .res_reqs_ready_o,
    .res_rsps_o,
    .res_rsps_valid_o,
    .res_rsps_ready_i,
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
    .q_o     (disp_cnt),
    .overflow_o ()
  );

endmodule
