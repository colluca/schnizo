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

    assign slot_ds[rss] = (rss_idx_t'(rss) == result_rss_sel) ? slot_wb_capture : slot_res_rsps[rss];
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
      .retired_i         ((rss_idx_t'(rss) == result_rss_sel) ? capture_retired : 1'b0),
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
  // TODO(colluca): replace instr and iter counters with trip_counters. As a matter of fact,
  //                replace entirely with the nested FREP sequencer logic.
  // TODO(colluca): why do we need counters at all for the LCPx phases? The schnizo_controller
  //                already has these, and if it needs other information this is all we should
  //                provide it with.

  logic dispatching;

  assign dispatching = disp_req_valid && disp_req_ready;

  logic retiring;
  // An instruction retires as soon as the result is handshaked, i.e.:
  // assign retiring = result_valid_i && result_ready_o;
  // However, a store has no result. Thus we generate this signal inside the RSS as the RSS knows
  // if the instruction is a store or any other instruction.
  assign retiring = capture_retired_rs;

  // Counters for the index control logic
  logic [NofRssWidthExt-1:0] disp_count;
  logic                      disp_inc;
  logic                      disp_reset;

  logic [NofRssWidthExt-1:0] result_count;
  logic                      result_inc;
  logic                      result_reset;

  logic [MaxIterationsW-1:0] lep_disp_iter_count;
  logic                      lep_disp_iter_dec;
  logic                      lep_disp_iter_load;
  logic [MaxIterationsW-1:0] lep_disp_iter_load_value;
  logic                      lep_disp_iter_clear;
  logic [MaxIterationsW-1:0] lep_result_iter_count;
  logic                      lep_result_iter_dec;
  logic                      lep_result_iter_load;
  logic [MaxIterationsW-1:0] lep_result_iter_load_value;
  logic                      lep_result_iter_clear;

  // The number of RSSs allocated during LCP is captured and used during LEP.
  // We snapshot the dispatch counter on the transition into LEP.
  logic [NofRssWidthExt-1:0] num_allocated_rss_d, num_allocated_rss_q;
  assign num_allocated_rss_d = goto_lcp2_i ? disp_count + disp_inc : num_allocated_rss_q;
  `FFAR(num_allocated_rss_q, num_allocated_rss_d, '0, clk_i, rst_i);

  assign last_disp_instr   = disp_count == (num_allocated_rss_q - 1);
  assign last_disp_iter    = lep_disp_iter_count == 1;
  assign last_result_instr = result_count == (num_allocated_rss_q - 1);
  assign last_result_iter  = lep_result_iter_count == 1;

  assign rs_full_o = (disp_count == NofRss[NofRssWidthExt-1:0]);

  logic any_instr_captured;
  assign any_instr_captured = (num_allocated_rss_q != '0);

  always_comb begin : counter_control
    disp_inc     = 1'b0;
    disp_reset   = 1'b0;
    result_inc   = 1'b0;
    result_reset = 1'b0;
    lep_disp_iter_load    = 1'b0;
    lep_result_iter_load  = 1'b0;
    lep_disp_iter_dec     = 1'b0;
    lep_disp_iter_clear   = 1'b0;
    lep_result_iter_dec   = 1'b0;
    lep_result_iter_clear = 1'b0;

    lep_disp_iter_load_value   = lep_iterations_i;
    lep_result_iter_load_value = lep_iterations_i;

    unique case (loop_state_i)
      LoopRegular,
      LoopHwLoop: ; // do nothing
      LoopLcp1: begin
        disp_inc   = dispatching;
        result_inc = retiring;
        if (goto_lcp2_i) begin
          disp_reset   = 1'b1;
          result_reset = 1'b1;
        end
      end
      LoopLcp2: begin
        disp_inc   = dispatching;
        result_inc = retiring;
        // Reset has higher prio than increment
        disp_reset   = last_disp_instr && dispatching;
        result_reset = last_result_instr && retiring;
        // Load the iteration counters
        lep_disp_iter_load   = 1'b1;
        lep_result_iter_load = 1'b1;
      end
      LoopLep: begin
        disp_inc     = dispatching;
        result_inc   = retiring;
        // Reset has higher prio than increment
        disp_reset   = last_disp_instr && dispatching;
        result_reset = last_result_instr && retiring;
        // Iteration handling - iteration has finished when instr counters wrap
        lep_disp_iter_dec   = disp_reset;
        // Decrement the iteration counter as long as there are results to capture.
        // This counter can underflow in case we have only store instructions. Reason is that any
        // store instruction always retires because there is no result to capture. We therefore let
        // the result counter immediately count down to zero.
        // TODO(colluca): not sure what this means
        lep_result_iter_dec = (lep_result_iter_count > '0) ? result_reset : 1'b0;
      end
      default: ; // do nothing
    endcase

    // Reset the RS
    if (restart_i) begin
      disp_reset        = 1'b1;
      result_reset      = 1'b1;
      lep_disp_iter_clear   = 1'b1;
      lep_result_iter_clear = 1'b1;
    end
  end

  // ---------------------------
  // Finish detection
  // ---------------------------

  // Finished: Asserted if we have finished in any cycle before.
  // Finish: Asserted if we finish in THIS cycle or have already finished.

  // TODO(colluca): lcp finish signals seem overly complex to me. They are only used in
  //                driving lcp_finish_o. What does the schnizo_controller really need to know?

  logic lcp_finished, lcp_finish;
  logic lep_finished, lep_finished_result, lep_finished_alternatively;
  logic lep_finish, lep_finish_disp, lep_finish_result;
  logic lep_finished_disp;

  // In LCP1 and LCP2 the RS has finished all instructions if:
  // - No dispatch request is pending
  // - There is no instruction in flight
  // The FU's busy flag is asserted as long as there is valid data in the path. This includes
  // valid data at the output and thus the FU is busy also in the cycle in which we retire
  // the instruction.
  // TODO(colluca): why do we need disp_req_valid_i?
  // TODO(colluca): this signal doesn't really tell us that we're finished with LCP,
  //                just that we are idle. It is probably additionally masked in the controller
  //                to determine if we are actually finished. Update description comment.
  assign lcp_finished = !fu_busy_i && !disp_req_valid_i && !disp_req_valid_i_q &&
                        (loop_state_i inside {LoopLcp1, LoopLcp2});

  // In LCP1 and LCP2 we finish in this cycle if:
  // - We have already finished
  // OR
  // - The result index is at the dispatch index and we retire in this cycle.
  // In LCP the dispatch index can never overtake the result pointer as we only increment the
  // index and never have a wrap around. A wrap around would only occur if we run out of slots.
  // But this can never happen as we would revert to regular loop execution if there are not
  // enough slots.
  // TODO(colluca): clarify what "overtake" means
  // TODO(colluca): my impression is that if this signal is asserted, lcp_finished is also
  //                asserted. In other words, the RHS of the || is not useful (except maybe
  //                for "retiring"). We could test this with an assertion
  assign lcp_finish =
    (lcp_finished || ((disp_count == result_count) && retiring)) && !disp_req_valid_i &&
    (loop_state_i inside {LoopLcp1, LoopLcp2});

  // In LEP the RS has finished if:
  // - All iterations are dispatched -> this is guaranteed if all results have been captured
  // AND
  // - All results are captured
  assign lep_finished_disp   = lep_disp_iter_count == '0;
  assign lep_finished_result = lep_result_iter_count == '0;
  // Stores will immediately finish the result iterations. Thus we need to factor in the dispatch
  // pointer.
  // TODO(colluca): why would the dispatch pointer not be incremented if the result pointer is?
  //                By definition, dispatch happens strictly before, or in the same cycle, as
  //                result capture
  assign lep_finished        = (lep_finished_result && lep_finished_disp) || !any_instr_captured;
  // This should be equivalent to:
  // - There is no instruction in flight & no dispatch request is pending
  // This approach could make the result iteration counter obsolete. But we must ensure that there
  // is always a valid dispatch request during the whole LEP. However, the finish detection anyway
  // requires the result iteration counter.
  // TODO(colluca): since we settled for using this, clean up all the legacy logic
  assign lep_finished_alternatively = ((loop_state_i == LoopLep) && lep_finished_disp && !fu_busy_i)
                                      || !any_instr_captured;

  // In LEP the finish condition is tricky as the dispatch index can "overtake" the result index.
  // The overtake can happen if the FU pipeline depth is larger than the number of slots.
  // We thus have to check also the iteration count.
  //
  // We finish during LEP if:
  // - We have already finished
  // OR
  // - All iterations were dispatched -> included in the result condition but used for LEP engine.
  // - No result capture is pending or we capture the last instruction in this cycle
  assign lep_finish_disp   = last_disp_iter && last_disp_instr && dispatching;
  assign lep_finish_result = last_result_iter && last_result_instr && retiring;
  // The dispatch finish condition is included in the result finish condition.
  // assign lep_finish        = (lep_finish_disp && lep_finish_result) || lep_finished;
  assign lep_finish        = lep_finished_alternatively;

  always_comb begin : finish_selection
    loop_finish_o = 1'b0;
    unique case (loop_state_i)
      LoopRegular,
      LoopHwLoop: loop_finish_o = 1'b0;
      LoopLcp1,
      LoopLcp2:   loop_finish_o = lcp_finish;
      LoopLep:    loop_finish_o = lep_finish;
      default:    loop_finish_o = 1'b0;
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
  assign lep_do_dispatch         = !lep_finished_disp && (loop_state_i inside {LoopLep}) &&
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
  assign disp_req = disp_req_i_q; // Always use the external dispatch request.
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

  counter #(
    .WIDTH          (NofRssWidthExt),
    .STICKY_OVERFLOW(0)
  ) i_disp_counter (
    .clk_i,
    .rst_ni    (!rst_i),
    .clear_i   (disp_reset),
    .en_i      (disp_inc),
    .load_i    ('0),
    .down_i    ('0),
    .d_i       ('0),
    .q_o       (disp_count),
    .overflow_o()
  );

  assign disp_idx = disp_count[NofRssWidth-1:0];

  counter #(
    .WIDTH          (NofRssWidthExt),
    .STICKY_OVERFLOW(0)
  ) i_result_counter (
    .clk_i,
    .rst_ni    (!rst_i),
    .clear_i   (result_reset),
    .en_i      (result_inc),
    .load_i    ('0),
    .down_i    ('0),
    .d_i       ('0),
    .q_o       (result_count),
    .overflow_o()
  );

  counter #(
    .WIDTH          (MaxIterationsW),
    .STICKY_OVERFLOW(0)
  ) i_lep_disp_iter_counter (
    .clk_i,
    .rst_ni    (!rst_i),
    .clear_i   (lep_disp_iter_clear),
    .en_i      (lep_disp_iter_dec),
    .load_i    (lep_disp_iter_load),
    .down_i    (1'b1),
    .d_i       (lep_disp_iter_load_value),
    .q_o       (lep_disp_iter_count),
    .overflow_o()
  );

  counter #(
    .WIDTH          (MaxIterationsW),
    .STICKY_OVERFLOW(0)
  ) i_lep_result_iter_counter (
    .clk_i,
    .rst_ni    (!rst_i),
    .clear_i   (lep_result_iter_clear),
    .en_i      (lep_result_iter_dec),
    .load_i    (lep_result_iter_load),
    .down_i    (1'b1),
    .d_i       (lep_result_iter_load_value),
    .q_o       (lep_result_iter_count),
    .overflow_o()
  );

endmodule
