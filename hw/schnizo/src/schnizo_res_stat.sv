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

  // Post-mux dispatch handshake (valid produced by mux, ready returned by slots)
  logic disp_req_valid;
  logic disp_req_ready;
  logic disp_req_internal_valid;
  logic disp_req_internal_ready; // unused, internal disp logic is always valid

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

  ////////////////////
  // LxP Controller //
  ////////////////////

  // Generates the instruction dispatch, issue, retire & writeback control signals and handles
  // the LEP iterations.

  // TODO(colluca): why do we need counters at all for the LCPx phases? The schnizo_controller
  //                already has these, and if it needs other information this is all we should
  //                provide it with.

  logic dispatch_hs;
  assign dispatch_hs = disp_req_valid && disp_req_ready;

  // An instruction retires as soon as the result is handshaked, i.e.:
  // assign retiring = result_valid_i && result_ready_o;
  // However, a store has no result. Thus we generate this signal inside the RSS as the RSS knows
  // if the instruction is a store or any other instruction.
  logic retiring;

  // Dispatch and result trip counter outputs
  rss_cnt_t disp_cnt, result_cnt;
  logic     last_disp, trip_disp;
  logic     last_result, trip_result;

  logic [MaxIterationsW-1:0] lep_disp_iter_count;
  logic [MaxIterationsW-1:0] lep_result_iter_count;

  // The number of RSSs allocated during LCP1 is captured for use in LCP2 and LEP.
  // We snapshot the dispatch counter on the LCP1->LCP2 transition.
  rss_cnt_t num_allocated_rss_d, num_allocated_rss_q;
  assign num_allocated_rss_d = goto_lcp2_i ? disp_cnt + dispatch_hs : num_allocated_rss_q;
  `FFAR(num_allocated_rss_q, num_allocated_rss_d, '0, clk_i, rst_i);

  logic last_result_iter;
  assign last_result_iter = lep_result_iter_count == 1;

  assign rs_full_o = (loop_state_i == LoopLcp1) && last_disp;

  logic any_instr_captured;
  assign any_instr_captured = (num_allocated_rss_q != '0);

  // ---------------------------
  // Finish detection
  // ---------------------------

  logic lcp_finished;
  logic lep_finished_disp, lep_finished;

  // In LCP the loop controller knows when we are in the last loop iteration.
  // All it needs to know from the RS is if the FU has retired all instructions.
  // `fu_busy_i` is asserted also when the output of the FU is valid, but in this cycle
  // the instruction may already be retiring, so to not waste a cycle we separately
  // include this condition.
  assign lcp_finished = !disp_req_valid_i && (!fu_busy_i && !disp_req_valid_i_q ||
                        ((disp_cnt == result_cnt) && retiring));

  // In LEP the RS has finished if:
  // - All instructions for all iterations have been dispatched
  // AND
  // - The FUs are not busy, i.e. all results have been captured
  assign lep_finished_disp = lep_disp_iter_count == '0;
  assign lep_finished = ((loop_state_i == LoopLep) && lep_finished_disp && !fu_busy_i)
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

  //////////////////////////////
  // Slots datapath           //
  //////////////////////////////

  schnizo_res_stat_slots #(
    .NofRss        (NofRss),
    .NofOperands   (NofOperands),
    .NofResRspIfs  (NofResRspIfs),
    .ConsumerCount (ConsumerCount),
    .RegAddrWidth  (RegAddrWidth),
    .rs_slot_t     (rs_slot_t),
    .rss_operand_t (rss_operand_t),
    .rss_result_t  (rss_result_t),
    .disp_req_t    (disp_req_t),
    .issue_req_t   (issue_req_t),
    .result_t      (result_t),
    .result_tag_t  (result_tag_t),
    .producer_id_t (producer_id_t),
    .slot_id_t     (slot_id_t),
    .operand_req_t (operand_req_t),
    .operand_t     (operand_t),
    .res_req_t     (res_req_t),
    .dest_mask_t   (dest_mask_t),
    .res_rsp_t     (res_rsp_t)
  ) i_slots (
    .clk_i,
    .rst_i,
    .producer_id_i     (producer_id_i),
    .restart_i         (restart_i),
    .loop_state_i      (loop_state_i),
    .disp_idx_i        (disp_cnt[NofRssWidth-1:0]),
    .last_result_iter_i(last_result_iter),
    .retiring_o        (retiring),
    .disp_req_i        (disp_req_i_q),
    .disp_req_valid_i  (disp_req_valid),
    .disp_req_ready_o  (disp_req_ready),
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

  trip_counter #(
    .WIDTH(NofRssWidthExt)
  ) i_disp_counter (
    .clk_i,
    .rst_ni  (!rst_i),
    .clear_i (goto_lcp2_i || restart_i),
    .en_i    (dispatch_hs),
    .delta_i (rss_cnt_t'(1)),
    .bound_i (rss_cnt_t'((loop_state_i == LoopLcp1) ? NofRss : (num_allocated_rss_q - 1))),
    .q_o     (disp_cnt),
    .last_o  (last_disp),
    .trip_o  (trip_disp)
  );

  trip_counter #(
    .WIDTH(NofRssWidthExt)
  ) i_result_counter (
    .clk_i,
    .rst_ni  (!rst_i),
    .clear_i (goto_lcp2_i || restart_i),
    .en_i    (retiring),
    .delta_i (rss_cnt_t'(1)),
    .bound_i (rss_cnt_t'((loop_state_i == LoopLcp1) ? NofRss : (num_allocated_rss_q - 1))),
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
    .en_i      ((loop_state_i == LoopLep) && trip_disp),
    .load_i    (loop_state_i == LoopLcp2),
    .down_i    (1'b1),
    .d_i       (lep_iterations_i),
    .q_o       (lep_disp_iter_count),
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