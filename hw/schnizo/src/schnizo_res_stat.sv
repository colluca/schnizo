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
  parameter int unsigned NofConstants   = 4,
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
  parameter type         ext_res_req_t  = logic,
  parameter type         available_result_t = logic,
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
  output available_result_t [NofRss-1:0] available_results_o,

  // Operand request interface - outgoing - request a result as operand
  output operand_req_t [NofOperands-1:0] op_reqs_o,
  output logic         [NofOperands-1:0] op_reqs_valid_o,
  input  logic         [NofOperands-1:0] op_reqs_ready_i,

  // Result request interface - incoming - from each possible requester
  input  ext_res_req_t [NofResRspIfs-1:0] res_reqs_i,
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

  // TODO(colluca): we could replace is_used and is_producer, with a single enum type variable
  //                {Unused, Static, Dynamic}
  typedef struct packed {
    logic         is_used;
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
  // TODO(colluca): what does this mean? Is it still valid after we decoupled issue and dispatch
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

  for (genvar rss = 0; rss < NofRss; rss++) begin : gen_rss
    assign slot_ids[rss] = slot_id_t'(rss);
    assign rss_ids[rss] = producer_id_t'{
      slot_id: slot_ids[rss],
      rs_id:   producer_id_i.rs_id
    };

    schnizo_res_stat_slot #(
      .NofOperands  (NofOperands),
      .ConsumerCount(ConsumerCount),
      .RegAddrWidth (RegAddrWidth),
      .rss_idx_t    (rss_idx_t),
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

      .producer_id_i        (rss_ids[rss]),
      .loop_state_i         (loop_state_i),
      .restart_i            (restart_i),
      .is_last_disp_iter_i  (last_disp_iter),
      .is_last_result_iter_i(last_result_iter),
      .retired_o            (rss_retiring[rss]),
      .available_result_o   (available_results_o[rss]),

      .disp_req_i      (disp_req),
      .disp_req_valid_i(disp_reqs_valid[rss]),
      .disp_req_ready_o(disp_reqs_ready[rss]),

      .op_reqs_o      (op_reqs[rss]),
      .op_reqs_valid_o(op_reqs_valid[rss]),
      .op_reqs_ready_i(op_reqs_ready[rss]),

      .dest_mask_i      (res_reqs_i[rss]),
      .dest_mask_valid_i(res_reqs_valid_i[rss]),
      .dest_mask_ready_o(res_reqs_ready_o[rss]),

      .res_rsp_o      (res_rsps_o[rss]),
      .res_rsp_valid_o(res_rsps_valid_o[rss]),
      .res_rsp_ready_i(res_rsps_ready_i[rss]),

      .op_rsps_i      (op_rsps[rss]),
      .op_rsps_valid_i(op_rsps_valid[rss]),
      .op_rsps_ready_o(op_rsps_ready[rss]),

      .issue_req_o      (issue_reqs[rss]),
      .issue_req_valid_o(issue_reqs_valid[rss]),
      .issue_req_ready_i(issue_reqs_ready[rss]),

      .result_i      (results[rss]),
      .result_valid_i(results_valid[rss]),
      .result_ready_o(results_ready[rss]),

      .rf_wb_tag_o      (rf_wb_tags[rss]),
      .rf_do_writeback_o(rf_do_writebacks[rss])
    );

  end

  /////////////////////////
  // Operand request mux //
  /////////////////////////

  // Here we connect the RSSs to the ODN. A full crossbar where each slot has
  // dedicated connections for each operand is infeasible. We thus only provide a certain
  // amount of ports. One port features a connection for all operands, i.e., can serve one slot
  // at a time. We always connect the currently active slot on port 0. Any other port can be used
  // to "prerequest" operands but this is not implemented yet.
  // This block therefore muxes the operand requests from the RSSs onto the operand request ports.
  // Similarly, it demuxes the operand response ports back to the requesting RSSs.
  // TODO(colluca): should we simplify this description by just assuming we have a single port
  //                and leaving out all the other details, or moving them elsewhere?

  // TODO(colluca): Shouldn't we use "issue" instead of "dispatch" in this comment?
  // Select which RSS currently can place requests based on which RSS is scheduled to dispatch.
  // In case the dispatch index overflows (we are full), tie down any signals to a default value.
  logic sel_rss_valid;
  assign sel_rss_valid = (disp_idx >= NofRss) ? 1'b0 : 1'b1;
  rss_idx_t sel_rss;
  assign sel_rss = sel_rss_valid ? disp_idx : '0;

  always_comb begin : op_req_mux
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
        // TODO(colluca): remove ports altogether
        op_reqs_o[port]       = '0;
        op_reqs_valid_o[port] = '0;
        op_rsps_ready_o[port] = '0;
      end
    end
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

  logic result_hs;
  assign result_hs = result_valid_i && result_ready_o;

  logic retire_at_issue;

  // Dispatch and result trip counter outputs
  rss_cnt_t disp_cnt;
  rss_idx_t disp_idx, issue_idx, result_idx;
  logic     last_disp;
  logic     trip_issue;
  logic     last_result, trip_result;

  logic [MaxIterationsW-1:0] lep_issue_iter_count;
  logic [MaxIterationsW-1:0] lep_result_iter_count;

  // The number of RSSs allocated during LCP1 is captured for use in LCP2 and LEP.
  // We snapshot the dispatch counter on the LCP1->LCP2 transition.
  rss_cnt_t num_allocated_rss_d, num_allocated_rss_q;
  assign num_allocated_rss_d = goto_lcp2_i ? disp_cnt + disp_hs : num_allocated_rss_q;
  `FFAR(num_allocated_rss_q, num_allocated_rss_d, '0, clk_i, rst_i);

  assign rs_full_o = disp_cnt == NofRss;

  logic last_result_iter;
  assign last_result_iter = lep_result_iter_count == 1;

  logic any_instr_captured;
  assign any_instr_captured = (num_allocated_rss_q != '0);

  // ---------------------------
  // Finish detection
  // ---------------------------

  logic lcp_finished;
  logic lep_finished_issue, lep_finished;

  // TODO(colluca): rename this signal to what exactly the controller needs to know.
  // In LCP the loop controller knows when we are in the last loop iteration.
  // All it needs to know from the RS is if the FU has retired all instructions.
  // `fu_busy_i` is asserted also when the output of the FU is valid, but in this cycle
  // the instruction may already be retiring, so to not waste a cycle we separately
  // include this condition (result_hs).
  assign lcp_finished = !disp_req_valid_i && (!fu_busy_i && !disp_req_valid_i_q ||
                        ((disp_idx == result_idx) && result_hs));

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

  // TODO(colluca): make this an enum to clearly understand who's being selected in the waves
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
    .NofRss          (NofRss),
    .NofConstants    (NofConstants),
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
    .ext_res_req_t   (ext_res_req_t),
    .available_result_t   (available_result_t),
    .dest_mask_t     (dest_mask_t),
    .res_rsp_t       (res_rsp_t)
  ) i_res_stat_slots (
    .clk_i,
    .rst_i,
    .producer_id_i     (producer_id_i),
    .restart_i         (restart_i),
    .loop_state_i      (loop_state_i),
    .disp_idx_i        (disp_idx),
    .issue_idx_i       (issue_idx),
    .last_issue_iter_i (lep_issue_iter_count == 1),
    .last_result_iter_i(last_result_iter),
    .retire_at_issue_o (retire_at_issue),
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

  // This counts the number of dispatched instructions, which can be as many as NofRss.
  // The dispatch index on the other hand must point to a valid reservation station,
  // so it should trip when it reaches NofRss-1.
  trip_counter #(
    .WIDTH(NofRssWidthExt)
  ) i_disp_counter (
    .clk_i,
    .rst_ni  (!rst_i),
    .clear_i (goto_lcp2_i || restart_i),
    .en_i    (disp_hs),
    .delta_i (rss_cnt_t'(1)),
    .bound_i (rss_cnt_t'((loop_state_i == LoopLcp1) ? NofRss : (num_allocated_rss_q - 1))),
    .q_o     (disp_cnt),
    .last_o  (last_disp),
    .trip_o  ()
  );
  assign disp_idx = (disp_cnt == NofRss) ? '0 : disp_cnt;

  trip_counter #(
    .WIDTH(NofRssWidth)
  ) i_issue_counter (
    .clk_i,
    .rst_ni  (!rst_i),
    .clear_i (goto_lcp2_i || restart_i),
    .en_i    (issue_hs),
    .delta_i (rss_idx_t'(1)),
    .bound_i (rss_idx_t'((loop_state_i == LoopLcp1) ? (NofRss - 1) : (num_allocated_rss_q - 1))),
    .q_o     (issue_idx),
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
    .q_o     (result_idx),
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

  rss_cnt_t disp_in_flight_q, disp_in_flight_d;
  // TODO(colluca): the size of this counter depends solely on the FU's maximum number of
  //                outstanding instructions.
  //                We should feed this parameter from outside and also use it to test that
  //                issue_in_flight counter never exceeds this value.
  logic [31:0] issue_in_flight_q, issue_in_flight_d;

  `FFAR(disp_in_flight_q, disp_in_flight_d, '0, clk_i, rst_i)
  `FFAR(issue_in_flight_q, issue_in_flight_d, '0, clk_i, rst_i)

  always_comb begin
    disp_in_flight_d = disp_in_flight_q;
    issue_in_flight_d = issue_in_flight_q;

    if (disp_hs) begin
      disp_in_flight_d += 1;
    end
    if (issue_hs) begin
      disp_in_flight_d -= 1;
      issue_in_flight_d += 1;
    end
    if (retire_at_issue || result_hs) begin
      issue_in_flight_d -= (retire_at_issue + result_hs);
    end
  end

  `ASSERT(DispatchBeforeIssue, issue_hs |-> (disp_hs || (disp_in_flight_q >= 1)), clk_i, rst_i)
  `ASSERT(MaxDispatchIssueDistanceOne, disp_hs |-> (issue_hs || (disp_in_flight_q < 1)), clk_i, rst_i)
  `ASSERT(RetireAtIssueImpliesIssue, retire_at_issue |-> issue_hs, clk_i, rst_i)
  `ASSERT(IssueBeforeResult, result_hs |-> (issue_hs || (issue_in_flight_q >= 1)), clk_i, rst_i)

endmodule