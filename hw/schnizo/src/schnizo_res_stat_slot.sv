// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// The Reservation station slot. It contains the actual instruction buffer logic.
//
// Abbreviations:
// FU:  Functional Unit. This is for example an ALU, FPU or LSU.
// RS:  Reservation Station. Holds multiple RSS for a single FU and controls the execution.
// RSS: Reservation Station Slot. A slot can hold one instruction with all the required
//      information for the superscalar execution.
module schnizo_res_stat_slot import schnizo_pkg::*; #(
  parameter int unsigned NofOperands    = 2,
  parameter int unsigned ConsumerCount  = 16,
  // The bits to address all registers
  parameter int unsigned RegAddrWidth   = 5,
  parameter type         rss_idx_t      = logic,
  parameter type         disp_req_t     = logic,
  parameter type         producer_id_t  = logic,
  parameter type         operand_req_t  = logic,
  parameter type         operand_t      = logic,
  parameter type         res_req_t      = logic,
  parameter type         dest_mask_t    = logic,
  parameter type         res_rsp_t      = logic,
  parameter type         issue_req_t    = logic,
  parameter type         result_t       = logic,
  parameter type         result_tag_t   = logic
) (
  input  logic clk_i,
  input  logic rst_i,

  // Index of this slot in the reservation station.
  input  rss_idx_t     slot_id_i,
  // If restart is asserted, we initialize the slot. THERE MAY NOT BE ANY instruction in flight!
  input  logic         restart_i,
  // Asserted for last LEP dispatch iteration to end the operand fetching.
  input  logic         is_last_disp_iter_i,
  // Asserted for last LEP result iteration to perform the possible writeback (based on result iteration).
  input  logic         is_last_result_iter_i,
  // ID of RSS to place operand requests. This ID must be static.
  input  producer_id_t own_producer_id_i,
  // The current result iteration state
  output logic         res_iter_o,
  // Asserted in the cycle the instruction retires.
  output logic         retired_o,
  input  loop_state_e  loop_state_i,

  // Dispatch interface
  input  disp_req_t disp_req_i,
  input  logic      disp_req_valid_i,
  output logic      disp_req_ready_o,

  // Operand request interface - outgoing - request a result as operand
  output operand_req_t [NofOperands-1:0] op_reqs_o,
  output logic         [NofOperands-1:0] op_reqs_valid_o,
  input  logic         [NofOperands-1:0] op_reqs_ready_i,

  // Result request interface - incoming - translated operand request
  // Result requests are converted to destination masks (where to send the result to) at RS level.
  input  dest_mask_t dest_mask_i,
  input  logic       dest_mask_valid_i,
  output logic       dest_mask_ready_o,

  // Result response interface - outgoing - result as operand response
  output res_rsp_t res_rsp_o,
  output logic     res_rsp_valid_o,
  input  logic     res_rsp_ready_i,

  // Operand response interface - incoming - returning result as operand
  input  operand_t [NofOperands-1:0] op_rsps_i,
  input  logic     [NofOperands-1:0] op_rsps_valid_i,
  output logic     [NofOperands-1:0] op_rsps_ready_o,

  // Issue interface
  output issue_req_t issue_req_o,
  output logic       issue_req_valid_o,
  input  logic       issue_req_ready_i,

  // FU result interface
  input  result_t result_i,
  input  logic    result_valid_i,
  output logic    result_ready_o,

  // RF writeback interface
  output result_tag_t rf_wb_tag_o,
  output logic        rf_do_writeback_o
);

  /////////////////////////////////////
  // Parameters and type definitions //
  /////////////////////////////////////

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
  typedef struct packed  {
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

  logic [NofOperands-1:0] op_valid;
  logic                   all_ops_valid;
  logic                   result_consumed;
  logic                   issued;
  logic                   retired;
  logic                   do_rf_writeback;
  logic                   rss_wb_valid;
  logic                   rss_wb_ready;

  //////////
  // Slot //
  //////////

  rs_slot_t slot_reset_state;
  rs_slot_t slot_q, slot_d;

  `FFAR(slot_q, slot_d, slot_reset_state, clk_i, rst_i);

  assign slot_reset_state = '{
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

  //////////////////
  // State update //
  //////////////////

  logic enable_capture_consumers_q, enable_capture_consumers_d;
  `FFAR(enable_capture_consumers_q, enable_capture_consumers_d, 1'b0, clk_i, rst_i);

  // We have to start capturing the consumer count after we got the result from
  // LCP1. We stop capturing the consumer count once we got the result from LCP2.
  // TODO(colluca): effectively the info we are tracking here is the loop state, at the result
  // side rather than the issue side. We have to capture consumers (increment consumer count)
  // only while we have a result produced in LCP1.
  always_comb begin
    enable_capture_consumers_d = enable_capture_consumers_q;

    // set after LCP1 result
    if (!enable_capture_consumers_q &&
        retired &&
        (loop_state_i == LoopLcp1)) begin
      enable_capture_consumers_d = 1'b1;
    end

    // clear after LCP2 result
    if (enable_capture_consumers_q && retired) begin
      enable_capture_consumers_d = 1'b0;
    end

    // Initialization of the slot has highest prio
    if (restart_i) begin
      enable_capture_consumers_d = 1'b0;
    end
  end

  /////////////////
  // Slot Update //
  /////////////////

  // The slot FF is updated in multiple steps depending on the current slot state.
  // The update logic dependencies are shown below.
  // The operand requests pass via the Operand Distribution Network (ODN).
  //
  //                                                              Result req / rsp can be in same or other RSS
  //             +-----------------+    +-------------------+                      +-----------------------+
  // Disp req -->| Slot selection  |--->| OP req generation |--------------------->| Result req handling   |
  //             +-----------------+    +-------------------+       via ODN        +-----------------------+
  //                  ^       ^                   |                                            | here we could add a queue / timing cut
  //                  |       |                   v                                            v
  // LxP state -------+       |         +-------------------+                      +-----------------------+
  //                          |         | Op rsp handling   |<---------------------| Result rsp generation |
  //         +----------------+         +-------------------+       via ODN        +-----------------------+
  //         |                                    |                                       |        ^
  //         |                                    v                                       |        |
  //         |                          +-------------------+                             |        |
  //         |            +-------------| Issue             |                             |        |
  //         |            |             +-------------------+                             |        |
  //         |            |                       |                                       |        |
  //         |   +-----------------+              v                                       |        |
  //         |   | Functional Unit |              o<--------------------------------------+        |
  //         |   +-----------------+              |  Merge the updates                             |
  //         |            |                       v                                                |
  //         |            |             +-------------------+                                      |
  //         |            +------------>| Result capture    |                                      |
  //         |                          +-------------------+                                      |
  //         |                                    |                                                |
  //         |                                    v                                                |
  //         |                          +-------------------+                                      |
  //         |                          |> Slot FF          |                                      |
  //         |                          +-------------------+                                      |
  //         |                                    |                                                |
  //         +------------------------------------+------------------------------------------------+

  ////////////////////
  // Slot selection //
  ////////////////////

  // Initial state-dependent slot update
  rs_slot_t selected_slot;

  schnizo_res_stat_slot_initial_update #(
    .NofOperands   (NofOperands),
    .disp_req_t    (disp_req_t),
    .producer_id_t (producer_id_t),
    .rs_slot_t     (rs_slot_t),
    .rss_operand_t (rss_operand_t),
    .rss_result_t  (rss_result_t)
  ) i_initial_update (
    .restart_i          (restart_i),
    .own_producer_id_i  (own_producer_id_i),
    .loop_state_i       (loop_state_i),
    .disp_req_i         (disp_req_i),
    .disp_req_valid_i   (disp_req_valid_i),
    .slot_i             (slot_q),
    .slot_reset_state_i (slot_reset_state),
    .slot_o             (selected_slot)
  );

  //////////////////////
  // Operand handling //
  //////////////////////

  rs_slot_t slot_op;
  rs_slot_t slot_op_rsp;

  // Sends operand requests and accepts responses based on the state of the slot after the
  // slot selection stage.
  // Also updates the slot after requesting operands (operands[i].requested field) and after
  // receiving responses (operands[i].{value,is_valid,requested} fields).

  // We only have to send a request and update the slot for the slot that is currently
  // being dispatched/issued.
  schnizo_op_req_handler #(
    .NofOperands(NofOperands),
    .rs_slot_t(rs_slot_t),
    .operand_req_t(operand_req_t),
    .res_req_t(res_req_t)
  ) i_op_req_handler (
    // Slot data before sending the operand request
    .slot_i(selected_slot),
    // Slot data after sending the operand request
    .slot_o(slot_op),
    // Dispatch interface
    .disp_req_valid_i(disp_req_valid_i),
     // Operand request interface - outgoing - request a result as operand
    .op_reqs_o(op_reqs_o),
    .op_reqs_valid_o(op_reqs_valid_o),
    .op_reqs_ready_i(op_reqs_ready_i)
  );

  // This also only happens for one slot at a time, however it may not be the slot that we currently dispatch/issue
  // so this has to be replicated for every slot.
  schnizo_op_rsp_handler #(
    .NofOperands(NofOperands),
    .rs_slot_t(rs_slot_t),
    .operand_t(operand_t)
  ) i_op_rsp_handler (
    // Slot data after sending operand request
    .slot_i(slot_op),
    // Slot data after handling responses
    .slot_o(slot_op_rsp),
    // Operand response interface - incoming - returning result as operand
    .op_rsps_i(op_rsps_i),
    .op_rsps_valid_i(op_rsps_valid_i),
    .op_rsps_ready_o(op_rsps_ready_o)
  );

  ///////////////////////
  // Issue instruction //
  ///////////////////////

  // Issues an instruction if all operands have been received, based on the state of the slot
  // after the operand request stage.
  // Also updates the slot after issuing the instruction (instruction_iter and
  // operands[i].is_valid fields).

  // TODO(colluca): break this into separate blocks. 1) Issue request generation
  // driving issue_req_o and issue_req_valid_o based on slot_op_rsp. 2) slot update
  // depending on slot_op_rsp, issued, etc.
  rs_slot_t slot_issue;
  always_comb begin : slot_issue_update
    slot_issue = slot_op_rsp;

    disp_req_ready_o = 1'b0;
    // Issue the operation if all operands are valid. The FU exerts backpressure if its pipeline
    // is full or the result cannot be written because the current result has not been consumed
    // by all consumers yet.
    // Tag used for the operation is the slot_id, to identify the result destination in case
    // results can come back OoO from the FU (as is the case for the FPU).
    issue_req_o                      = '0;
    issue_req_o.fu_data.fu           = NONE; // Not required by FU
    issue_req_o.fu_data.alu_op       = slot_issue.alu_op;
    issue_req_o.fu_data.lsu_op       = slot_issue.lsu_op;
    issue_req_o.fu_data.csr_op       = CsrOpNone; // Not supported in FREP
    issue_req_o.fu_data.fpu_op       = slot_issue.fpu_op;
    issue_req_o.fu_data.operand_a    = slot_issue.operands[0].value;
    issue_req_o.fu_data.operand_b    = slot_issue.operands[1].value;
    issue_req_o.fu_data.imm          = (NofOperands >= 3) ? slot_issue.operands[2].value : '0;
    issue_req_o.fu_data.lsu_size     = slot_issue.lsu_size;
    issue_req_o.fu_data.fpu_fmt_src  = slot_issue.fpu_fmt_src;
    issue_req_o.fu_data.fpu_fmt_dst  = slot_issue.fpu_fmt_dst;
    issue_req_o.fu_data.fpu_rnd_mode = slot_issue.fpu_rnd_mode;
    issue_req_o.tag                  = slot_id_i;

    for (int i = 0; i < NofOperands; i++) begin
      op_valid[i] = slot_issue.operands[i].is_valid;
    end
    all_ops_valid = &op_valid;

    issue_req_valid_o = 1'b0;
    if (all_ops_valid && slot_issue.is_occupied) begin
      // TODO(colluca): can we not just have 1'b1 here? Then we could probably remove
      // the weird dispatch mux in the res_stat
      issue_req_valid_o = disp_req_valid_i;
    end
    // Capture handshake
    issued = issue_req_valid_o && issue_req_ready_i;
    if (issued) begin
      // Toggle instruction state
      slot_issue.instruction_iter = ~slot_issue.instruction_iter;
      // INFO(soderma): We don't have to manually reset the valid signals in LCP1
      // this valid bit is completely overwritten in LCP2 anyway.
      // Reset the operands' valid flags depending on loop phase and production state
      // We have to reset it when it is produced. Since a new value has to be captured
      // in the next iteration.
      for (int op = 0; op < NofOperands; op++) begin
        slot_issue.operands[op].is_valid =  slot_issue.operands[op].is_produced ? 1'b0 :
                                            slot_issue.operands[op].is_valid;
      end

      // When we issue the instruction, the dispatch request is complete
      disp_req_ready_o = 1'b1;
    end
  end

  ////////////////////////////////
  // Result response generation //
  ////////////////////////////////

  // Always answer requests using the "old" result (before result capture) as otherwise we
  // would create a loop. The loop comes from the connection back to the operand response
  // handling. The generated result response is sent back to the operand interface.
  assign res_rsp_o.dest_mask = dest_mask_i;
  assign res_rsp_o.operand   = slot_q.result.value;
  // We don't need to check the iteration here as it is already checked in the request crossbar.
  assign res_rsp_valid_o     = dest_mask_valid_i &&
                        slot_q.result.is_valid;
  assign dest_mask_ready_o   = res_rsp_ready_i;

  logic [cf_math_pkg::idx_width($bits(dest_mask_i)+1)-1:0] num_current_consumers;
  popcount #(
    .INPUT_WIDTH($bits(dest_mask_i))
  ) i_consumer_popcount (
      .data_i(dest_mask_i),
      .popcount_o(num_current_consumers)
  );

  instr_tag_t rf_wb_tag;
  rs_slot_t slot_wb;
  logic     enable_rf_writeback;
  always_comb begin : result_wb_request_response
    // TODO(colluca): break this block into separate blocks. 1) slot update after result response.
    // 2) capture result. 3) slot update after result capture.
    // 1) should be part of "Generate result responses" and 2) and 3) should be part of
    // a separate top-level block called "Result capture"

    //////////////////////////////////////////////////
    // Update slot after result response generation //
    //////////////////////////////////////////////////

    // TODO(colluca): replace $countones with popcount module.
    slot_wb = slot_issue;
    // When we served a result request, update consumer counter
    if (res_rsp_valid_o && res_rsp_ready_i) begin
      // count the bits in the destination mask
      slot_wb.consumed_by = slot_wb.consumed_by + num_current_consumers;
      // During LCP there may be only one request at at time.. We still count all requests.
      if (enable_capture_consumers_q) begin
        slot_wb.consumer_count = slot_wb.consumer_count + num_current_consumers;
      end
    end

    ////////////////////
    // Result capture //
    ////////////////////

    // Capture the result:
    // - Always if the current result is invalid
    // - If the current result is valid, result must have been consumed by all consumers
    //
    // We must check also the RF writeback for LCP and last LEP.
    // This is handled with a special stream fork.

    // Compose tag
    rf_wb_tag = '0;
    rf_wb_tag.dest_reg       = slot_wb.dest_id;
    rf_wb_tag.dest_reg_is_fp = slot_wb.dest_is_fp;
    // TODO(colluca): find proper solution for this
    // HACK:
    // We directly pass through the branch and jump details to support jumps in LCP1
    // (where we will fall back into regular HW loop mode). This is possible as the ALU is
    // single cycle and the dispatch request is valid until we write back.
    rf_wb_tag.is_branch = disp_req_i.tag.is_branch;
    rf_wb_tag.is_jump   = disp_req_i.tag.is_jump;

    // Check if we want to write back to the RF. If so, enable the RF path for the dynamic stream
    // fork. A store has no writeback and the last result iteration is "immediately" reached.
    enable_rf_writeback = is_last_result_iter_i && !slot_wb.is_store;
    do_rf_writeback = (loop_state_i == LoopLep) ? (slot_wb.do_writeback && enable_rf_writeback) : 1'b1;

    // The result is consumed when all consumers read the result once
    result_consumed = (slot_wb.consumed_by == slot_wb.consumer_count) &&
                      (slot_wb.consumer_count != '0);

    rss_wb_ready = 1'b0;
    // The ready may not be dependent on the valid. See below for more details of the handshake.
    if ((result_consumed || !slot_wb.result.is_valid || slot_wb.consumer_count == '0) &&
        slot_wb.is_occupied) begin
      rss_wb_ready = 1'b1;
    end

    // We captured a new result when the stream fork signals the handshake to the FU.
    // This includes both cases (only RSS as well as RSS and RF).
    // A store instruction has no result. Thus we capture a dummy result at the same time
    // we issue the store instruction.
    retired = slot_wb.is_store ? issued : (result_valid_i && result_ready_o);

    //////////////////////////////////////
    // Slot update after result capture //
    //////////////////////////////////////

    if (retired) begin
      slot_wb.result.is_valid  = 1'b1;
      slot_wb.result.iteration = !slot_wb.result.iteration;
      // Don't update the result FFs for stores.
      // TODO: Does this MUX really save power (by not updating the FFs) or will it add too much
      //       logic?
      // TODO(colluca): to save power we would want to avoid that it switches at all, i.e.
      // keep the value in slot_q, not '0.
      slot_wb.result.value     = slot_wb.is_store ? '0 : result_i;
      slot_wb.consumed_by      = '0;
    end
  end

  // Update the slot after all manipulations
  assign slot_d = slot_wb;

  // The current result iteration state is directly passed to the output
  assign res_iter_o = slot_q.result.iteration;

  // Retired signal back to RS to step the result pointer.
  // For all instructions except stores, this retired signal is the same as used inside this RSS.
  // I.e., it is asserted in the cycle we retire the result / handshake it.
  // For stores this is different as stores have no result and thus retire immediately.
  // However, we must signal the retirement "in order" to the result pointer.
  // As loads and stores can be mixed, we could miss the retired signal for a store as it is only
  // asserted once in the cycle we issue it. But in this cycle the RS result pointer could be set
  // to an ongoing load. Thus we signal the retired signal always and as soon as the RS result
  // pointer steps to the store, it immediately "retires" the instruction.
  // TODO(colluca): does the RS really need a pointer? Or is a counter sufficient? In the latter
  // case we wouldn't need this differentiation and the RS would just set `retiring` to
  // |rss_retiring instead of rss_retiring[result_idx]. This would also be easier to extend if
  // we would at some point want to support multiple instructions retiring in the same cycle,
  // within the same RS, e.g. due to the presence of pipelines with different latencies.
  assign retired_o = slot_wb.is_store ? 1'b1 : retired;

  ///////////////
  // Writeback //
  ///////////////

  assign rss_wb_valid = result_valid_i;
  assign result_ready_o = rss_wb_ready;
  assign rf_do_writeback_o = do_rf_writeback;
  assign rf_wb_tag_o = rf_wb_tag;

endmodule
