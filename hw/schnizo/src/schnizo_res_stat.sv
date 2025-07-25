// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: The Reservation station which handles the instruction issuing of a functional
// unit during superscalar loop execution.

// Abbreviations:
// FU:  Functional Unit. This is for example an ALU, FPU or LSU.
// RS:  Reservation Station. Holds multiple RSS for a single FU and controls the execution.
// RSS: Reservation Station Slot. A slot can hold one instruction with all the required
//      information for the superscalar execution.
// RF:  Register File

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

module schnizo_res_stat import schnizo_pkg::*; #(
  parameter int unsigned NofRss         = 4,
  // The maximal number of operands
  parameter int unsigned NofOperands    = 3,
  // How many slots in parallel can request / capture operands.
  parameter int unsigned NofOpPorts     = 1,
  parameter int unsigned NofOperandIfs  = 1,
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
  output disp_rsp_t disp_rsp_o,

  // The issued instruction - to FU
  output issue_req_t issue_req_o,
  output logic       issue_req_valid_o,
  input  logic       issue_req_ready_i,

  // Result from FU
  input  result_t result_i,
  input  logic    result_valid_i,
  output logic    result_ready_o,

  // RF writeback
  output result_t     rf_wb_result_o,
  output result_tag_t rf_wb_tag_o,
  output logic        rf_wb_valid_o,
  input  logic        rf_wb_ready_i,

  /// Operand distribution network
  // Operand request interface - outgoing - request a result as operand
  output operand_req_t [NofOpPorts-1:0][NofOperands-1:0] op_reqs_o,
  output logic         [NofOpPorts-1:0][NofOperands-1:0] op_reqs_valid_o,
  input  logic         [NofOpPorts-1:0][NofOperands-1:0] op_reqs_ready_i,

  // Result request interface - incoming - from each possible requester
  input  res_req_t [NofOperandIfs-1:0] res_reqs_i,
  input  logic     [NofOperandIfs-1:0] res_reqs_valid_i,
  output logic     [NofOperandIfs-1:0] res_reqs_ready_o,

  // Result response interface - outgoing - result as operand response
  // Shared port for all slots.
  output res_rsp_t [NofResRspIfs-1:0] res_rsps_o,
  output logic     [NofResRspIfs-1:0] res_rsps_valid_o,
  input  logic     [NofResRspIfs-1:0] res_rsps_ready_i,

  // Operand response interface - incoming - returning result as operand
  input  operand_t [NofOpPorts-1:0][NofOperands-1:0] op_rsps_i,
  input  logic     [NofOpPorts-1:0][NofOperands-1:0] op_rsps_valid_i,
  output logic     [NofOpPorts-1:0][NofOperands-1:0] op_rsps_ready_o
);
  // ---------------------------
  // Reservation Station definitions
  // ---------------------------
  // The RSS pointer / index vector width
  localparam integer unsigned NofRssWidth    = cf_math_pkg::idx_width(NofRss);
  // We need to count from 0 to NofRss for the control logic -> +1 bit
  localparam integer unsigned NofRssWidthExt = cf_math_pkg::idx_width(NofRss+1);

  // ---------------------------
  // Reservation Station Slots
  // ---------------------------
  disp_req_t              disp_req;
  logic                   disp_req_valid;
  logic                   disp_req_ready;
  // disp_req_t              disp_req_internal; // not required
  logic                   disp_req_internal_valid;
  logic                   disp_req_internal_ready; // unused, internal disp logic is always valid
  logic      [NofRss-1:0] disp_reqs_valid;
  logic      [NofRss-1:0] disp_reqs_ready;
  logic      [NofRss-1:0] rss_retiring;

  // The pointers / indexes to select the appropriate RSS. The issue MUX is always in sync with
  // the dispatch DEMUX.
  logic [NofRssWidth-1:0] disp_idx;
  logic [NofRssWidth-1:0] result_idx;

  // To / from FU and RF writeback
  issue_req_t  [NofRss-1:0] issue_reqs;
  logic        [NofRss-1:0] issue_reqs_valid;
  logic        [NofRss-1:0] issue_reqs_ready;
  result_t     [NofRss-1:0] results;
  logic        [NofRss-1:0] results_valid;
  logic        [NofRss-1:0] results_ready;
  result_t     [NofRss-1:0] rf_wb_results;
  result_tag_t [NofRss-1:0] rf_wb_tags;
  logic        [NofRss-1:0] rf_wbs_valid;
  logic        [NofRss-1:0] rf_wbs_ready;

  // loop control
  logic last_disp_instr;
  logic last_disp_iter;
  logic last_result_instr;
  logic last_result_iter;

  // ---------------------------
  // Operand distribution network
  // ---------------------------
  // These internal signals are for each slot and are MUXed below to the number of xbar connections
  operand_req_t [NofRss-1:0][NofOperands-1:0] op_reqs;
  logic         [NofRss-1:0][NofOperands-1:0] op_reqs_valid;
  logic         [NofRss-1:0][NofOperands-1:0] op_reqs_ready;
  dest_mask_t   [NofRss-1:0]                  dest_masks;
  logic         [NofRss-1:0]                  dest_masks_valid;
  logic         [NofRss-1:0]                  dest_masks_ready;
  res_rsp_t     [NofRss-1:0]                  res_rsps;
  logic         [NofRss-1:0]                  res_rsps_valid;
  logic         [NofRss-1:0]                  res_rsps_ready;
  operand_t     [NofRss-1:0][NofOperands-1:0] op_rsps;
  logic         [NofRss-1:0][NofOperands-1:0] op_rsps_valid;
  logic         [NofRss-1:0][NofOperands-1:0] op_rsps_ready;

  // ---------------------------
  // Cut the external dispatch request
  // ---------------------------
  disp_req_t disp_req_i_q;
  logic      disp_req_valid_i_q;
  logic      disp_req_ready_o_q;

  // The cut will result in delayed exceptions. If an exception occurs it will trigger the
  // exception at the next instruction.
  logic disp_req_valid_guarded;
  logic disp_req_ready_o_raw;
  // Do not accept a new dispatch request if we are currently handling one or we are full.
  assign disp_req_valid_guarded = disp_req_valid_i && !disp_req_valid_i_q && !rs_full_o;
  // Do not signal ready until we are processing the request. This allows to handle branches where
  // the target address is only valid in the cycle the ALU computes it.
  // This is in the effective dispatch cycle because the ALU is single cycle.
  assign disp_req_ready_o = disp_req_ready_o_raw && !disp_req_valid_i_q && !rs_full_o;

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

  // ---------------------------
  // Slots
  // ---------------------------
  // Local signals used for result request filtering
  slot_id_t [NofRss-1:0] slot_ids;
  logic     [NofRss-1:0] res_iters;

  for (genvar rss = 0; rss < NofRss; rss = rss + 1) begin : gen_rss
    assign slot_ids[rss] = slot_id_t'(rss);
    producer_id_t rss_id;
    assign rss_id = producer_id_t'{
      slot_id: slot_ids[rss],
      rs_id:   producer_id_i.rs_id
    };

    schnizo_res_stat_slot #(
      .NofOperands  (NofOperands),
      .ConsumerCount(ConsumerCount),
      .RegAddrWidth (RegAddrWidth),
      .disp_req_t   (disp_req_t),
      .producer_id_t(producer_id_t),
      .operand_req_t(operand_req_t),
      .operand_t    (operand_t),
      .res_req_t    (res_req_t),
      .dest_mask_t  (dest_mask_t),
      .res_rsp_t    (res_rsp_t),
      .issue_req_t  (issue_req_t),
      .result_t     (result_t),
      .result_tag_t (result_tag_t)
    ) i_rss (
      .clk_i,
      .rst_i,

      .restart_i            (restart_i),
      .is_last_disp_iter_i  (last_disp_iter),
      .is_last_result_iter_i(last_result_iter),
      .own_producer_id_i    (rss_id),
      .res_iter_o           (res_iters[rss]),
      .retired_o            (rss_retiring[rss]),

      .disp_req_i      (disp_req),
      .disp_req_valid_i(disp_reqs_valid[rss]),
      .disp_req_ready_o(disp_reqs_ready[rss]),

      .op_reqs_o      (op_reqs[rss]),
      .op_reqs_valid_o(op_reqs_valid[rss]),
      .op_reqs_ready_i(op_reqs_ready[rss]),

      .dest_mask_i      (dest_masks[rss]),
      .dest_mask_valid_i(dest_masks_valid[rss]),
      .dest_mask_ready_o(dest_masks_ready[rss]),

      .res_rsp_o      (res_rsps[rss]),
      .res_rsp_valid_o(res_rsps_valid[rss]),
      .res_rsp_ready_i(res_rsps_ready[rss]),

      .op_rsps_i      (op_rsps[rss]),
      .op_rsps_valid_i(op_rsps_valid[rss]),
      .op_rsps_ready_o(op_rsps_ready[rss]),

      .issue_req_o      (issue_reqs[rss]),
      .issue_req_valid_o(issue_reqs_valid[rss]),
      .issue_req_ready_i(issue_reqs_ready[rss]),

      .result_i      (results[rss]),
      .result_valid_i(results_valid[rss]),
      .result_ready_o(results_ready[rss]),

      .rf_wb_result_o(rf_wb_results[rss]),
      .rf_wb_tag_o   (rf_wb_tags[rss]),
      .rf_wb_valid_o (rf_wbs_valid[rss]),
      .rf_wb_ready_i (rf_wbs_ready[rss])
    );

  end

  // ---------------------------
  // Operand Distribution Network
  // ---------------------------
  // Operand requests:
  // Here we connect the RSSs to the crossbar networks. A full crossbar where each slot has
  // dedicated connections for each operand is infeasible. We thus only provide a certain
  // amount of ports. One port features a connection for all operands, i.e., can serve one slot
  // at a time. We always connect the currently active slot on port 0. Any other port can be used
  // to "prerequest" operands but this not implemented yet.

  // Select which RSS currently can place requests based on which RSS is scheduled to dispatch.
  // In case the dispatch index overflows (we are full), tie down any signals to a default value.
  logic sel_rss_valid;
  assign sel_rss_valid = (disp_idx >= NofRss) ? 1'b0 : 1'b1;
  logic [NofRssWidth-1:0] sel_rss;
  assign sel_rss = sel_rss_valid ? disp_idx : '0;

  always_comb begin : op_req_gen
    op_reqs_o        = '0;
    op_reqs_valid_o  = '0;
    op_reqs_ready    = '0;
    op_rsps          = '0;
    op_rsps_valid    = '0;
    op_rsps_ready_o  = '0;

    for (int port = 0; port < NofOpPorts; port++) begin
      if (port == 0) begin
        for (int op = 0; op < NofOperands; op++) begin
          // Request
          op_reqs_o[port][op] = op_reqs[sel_rss][op];
          // Tie down if RSS selection is not valid
          op_reqs_valid_o[port][op]  = op_reqs_valid[sel_rss][op] & sel_rss_valid;
          op_reqs_ready[sel_rss][op] = op_reqs_ready_i[port][op] & sel_rss_valid;
          // Response
          op_rsps[sel_rss][op]       = op_rsps_i[port][op];
          op_rsps_valid[sel_rss][op] = op_rsps_valid_i[port][op] & sel_rss_valid;
          op_rsps_ready_o[port][op]  = op_rsps_ready[sel_rss][op] & sel_rss_valid;
        end
      end else begin
        // We only support one port currently
        op_reqs_o[port]       = '0;
        op_reqs_valid_o[port] = '0;
        op_rsps_ready_o[port] = '0;
      end
    end
  end

  // Result requests:
  // Each reservation station has one connection to the result request crossbar. This connection
  // is shared between all slots. However, this connection must be able to serve requests from
  // multiple operands at the same time as otherwise we have a hefty performance issue.
  // We enable therefore coalescing requests. In addition, we need a filtering such that we only
  // handle request which currently can be served. Otherwise, deadlocks will occur.
  schnizo_res_req_mux #(
    .NofOperandIfs(NofOperandIfs),
    .NofSlots     (NofRss),
    .res_req_t    (res_req_t),
    .dest_mask_t  (dest_mask_t),
    .slot_id_t    (slot_id_t)
  ) i_res_req_mux (
    .clk_i,
    .rst_i,
    .slot_ids_i       (slot_ids),
    .res_iters_i      (res_iters),
    .res_req_i        (res_reqs_i),
    .res_req_valid_i  (res_reqs_valid_i),
    .res_req_ready_o  (res_reqs_ready_o),
    .dest_mask_o      (dest_masks),
    .dest_mask_valid_o(dest_masks_valid),
    .dest_mask_ready_i(dest_masks_ready)
  );

  // Result response:
  // On the response side we could simplify it to one shared input to the result response crossbar.
  // However, having an arbiter in the path drastically degrades the critical path.
  // Therefore we keep a dedicated input for each slot.
  assign res_rsps_o       = res_rsps;
  assign res_rsps_valid_o = res_rsps_valid;
  assign res_rsps_ready   = res_rsps_ready_i;

  // ---------------------------
  // LxP Controller
  // ---------------------------
  // Generates the instruction dispatch, issue, retire & writeback control signals and handles
  // the LEP iterations.
  logic dispatching;
  // logic issuing;

  assign dispatching = disp_req_valid && disp_req_ready;
  // assign issuing     = issue_req_valid_o && issue_req_ready_i;

  logic retiring;
  // An instruction retires as soon as the result is handshaked, i.e.:
  // assign retiring    = result_valid_i && result_ready_o;
  // However, a store has no result. Thus we generate this signal inside the RSS as the RSS knows
  // if the instruction is a store or any other instruction.
  // The result pointer can point to +1 of NofRSS. We thus have to limit it inside the range.
  assign retiring = (result_idx >= NofRss) ? 1'b0 : rss_retiring[result_idx];

  // The counters for the index control logic
  // The lcp_xxx and lep_xxx counters count instructions and do count up.
  // The lep_xxx_iter counters count instructions and do count down.
  logic [NofRssWidthExt-1:0] lcp_disp_count;
  logic                      lcp_disp_inc;
  logic                      lcp_disp_reset;

  logic [NofRssWidthExt-1:0] lcp_result_count;
  logic                      lcp_result_inc;
  logic                      lcp_result_reset;

  logic [NofRssWidthExt-1:0] lep_disp_count;
  logic                      lep_disp_inc;
  logic                      lep_disp_reset;

  logic [MaxIterationsW-1:0] lep_disp_iter_count;
  logic                      lep_disp_iter_dec;
  logic                      lep_disp_iter_load;
  logic [MaxIterationsW-1:0] lep_disp_iter_load_value;
  logic                      lep_disp_iter_clear;

  logic [NofRssWidthExt-1:0] lep_result_count;
  logic                      lep_result_inc;
  logic                      lep_result_reset;

  logic [MaxIterationsW-1:0] lep_result_iter_count;
  logic                      lep_result_iter_dec;
  logic                      lep_result_iter_load;
  logic [MaxIterationsW-1:0] lep_result_iter_load_value;
  logic                      lep_result_iter_clear;

  // The LCP counter serves as RSS allocated counter to know the iteration size in LEP.
  // It is not reset when switching from LCP2 to LEP.
  logic [NofRssWidthExt-1:0] rss_allocated_count;
  assign rss_allocated_count = lcp_disp_count;

  assign last_disp_instr   = lep_disp_count == (rss_allocated_count - 1);
  assign last_disp_iter    = lep_disp_iter_count == 1;
  assign last_result_instr = lep_result_count == (rss_allocated_count - 1);
  assign last_result_iter  = lep_result_iter_count == 1;

  assign rs_full_o = (rss_allocated_count == NofRss[NofRssWidthExt-1:0]);

  logic any_instr_captured;
  assign any_instr_captured = (rss_allocated_count != '0);

  always_comb begin : counter_control
    lcp_disp_inc          = 1'b0;
    lcp_disp_reset        = 1'b0;
    lcp_result_inc        = 1'b0;
    lcp_result_reset      = 1'b0;
    lep_disp_iter_load    = 1'b0;
    lep_result_iter_load  = 1'b0;
    lep_disp_inc          = 1'b0;
    lep_result_inc        = 1'b0;
    lep_disp_reset        = 1'b0;
    lep_result_reset      = 1'b0;
    lep_disp_iter_dec     = 1'b0;
    lep_disp_iter_clear   = 1'b0;
    lep_result_iter_dec   = 1'b0;
    lep_result_iter_clear = 1'b0;

    lep_disp_iter_load_value   = lep_iterations_i;
    lep_result_iter_load_value = lep_iterations_i;

    unique case(loop_state_i)
      LoopRegular,
      LoopHwLoop: ; // do nothing
      LoopLcp1: begin
        lcp_disp_inc   = dispatching;
        lcp_result_inc = retiring;
        if (goto_lcp2_i) begin
          lcp_disp_reset   = 1'b1;
          lcp_result_reset = 1'b1;
        end
      end
      LoopLcp2: begin
        lcp_disp_inc   = dispatching;
        lcp_result_inc = retiring;
        // Load the iteration counters
        lep_disp_iter_load   = 1'b1;
        lep_result_iter_load = 1'b1;
      end
      LoopLep: begin
        lep_disp_inc     = dispatching;
        lep_result_inc   = retiring;
        // Reset has higher prio than increment
        lep_disp_reset   = last_disp_instr && dispatching;
        lep_result_reset = last_result_instr && retiring;
        // Iteration handling - iteration has finished when instr counters wrap
        lep_disp_iter_dec   = lep_disp_reset;
        // Decrement the iteration counter as long as there are results to capture.
        // This counter can underflow in case we have only store instructions. Reason is that any
        // store instruction always retires because there is no result to capture. We therefore let
        // the result counter immediately count down to zero.
        lep_result_iter_dec = (lep_result_iter_count > '0) ? lep_result_reset : 1'b0;
      end
      default: ; // do nothing
    endcase

    // Reset the RS
    if (restart_i) begin
      lcp_disp_reset        = 1'b1;
      lcp_result_reset      = 1'b1;
      lep_disp_reset        = 1'b1;
      lep_disp_iter_clear   = 1'b1;
      lep_result_reset      = 1'b1;
      lep_result_iter_clear = 1'b1;
    end
  end

  // ---------------------------
  // Finish detection
  // ---------------------------
  // Finished: Asserted if we have finished in any cycle before.
  // Finish: Asserted if we finish in THIS cycle or have already finished.
  logic lcp_finished, lcp_finish;
  logic lep_finished, lep_finished_result, lep_finished_alternatively;
  logic lep_finish, lep_finish_disp, lep_finish_result;
  logic lep_finished_disp;

  // In LCP1 and LCP2 the RS has finished all instructions if:
  // - There is no instruction in flight
  // - No dispatch request is pending
  // The FU's busy flag is asserted as long as there is valid data in the path. This includes the
  // output and thus the FU is busy also in the cycle were we retire the instruction.
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
  assign lcp_finish =
    (lcp_finished || ((lcp_disp_count == lcp_result_count) && retiring)) && !disp_req_valid_i &&
    (loop_state_i inside {LoopLcp1, LoopLcp2});

  // In LEP the RS has finished if:
  // - All iterations are dispatched -> this is given if all results are captured
  // - All results are captured
  assign lep_finished_disp   = lep_disp_iter_count == '0;
  assign lep_finished_result = lep_result_iter_count == '0;
  // Stores will immediately finish the result iterations. Thus we need to factor in the dispatch
  // pointer.
  assign lep_finished        = (lep_finished_result && lep_finished_disp) || !any_instr_captured;
  // This should be equivalent to:
  // - There is no instruction in flight & no dispatch request is pending
  // This approach could make the result iteration counter obsolete. But we must ensure that there
  // is always a valid dispatch request during the whole LEP. However, the finish detection anyway
  // requires the result iteration counter.
  assign lep_finished_alternatively = !fu_busy_i && !disp_req_internal_valid;
  // TODO: At init these two signals differ
  // `ASSERT(LepAlternativeFinished, lep_finished_alternatively == lep_finished, clk_i, rst_i);

  // In LEP the finish condition is tricky as the dispatch index can "overtake" the result index.
  // The overtake can happen if the FU pipeline depth is larger than the number of slots.
  // We thus have to check also the iteration count.
  //
  // We finish during LEP if:
  // - We have already finished
  // OR
  // - All iterations were dispatched -> included in the result condition but used for LEP engine.
  // - No result capture is pending or we capture the last instruction in this cycle
  assign lep_finish_disp   = (last_disp_iter & last_disp_instr & dispatching);
  assign lep_finish_result = last_result_iter && last_result_instr && retiring;
  // The dispatch finish condition is included in the result finish condition.
  assign lep_finish        = (lep_finish_disp && lep_finish_result) || lep_finished;

  always_comb begin : finish_selection
    loop_finish_o = 1'b0;
    unique case(loop_state_i)
      LoopRegular,
      LoopHwLoop: loop_finish_o = 1'b0;
      LoopLcp1,
      LoopLcp2:   loop_finish_o = lcp_finish;
      LoopLep:    loop_finish_o = lep_finish;
      default:    loop_finish_o = 1'b0;
    endcase
  end

  // ---------------------------
  // LEP Dispatcher
  // ---------------------------
  // In LEP we can dispatch the RSSs if we have a instruction captured until we reached the amount
  // of iterations. The actual dispatch request data is irrelevant as the instruction is captured
  // in the RSS.
  logic lep_do_dispatch;
  assign lep_do_dispatch         = !lep_finished_disp && (loop_state_i inside {LoopLep}) &&
                                   any_instr_captured;
  assign disp_req_internal_valid = lep_do_dispatch;

  // ---------------------------
  // Dispatch & issue MUX, Result MUX
  // ---------------------------
  // The dispatch request selection. Either select request from outside or from LEP engine.
  logic sel_disp_req_internal;

  always_comb begin : index_selection
    disp_idx              = '0;
    result_idx            = '0;
    sel_disp_req_internal = 1'b0;

    unique case(loop_state_i)
      LoopRegular,
      LoopHwLoop: begin
        disp_idx   = '0;
        result_idx = '0;
      end
      LoopLcp1,
      LoopLcp2: begin
        disp_idx   = lcp_disp_count[NofRssWidth-1:0];
        result_idx = lcp_result_count[NofRssWidth-1:0];
      end
      LoopLep: begin
        disp_idx              = lep_disp_count[NofRssWidth-1:0];
        result_idx            = lep_result_count[NofRssWidth-1:0];
        sel_disp_req_internal = 1'b1;
      end
      default: begin
        disp_idx   = '0;
        result_idx = '0;
      end
    endcase
  end

  // Select between external (LCP) and internal dispatch request (LEP). The internal dispatch
  // request has no actual data as the instruction is already captured in the RSS. Thus we can
  // simplify the MUX to only mux the valid/ready handshake.
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

  // Dispatch request DEMUX
  // As disp_idx can take a value outside of the DEMUX range, we must tie down the ready in
  // this case.
  logic disp_req_ready_raw;
  assign disp_req_ready = (disp_idx >= NofRss) ? 1'b0 : disp_req_ready_raw;

  stream_demux #(
    .N_OUP (NofRss)
  ) i_disp_demux (
    .inp_valid_i(disp_req_valid),
    .inp_ready_o(disp_req_ready_raw),
    .oup_sel_i  (disp_idx),
    .oup_valid_o(disp_reqs_valid),
    .oup_ready_i(disp_reqs_ready)
  );

  assign disp_rsp_o = producer_id_t'{
    // Here we can go out of bounds because this response is only valid if we use a existing slot.slot_id
    slot_id: (disp_idx >= NofRss) ? 1'b0 : slot_ids[disp_idx],
    rs_id:   producer_id_i.rs_id
  };

  // Issue request MUX
  // As the disp_idx can overflow the MUX input, we tie down the handshake signals in this case.
  logic issue_req_valid_raw;
  issue_req_t issue_req_raw;
  logic [NofRss-1:0] issue_reqs_ready_raw;
  assign issue_reqs_ready = (disp_idx >= NofRss) ? {NofRss{1'b0}} : issue_reqs_ready_raw;

  if (NofRss == 1) begin : gen_1slot_issue
    // If we only have one slot, we can directly connect the issue request.
    assign issue_req_raw           = issue_reqs[0];
    assign issue_req_valid_raw     = issue_reqs_valid[0];
    assign issue_reqs_ready_raw[0] = issue_req_ready_i;
  end else begin : gen_nslots_issue
    stream_mux #(
      .DATA_T(issue_req_t),
      .N_INP (NofRss)
    ) i_issue_mux (
      .inp_data_i (issue_reqs),
      .inp_valid_i(issue_reqs_valid),
      .inp_ready_o(issue_reqs_ready_raw),
      // The same MUX ctrl signal as for the dispatch demux because dispatch & issue handshake
      // simultaneously.
      .inp_sel_i  (disp_idx), // This idx can overflow and this would set the req handshake to X!
      .oup_data_o (issue_req_raw),
      .oup_valid_o(issue_req_valid_raw),
      .oup_ready_i(issue_req_ready_i)
    );
  end

  // tie down valid & data signal if we overflow.
  assign issue_req_valid_o = (disp_idx >= NofRss) ? 1'b0 : issue_req_valid_raw;
  assign issue_req_o       = (disp_idx >= NofRss) ?   '0 : issue_req_raw;

  // Result DEMUX
  // result_idx can overflow the same way as the disp_idx. Tie down the ready in case of overflow.
  logic result_ready_raw;
  assign result_ready_o = (result_idx >= NofRss) ? 1'b0 : result_ready_raw;

  assign results = {NofRss{result_i}};
  stream_demux #(
    .N_OUP (NofRss)
  ) i_result_demux (
    .inp_valid_i(result_valid_i),
    .inp_ready_o(result_ready_raw),
    .oup_sel_i  (result_idx),
    .oup_valid_o(results_valid),
    .oup_ready_i(results_ready)
  );

  // Writeback MUX - This could also be implemented with an arbiter but a MUX is simpler & smaller.
  typedef struct packed {
    result_t     result;
    result_tag_t tag;
  } result_and_tag_t;

  result_and_tag_t [NofRss-1:0] results_and_tags;
  result_and_tag_t              result_and_tag;

  for (genvar rss = 0; rss < NofRss; rss++) begin : gen_merge_wb
    assign results_and_tags[rss].result = rf_wb_results[rss];
    assign results_and_tags[rss].tag    = rf_wb_tags[rss];
  end

  // result_idx overflow tie down
  logic            rf_wb_valid_raw;
  result_and_tag_t result_and_tag_raw;

  if (NofRss == 1) begin : gen_1slot_wb
    assign result_and_tag_raw = results_and_tags[0];
    assign rf_wb_valid_raw    = rf_wbs_valid[0];
    assign rf_wbs_ready[0]    = rf_wb_ready_i;
  end else begin : gen_nslots_wb
    stream_mux #(
      .DATA_T(result_and_tag_t),
      .N_INP (NofRss)
    ) i_wb_mux (
      .inp_data_i (results_and_tags),
      .inp_ready_o(rf_wbs_ready),
      .inp_valid_i(rf_wbs_valid),
      .inp_sel_i  (result_idx),
      .oup_data_o (result_and_tag_raw),
      .oup_valid_o(rf_wb_valid_raw),
      .oup_ready_i(rf_wb_ready_i)
    );
  end

  assign rf_wb_valid_o = (result_idx >= NofRss) ? 1'b0 : rf_wb_valid_raw;
  assign result_and_tag = (result_idx >= NofRss) ?  '0 : result_and_tag_raw;

  assign rf_wb_result_o = result_and_tag.result;
  assign rf_wb_tag_o    = result_and_tag.tag;

  // ---------------------------
  // Counters
  // ---------------------------
  counter #(
    .WIDTH          (NofRssWidthExt),
    .STICKY_OVERFLOW(0)
  ) i_lcp_disp_counter (
    .clk_i,
    .rst_ni    (~rst_i),
    .clear_i   (lcp_disp_reset),
    .en_i      (lcp_disp_inc),
    .load_i    ('0),
    .down_i    ('0),
    .d_i       ('0),
    .q_o       (lcp_disp_count),
    .overflow_o()
  );

  counter #(
    .WIDTH          (NofRssWidthExt),
    .STICKY_OVERFLOW(0)
  ) i_lcp_result_counter (
    .clk_i,
    .rst_ni    (~rst_i),
    .clear_i   (lcp_result_reset),
    .en_i      (lcp_result_inc),
    .load_i    ('0),
    .down_i    ('0),
    .d_i       ('0),
    .q_o       (lcp_result_count),
    .overflow_o()
  );

  counter #(
    .WIDTH          (NofRssWidthExt),
    .STICKY_OVERFLOW(0)
  ) i_lep_disp_counter (
    .clk_i,
    .rst_ni    (~rst_i),
    .clear_i   (lep_disp_reset),
    .en_i      (lep_disp_inc),
    .load_i    ('0),
    .down_i    ('0),
    .d_i       ('0),
    .q_o       (lep_disp_count),
    .overflow_o()
  );

  counter #(
    .WIDTH          (MaxIterationsW),
    .STICKY_OVERFLOW(0)
  ) i_lep_disp_iter_counter (
    .clk_i,
    .rst_ni    (~rst_i),
    .clear_i   (lep_disp_iter_clear),
    .en_i      (lep_disp_iter_dec),
    .load_i    (lep_disp_iter_load),
    .down_i    (1'b1),
    .d_i       (lep_disp_iter_load_value),
    .q_o       (lep_disp_iter_count),
    .overflow_o()
  );

  counter #(
    .WIDTH          (NofRssWidthExt),
    .STICKY_OVERFLOW(0)
  ) i_lep_result_counter (
    .clk_i,
    .rst_ni    (~rst_i),
    .clear_i   (lep_result_reset),
    .en_i      (lep_result_inc),
    .load_i    ('0),
    .down_i    ('0),
    .d_i       ('0),
    .q_o       (lep_result_count),
    .overflow_o()
  );

  counter #(
    .WIDTH          (MaxIterationsW),
    .STICKY_OVERFLOW(0)
  ) i_lep_result_iter_counter (
    .clk_i,
    .rst_ni    (~rst_i),
    .clear_i   (lep_result_iter_clear),
    .en_i      (lep_result_iter_dec),
    .load_i    (lep_result_iter_load),
    .down_i    (1'b1),
    .d_i       (lep_result_iter_load_value),
    .q_o       (lep_result_iter_count),
    .overflow_o()
  );

endmodule
