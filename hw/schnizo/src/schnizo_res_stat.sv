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
module schnizo_res_stat import schnizo_pkg::*; #(
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
  input  loop_state_e               loop_state_i,
  input  logic [MaxIterationsW-1:0] lep_iterations_i,
  // Asserted in the last LCP1 cycle (the cycle before we start LCP2)
  input  logic                      goto_lcp2_i,
  // Asserted when all RSS have finish execution (in this cycle).
  // LCP: No instructions in flight. LEP: All iterations done
  output logic                      loop_finish_o,
  output logic                      rs_full_o,
  // FU busy state. Asserted if valid data is in flight.
  input  logic                      fu_busy_i,

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

  localparam integer unsigned ConsumerCountWidth = cf_math_pkg::idx_width(ConsumerCount);

  typedef struct packed {
    // The ID of the producer. Only valid if the isProduced flag is set. Otherwise this operand is
    // constant and fetched during LCP1 and LCP2.
    producer_id_t producer;
    // Signaling whether this operand is produced or not. If set, the value has to be fetched from
    // the producer defined by producer_id. If reset, this operand is constant and is fetched in
    // LCP1 and again in LCP2 and kept for the rest of the loop execution. A constant value can
    // either be a value read once from a register or an immediate of the instruction.
    logic         is_produced;
    // Specifying in which iteration the producer generated the value. If set, the producer is in
    // the same iteration. If reset, this is a loop-carried dependency.
    logic         is_from_current_iter;
    operand_t     value;
    logic         is_valid;
    // Set if we placed a request to the producer
    logic         requested;
  } rss_operand_t;

  typedef struct packed {
    result_t value;
    // If set, the result is valid.
    logic    is_valid;
    // This flag signals to which iteration (“current” or “next”) the currently stored value in
    // the Result buffer belongs to. It is toggled each time a new value is written into the
    // buffer.
    logic    iteration;
  } rss_result_t;

  // Result metadata and counters — updated by res_req_handling and result_capture.
  typedef struct packed {
    // How many consumers use the result of this instruction.
    logic [ConsumerCountWidth-1:0]  consumer_count;
    // A counter to keep track how many times the current result has been captured.
    logic [ConsumerCountWidth-1:0]  consumed_by;
    // The most recent result.
    rss_result_t                    result;
    // TODO(colluca): it should be possible to get rid of this
    // Some instructions (e.g. stores) don't have a destination register, i.e. never generate a result.
    // Thus, we immediately retire the instruction when it's issued.
    logic                           no_dest;
    // The register ID where this instruction does commit into during regular execution.
    logic [RegAddrWidth-1:0]        dest_id;
    // Whether the destination register is a floating point or integer register.
    logic                           dest_is_fp;
    // Specifying whether the last result of the loop is written into the register defined by
    // destination id. This flag is defined during LCP and ensures that at the end of the loop
    // only the last writing instruction does perform a writeback to the RF.
    logic                           do_writeback;
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
    // This flag signals to which iteration (“current” or “next”) the currently
    // “waiting instruction” (not all operands are ready) in the RSS belongs to. It is toggled
    // each time the instruction is issued.
    logic                           instruction_iter;
    // Some instructions (e.g. stores) don't have a destination register, i.e. never generate a result.
    // Thus, we immediately retire the instruction when it's issued.
    logic                           no_dest;
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

  localparam integer unsigned ConsumerCountWidth = cf_math_pkg::idx_width(ConsumerCount);

  typedef struct packed {
    // The ID of the producer. Only valid if the isProduced flag is set. Otherwise this operand is
    // constant and fetched during LCP1 and LCP2.
    producer_id_t producer;
    // Signaling whether this operand is produced or not. If set, the value has to be fetched from
    // the producer defined by producer_id. If reset, this operand is constant and is fetched in
    // LCP1 and again in LCP2 and kept for the rest of the loop execution. A constant value can
    // either be a value read once from a register or an immediate of the instruction.
    logic         is_produced;
    // Specifying in which iteration the producer generated the value. If set, the producer is in
    // the same iteration. If reset, this is a loop-carried dependency.
    logic         is_from_current_iter;
    operand_t     value;
    logic         is_valid;
    // Set if we placed a request to the producer
    logic         requested;
  } rss_operand_t;

  typedef struct packed {
    result_t value;
    // If set, the result is valid.
    logic    is_valid;
    // This flag signals to which iteration (“current” or “next”) the currently stored value in
    // the Result buffer belongs to. It is toggled each time a new value is written into the
    // buffer.
    logic    iteration;
  } rss_result_t;

  // TODO(colluca): put all FU-specific fields into a separate struct that is passed
  // as a parameter, and instantiated as a "user" field. Otherwise, only mandatory fields used
  // for control logic should be hardcoded here. `is_store` is one of these, so it should be
  // renamed to reflect its FU-independent function.
  typedef struct packed {
    // Whether the RSS contains an active instruction.
    logic                           is_occupied;
    // How many consumer use the result of this instruction.
    logic [ConsumerCountWidth-1:0]  consumer_count;
    // A counter to keep track how many times the current result has been captured.
    logic [ConsumerCountWidth-1:0]  consumed_by;
    // The instruction itself. Partially decoded. Depends on FU type.
    // TODO: Can we rely on the synthesis optimization to remove unused signals even if they are
    //       registered here?
    alu_op_e                        alu_op;
    lsu_op_e                        lsu_op;
    fpu_op_e                        fpu_op;
    lsu_size_e                      lsu_size;
    // A store instruction never generates a result. Thus we immediately accept a result when
    // issuing the instruction.
    logic                           is_store;
    fpnew_pkg::fp_format_e          fpu_fmt_src;
    fpnew_pkg::fp_format_e          fpu_fmt_dst;
    fpnew_pkg::roundmode_e          fpu_rnd_mode;
    // The most recent result
    rss_result_t                    result;
    // This flag signals to which iteration (“current” or “next”) the currently
    // “waiting instruction” (not all operands are ready) in the RSS belongs to. It is toggled
    // each time the instruction is issued.
    logic                           instruction_iter;
    // The register ID where this instruction does commit into during regular execution.
    logic [RegAddrWidth-1:0]        dest_id;
    // Whether the destination register is a floating point or integer register.
    logic                           dest_is_fp;
    // Specifying whether the last result of the loop is written into the register defined by
    // destination id. This flag is defined during LCP and ensures that at the end of the loop
    // only the last writing instruction does perform a writeback to the RF.
    logic                           do_writeback;
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
  } rs_slot_t;

  /////////////////
  // Connections //
  /////////////////

  // Reservation Station Slots
  disp_req_t              disp_req;
  logic                   disp_req_valid;
  logic                   disp_req_ready;
  logic                   disp_req_internal_valid;
  logic                   disp_req_internal_ready; // unused, internal disp logic is always valid

  // The pointers / indexes to select the appropriate RSS.
  rss_idx_t disp_idx;
  rss_idx_t result_idx;

  // loop control
  logic last_disp_instr;
  logic last_disp_iter;
  logic last_result_instr;
  logic last_result_iter;

  // Slot states
  rs_slot_t [NofRss-1:0] slot_qs;         // registered state from each slot
  rs_slot_t [NofRss-1:0] slot_ds;         // next state for each slot
  rs_slot_t              slot_issue;      // post-dispatch-pipeline state for the selected slot
  logic                  issue_hs;        // issue handshake from the shared dispatch pipeline
  rs_slot_t [NofRss-1:0] slot_res_rsps;   // post-res_req_handling state from each slot
  rs_slot_t              slot_wb_capture; // post-result-capture state for the selected slot
  logic                  capture_retired;         // retired signal for the selected slot
  logic                  capture_retired_rs;      // retired_rs signal for RS result pointer
  result_tag_t           capture_rf_wb_tag;       // RF writeback tag from result capture
  logic                  capture_rf_do_writeback; // RF writeback enable from result capture

  rss_idx_t result_rss_sel;
  assign result_rss_sel = rss_idx_t'(result_tag_i);

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

  ///////////
  // Slots //
  ///////////

  slot_id_t     [NofRss-1:0] slot_ids;
  producer_id_t [NofRss-1:0] rss_ids;

  // In case the dispatch index overflows (we are full), tie down any signals to a default value.
  logic sel_rss_valid;
  assign sel_rss_valid = (disp_idx >= NofRss) ? 1'b0 : 1'b1;

  // In case the result index overflows, suppress the retiring signal.
  logic sel_result_valid;
  assign sel_result_valid = (result_idx < NofRss) ? 1'b1 : 1'b0;

  rs_slot_t slot_reset_value;
  assign slot_reset_value = '{
    is_occupied:          1'b0, // suppresses operand requests
    consumer_count:       '0,
    consumed_by:          '0,
    alu_op:               AluOpAdd,
    lsu_op:               LsuOpLoad, // avoid store because the store flag has to be 0
    fpu_op:               FpuOpFadd,
    is_store:             1'b0,
    lsu_size:             Byte,
    fpu_fmt_src:          fpnew_pkg::FP32,
    fpu_fmt_dst:          fpnew_pkg::FP32,
    fpu_rnd_mode:         fpnew_pkg::RNE,
    // We ignore the result part - the iteration flag could be X.
    result:               '0,
    instruction_iter:     1'b0,
    dest_id:              '0,
    dest_is_fp:           '0,
    do_writeback:         1'b0,
    operands:             '0 // invalid operands lead to no issue requests
  };

  for (genvar rss = 0; rss < NofRss; rss++) begin : gen_rss
    assign slot_ids[rss] = slot_id_t'(rss);
    assign rss_ids[rss] = producer_id_t'{
      slot_id: slot_ids[rss],
      rs_id:   producer_id_i.rs_id
    };

    assign slot_ds[rss] = sel_result_valid && (rss_idx_t'(rss) == result_rss_sel) ? slot_wb_capture : slot_res_rsps[rss];
    `FFAR(slot_qs[rss], slot_ds[rss], slot_reset_value, clk_i, rst_i);

    schnizo_rss_res_req_handling #(
      .rs_slot_t    (rs_slot_t),
      .operand_req_t(operand_req_t),
      .producer_id_t(producer_id_t),
      .dest_mask_t  (dest_mask_t),
      .res_rsp_t    (res_rsp_t)
    ) i_res_req_handling (
      .clk_i,
      .rst_i,
      .slot_q_i          (slot_qs[rss]),
      .slot_i            (sel_rss_valid && (rss_idx_t'(rss) == disp_idx) ? slot_issue : slot_qs[rss]),
      .retired_i         (sel_result_valid && (rss_idx_t'(rss) == result_rss_sel) ? capture_retired : 1'b0),
      .loop_state_i      (loop_state_i),
      .restart_i         (restart_i),
      .dest_mask_i       (res_reqs_i[rss]),
      .dest_mask_valid_i (res_reqs_valid_i[rss]),
      .dest_mask_ready_o (res_reqs_ready_o[rss]),
      .producer_id_i     (rss_ids[rss]),
      .available_result_o(available_results_o[rss]),
      .res_rsp_o         (res_rsps_o[rss]),
      .res_rsp_valid_o   (res_rsps_valid_o[rss]),
      .res_rsp_ready_i   (res_rsps_ready_i[rss]),
      .slot_o            (slot_res_rsps[rss])
    );

  end

  ////////////////////
  // LxP Controller //
  ////////////////////

  // Generates the instruction dispatch, issue, retire & writeback control signals and handles
  // the LEP iterations.

  // TODO(colluca): why do we need counters at all for the LCPx phases? The schnizo_controller
  //                already has these, and if it needs other information this is all we should
  //                provide it with.

  logic disp_hs;
  assign disp_hs = disp_req_valid && disp_req_ready;

  logic issue_hs;
  assign issue_hs = issue_req_valid_o && issue_req_ready_i;

  logic retiring;
  // An instruction retires as soon as the result is handshaked, i.e.:
  // assign retiring    = result_valid_i && result_ready_o;
  // However, a store has no result. Thus we generate this signal inside the RSS as the RSS knows
  // if the instruction is a store or any other instruction.
  // The result pointer can point to +1 of NofRSS. We thus have to limit it inside the range.
  assign retiring = sel_result_valid ? capture_retired_rs : 1'b0;

  logic retire_at_issue;

  // Dispatch and result trip counter outputs
  rss_idx_t disp_cnt, issue_cnt, result_cnt;
  logic     last_disp;
  logic     trip_issue;
  logic     last_result, trip_result;

  logic [MaxIterationsW-1:0] lep_issue_iter_count;
  logic [MaxIterationsW-1:0] lep_result_iter_count;

  // The number of RSSs allocated during LCP1 is captured for use in LCP2 and LEP.
  // We snapshot the dispatch counter on the LCP1->LCP2 transition.
  rss_idx_t num_allocated_rss_d, num_allocated_rss_q;
  assign num_allocated_rss_d = goto_lcp2_i ? disp_cnt + disp_hs : num_allocated_rss_q;
  `FFAR(num_allocated_rss_q, num_allocated_rss_d, '0, clk_i, rst_i);

  logic last_result_iter;
  assign last_result_iter = lep_result_iter_count == 1;

  // TODO(colluca): do we need the state-dependent condition?
  assign rs_full_o = (loop_state_i == LoopLcp1) && last_disp;

  logic any_instr_captured;
  assign any_instr_captured = (num_allocated_rss_q != '0);

  // ---------------------------
  // Finish detection
  // ---------------------------

  logic lcp_finished;
  logic lep_finished_issue, lep_finished;

  // In LCP the loop controller knows when we are in the last loop iteration.
  // All it needs to know from the RS is if the FU has retired all instructions.
  // `fu_busy_i` is asserted also when the output of the FU is valid, but in this cycle
  // the instruction may already be retiring, so to not waste a cycle we separately
  // include this condition (result_hs).
  assign lcp_finished = !disp_req_valid_i && (!fu_busy_i && !disp_req_valid_i_q ||
                        ((disp_cnt == result_cnt) && result_hs));

  // In LEP the RS has finished if:
  // - All instructions for all iterations have been dispatched
  // AND
  // - The FUs are not busy, i.e. all results have been captured
  assign lep_finished_issue = lep_issue_iter_count == '0;
  assign lep_finished = ((loop_state_i == LoopLep) && lep_finished_issue && !fu_busy_i)
                        || !any_instr_captured;

  always_comb begin : loop_finish
    loop_finish_o = 1'b0;
    unique case (loop_state_i)
      LoopRegular,
      LoopHwLoop: loop_finish_o = 1'b0;
      LoopLcp1,
      LoopLcp2: loop_finish_o = lcp_finished;
      LoopLep: loop_finish_o = lep_finished;
      default: loop_finish_o = 1'b0;
    endcase
  end

  ////////////////////
  // LEP Dispatcher //
  ////////////////////
  // TODO(colluca): according to the previous terminology shouldn't this be called issue?

  // In LEP we can dispatch the RSSs if we have a instruction captured until we reached the amount
  // of iterations. The actual dispatch request data is irrelevant as the instruction is captured
  // in the RSS.

  logic lep_do_dispatch;
  assign lep_do_dispatch         = !lep_finished_issue && (loop_state_i inside {LoopLep}) &&
                                   any_instr_captured;
  assign disp_req_internal_valid = lep_do_dispatch;

  //////////////////
  // Dispatch MUX //
  //////////////////

  // The dispatch request selection. Either select request from outside or from LEP engine.
  // TODO(colluca): this to me sounds like a repetition of the bypass path we have in the
  //                FU block, which is used for regular execution. Do we really need both?
  //                Can we at that point not just pass regular execution requests into the
  //                res_stat and bypass everything internally?
  //                Well, maybe not, because of the cut.

  logic sel_disp_req_internal;
  assign sel_disp_req_internal = loop_state_i == LoopLep;

  // Select between external (LCP) and internal dispatch request (LEP). The internal dispatch
  // request has no actual data as the instruction is already captured in the RSS. Thus we can
  // simplify the MUX to only mux the valid/ready handshake.
  // TODO(colluca): do we need a mux at all here? I would think we would only need to OR the valids
  //                and broadcast the ready.
  stream_mux #(
    .DATA_T(logic),
    .N_INP (2)
  ) i_disp_req_mux (
    .inp_data_i ('0), // dummy data
    .inp_valid_i({disp_req_internal_valid, disp_req_valid_i_q}),
    .inp_ready_o({disp_req_internal_ready, disp_req_ready_o_q}),
    .inp_sel_i  (sel_disp_req_internal),
    .oup_data_o (), // don't use the MUX output data
    .oup_valid_o(disp_req_valid),
    .oup_ready_i(disp_req_ready)
  );

  ///////////////////////
  // Dispatch pipeline //
  ///////////////////////

  logic disp_req_ready_pipeline;
  assign disp_req_ready = sel_rss_valid ? disp_req_ready_pipeline : 1'b0;

  logic       issue_req_valid_raw;
  issue_req_t issue_req_raw;

  schnizo_rss_dispatch_pipeline #(
    .NofOperands  (NofOperands),
    .disp_req_t   (disp_req_t),
    .producer_id_t(producer_id_t),
    .rs_slot_t    (rs_slot_t),
    .rss_operand_t(rss_operand_t),
    .rss_result_t (rss_result_t),
    .operand_req_t(operand_req_t),
    .res_req_t    (res_req_t),
    .operand_t    (operand_t),
    .issue_req_t  (issue_req_t)
  ) i_dispatch_pipeline (
    .restart_i         (restart_i),
    .producer_id_i     (sel_rss_valid ? rss_ids[disp_idx] : '0),
    .loop_state_i      (loop_state_i),
    .disp_req_i        (disp_req),
    .disp_req_valid_i  (disp_req_valid && sel_rss_valid),
    .disp_req_ready_o  (disp_req_ready_pipeline),
    .slot_i            (sel_rss_valid ? slot_qs[disp_idx] : '0),
    .slot_reset_state_i(slot_reset_value),
    .op_reqs_o         (op_reqs_o),
    .op_reqs_valid_o   (op_reqs_valid_o),
    .op_reqs_ready_i   (op_reqs_ready_i),
    .op_rsps_i         (op_rsps_i),
    .op_rsps_valid_i   (op_rsps_valid_i),
    .op_rsps_ready_o   (op_rsps_ready_o),
    .issue_req_o       (issue_req_raw),
    .issue_req_valid_o (issue_req_valid_raw),
    .issue_req_ready_i (issue_req_ready_i),
    .issue_hs_o        (issue_hs),
    .slot_o            (slot_issue)
  );

  // TODO(colluca): use rss_ids
  assign disp_rsp_o = producer_id_t'{
    // Here we can go out of bounds because this response is only valid if we use a existing slot.slot_id
    slot_id: (disp_idx >= NofRss) ? 1'b0 : slot_ids[disp_idx],
    rs_id:   producer_id_i.rs_id
  };

  // issue_req_raw and issue_req_valid_raw come directly from i_dispatch_pipeline above.
  // Tie down if dispatch index is out of range.
  assign issue_req_valid_o   = sel_rss_valid ? issue_req_valid_raw : 1'b0;
  assign issue_req_o         = sel_rss_valid ? issue_req_raw       : '0;

  // Each accepted dispatch request was committed so we also commit to each issue request
  assign instr_exec_commit_o = issue_req_valid_o;

  /////////////////////////
  // Result RF/RSS demux //
  /////////////////////////

  logic rss_wb_valid, rss_wb_ready;
  logic rf_wb_valid, rf_wb_ready;

  stream_fork #(
    .N_OUP(32'd2)
  ) i_result_fork (
    .clk_i,
    .rst_ni (!rst_i),
    .valid_i(result_valid_i),
    .ready_o(result_ready_o),
    .valid_o({rf_wb_valid, rss_wb_valid}),
    .ready_i({rf_wb_ready, rss_wb_ready})
  );

  ///////////////////////////////////////
  // Synchronize RF and RSS writebacks //
  ///////////////////////////////////////

  logic rf_do_writeback;

  logic rss_wb_valid_sync, rss_wb_ready_sync;
  logic rf_wb_valid_sync, rf_wb_ready_sync;
  logic rss_wb_enable;

  assign rf_do_writeback = capture_rf_do_writeback;

  // Synchronize the two streams, otherwise it may occur that a result
  // capture event preceeds an issue event, with single-cycle FUs.
  // While this does not seem to compromise correctness, it does complicate the
  // tracer design, and it does go against the expectation that issue
  // precedes result capture.
  assign rf_wb_valid_sync = rf_wb_valid && rss_wb_ready_sync;
  assign rf_wb_ready = rf_wb_ready_sync && rss_wb_ready_sync;
  assign rss_wb_enable = rf_do_writeback ? rf_wb_valid_sync && rf_wb_ready_sync : 1'b1;
  assign rss_wb_valid_sync = rss_wb_valid && rss_wb_enable;
  assign rss_wb_ready = rss_wb_ready_sync && rss_wb_enable;

  //////////////////
  // RF writeback //
  //////////////////

  stream_filter i_filter_rf_writeback (
    .valid_i(rf_wb_valid_sync),
    .ready_o(rf_wb_ready_sync),
    .drop_i (!rf_do_writeback),
    .valid_o(rf_wb_valid_o),
    .ready_i(rf_wb_ready_i)
  );
  assign rf_wb_result_o = result_i;
  assign rf_wb_tag_o    = capture_rf_wb_tag;

  /////////////////////
  // Result capture  //
  /////////////////////

  schnizo_rss_result_capture #(
    .rs_slot_t   (rs_slot_t),
    .result_t    (result_t),
    .result_tag_t(result_tag_t),
    .disp_req_t  (disp_req_t)
  ) i_result_capture (
    .slot_i              (slot_res_rsps[result_rss_sel]),
    .issue_hs_i          (issue_hs && (disp_idx == result_rss_sel)),
    .result_i            (result_i),
    .result_valid_i      (rss_wb_valid_sync),
    .loop_state_i        (loop_state_i),
    .is_last_result_iter_i(last_result_iter),
    .disp_req_i          (disp_req),
    .result_ready_o      (rss_wb_ready_sync),
    .retired_o           (capture_retired),
    .retired_rs_o        (capture_retired_rs),
    .rf_wb_tag_o         (capture_rf_wb_tag),
    .rf_do_writeback_o   (capture_rf_do_writeback),
    .slot_o              (slot_wb_capture)
  );

  //////////////
  // Counters //
  //////////////

  trip_counter #(
    .WIDTH(NofRssWidth)
  ) i_disp_counter (
    .clk_i,
    .rst_ni  (!rst_i),
    .clear_i (goto_lcp2_i || restart_i),
    .en_i    (disp_hs),
    .delta_i (rss_idx_t'(1)),
    .bound_i (rss_idx_t'((loop_state_i == LoopLcp1) ? (NofRss - 1) : (num_allocated_rss_q - 1))),
    .q_o     (disp_cnt),
    .last_o  (last_disp),
    .trip_o  ()
  );

  trip_counter #(
    .WIDTH(NofRssWidth)
  ) i_issue_counter (
    .clk_i,
    .rst_ni  (!rst_i),
    .clear_i (goto_lcp2_i || restart_i),
    .en_i    (issue_hs),
    .delta_i (rss_idx_t'(1)),
    .bound_i (rss_idx_t'((loop_state_i == LoopLcp1) ? (NofRss - 1) : (num_allocated_rss_q - 1))),
    .q_o     (issue_cnt),
    .last_o  (),
    .trip_o  (trip_issue)
  );

  // An instruction retires as soon as the result is handshaked.
  // Instructions which don't produce a result retire as soon as they are issued.
  // TODO(colluca): it would probably be better to make this uniform at the FU level,
  // i.e. to enforce that every FU always produces a response, even if it doesn't carry a result.
  // This would eliminate the need to increment by 2 in some cycles.
  trip_counter #(
    .WIDTH(NofRssWidth)
  ) i_result_counter (
    .clk_i,
    .rst_ni  (!rst_i),
    .clear_i (goto_lcp2_i || restart_i),
    .en_i    (retire_at_issue || result_hs),
    .delta_i (rss_idx_t'(retire_at_issue + result_hs)),
    .bound_i (rss_idx_t'((loop_state_i == LoopLcp1) ? (NofRss - 1) : (num_allocated_rss_q - 1))),
    .q_o     (result_cnt),
    .last_o  (last_result),
    .trip_o  (trip_result)
  );

  counter #(
    .WIDTH          (MaxIterationsW),
    .STICKY_OVERFLOW(0)
  ) i_lep_issue_iter_counter (
    .clk_i,
    .rst_ni    (!rst_i),
    .clear_i   (restart_i),
    .en_i      ((loop_state_i == LoopLep) && trip_issue),
    .load_i    (loop_state_i == LoopLcp2),
    .down_i    (1'b1),
    .d_i       (lep_iterations_i),
    .q_o       (lep_issue_iter_count),
    .overflow_o()
  );

  counter #(
    .WIDTH          (MaxIterationsW),
    .STICKY_OVERFLOW(0)
  ) i_lep_result_iter_counter (
    .clk_i,
    .rst_ni    (!rst_i),
    .clear_i   (restart_i),
    .en_i      ((loop_state_i == LoopLep) && trip_result && (lep_result_iter_count > '0)),
    .load_i    (loop_state_i == LoopLcp2),
    .down_i    (1'b1),
    .d_i       (lep_iterations_i),
    .q_o       (lep_result_iter_count),
    .overflow_o()
  );

  ////////////////
  // Assertions //
  ////////////////

  // The inflight counters track the actual number of dispatched and issued instructions
  // in flight. If we have a issue handshake without a previous dispatch handshake, or a
  // result handshake without a previous issue handshake, the counters underflow and we
  // raise an error. Additionally, there can only be at most one instruction dispatched
  // but not yet issued.
  // TODO(colluca): these assertions would trigger in time 0. Find a solution and fix these.
  // rss_idx_t inflight_disp_d, inflight_disp_q;
  // rss_idx_t inflight_issue_d, inflight_issue_q;
  // assign inflight_disp_d  = restart_i ? '0 :
  //                           inflight_disp_q  + rss_idx_t'(disp_hs)  - rss_idx_t'(issue_hs);
  // assign inflight_issue_d = restart_i ? '0 :
  //                           inflight_issue_q + rss_idx_t'(issue_hs) - rss_idx_t'(retire_at_issue + result_hs);
  // `FFAR(inflight_disp_q,  inflight_disp_d,  '0, clk_i, rst_i)
  // `FFAR(inflight_issue_q, inflight_issue_d, '0, clk_i, rst_i)
  // `ASSERT(DispatchBeforeIssue, inflight_disp_q <= rss_idx_t'(1), clk_i, !rst_i)
  // `ASSERT(IssueBeforeResult, inflight_issue_q < rss_idx_t'(NofRss), clk_i, !rst_i)

endmodule