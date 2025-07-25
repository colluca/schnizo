// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: The Reservation station slot. It contains the actual instruction buffer logic.

// Abbreviations:
// FU:  Functional Unit. This is for example an ALU, FPU or LSU.
// RS:  Reservation Station. Holds multiple RSS for a single FU and controls the execution.
// RSS: Reservation Station Slot. A slot can hold one instruction with all the required
//      information for the superscalar execution.

`include "common_cells/registers.svh"

module schnizo_res_stat_slot import schnizo_pkg::*; #(
  parameter int unsigned NofOperands    = 2,
  parameter int unsigned ConsumerCount  = 16,
  parameter int unsigned NofResReqs     = 4,
  // The bits to address all registers
  parameter int unsigned RegAddrWidth  = 5,
  parameter type         disp_req_t     = logic,
  parameter type         producer_id_t  = logic,
  parameter type         operand_id_t   = logic,
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

  // If restart is asserted, we initialize the slot. THERE MAY NOT BE ANY instruction in flight!
  input  logic         restart_i,
  // Asserted for last LEP dispatch iteration to end the operand fetching.
  input  logic         is_last_disp_iter_i,
  // Asserted for last LEP result iteration to perform the possible writeback (based on result iteration).
  input  logic         is_last_result_iter_i,
  // ID of RSS to place operand requests. This ID must be static.
  input  producer_id_t own_producer_id_i,
  // ID of operand 0. Operand 1,.. are consecutive.
  input  operand_id_t  op_start_id_i,
  // The current result iteration state
  output logic         res_iter_o,
  // Asserted in the cycle the instruction retires.
  output logic         retired_o,

  // Dispatch interface
  input  disp_req_t disp_req_i,
  input  logic      disp_req_valid_i,
  output logic      disp_req_ready_o,

  // Operand request interface - outgoing - request a result as operand
  output operand_req_t [NofOperands-1:0] op_reqs_o,
  output logic         [NofOperands-1:0] op_reqs_valid_o,
  input  logic         [NofOperands-1:0] op_reqs_ready_i,

  // Result request interface - incoming - translated operand request
  input  dest_mask_t res_req_i,
  input  logic       res_req_valid_i,
  output logic       res_req_ready_o,

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
  output result_t     rf_wb_result_o,
  output result_tag_t rf_wb_tag_o,
  output logic        rf_wb_valid_o,
  input  logic        rf_wb_ready_i
);
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

  typedef struct packed  {
    // Whether the RSS contains an active instruction.
    logic                           is_occupied;
    // How many consumer use the result of this instruction.
    logic [ConsumerCountWidth-1:0]  consumer_count;
    // A counter to keep track how many times the current result has been captured.
    logic [ConsumerCountWidth-1:0]  consumed_by;
    // If the instruction has been issued in LCP1, the flag is set and all notifications targeting
    // this RSS are captured. When the instruction is issued for the 2nd time in LCP2, the flag is
    // reset.
    logic                           do_capture_consumers;
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
    rss_operand_t [NofOperands-1:0] operands;
  } rs_slot_t;

  typedef enum logic[2:0] {
    Lcp1Init,
    Lcp1Fetch,
    WaitForLcp1Result,
    Lcp2Init,
    Lcp2Fetch,
    WaitForLcp2Result,
    Lep,
    LepFinished
  } rss_state_e;

  rs_slot_t slot_lcp1;
  rs_slot_t slot_reset_state;
  rs_slot_t slot_q, slot_d;
  `FFAR(slot_q, slot_d, slot_reset_state, clk_i, rst_i);

  rss_state_e state_q, state_d;
  `FFAR(state_q, state_d, Lcp1Init, clk_i, rst_i);

  dest_mask_t current_dest_mask;
  logic       current_dest_mask_valid;
  logic       current_dest_mask_ready;

  logic [NofOperands-1:0] op_valid;
  logic                   enable_op_request;
  logic                   enforce_valid_reset;
  logic                   enforce_rf_writeback;
  logic                   enable_capture_consumers;
  logic                   all_ops_valid;
  logic                   result_consumed;
  logic                   issued;
  logic                   retired;
  logic                   do_rf_writeback;
  logic [1:0]             wb_sel;
  logic                   rss_wb_valid;
  logic                   rss_wb_ready;

  always_comb begin : rss_state
    state_d = state_q;

    enable_op_request        = 1'b0;
    enforce_rf_writeback     = 1'b0;
    // Set the capture consumer flag when we captured the result of LCP1.
    // Reset it when we captured the result of LCP2.
    enable_capture_consumers = 1'b0;

    unique case(state_q)
      Lcp1Init: begin
        if (disp_req_valid_i) begin
          enable_op_request    = 1'b1;
          enforce_rf_writeback = 1'b1;
          state_d              = Lcp1Fetch;
          if (issued) begin
            state_d = WaitForLcp1Result;
          end
          if (retired) begin
            state_d = Lcp2Init;
            enable_capture_consumers = 1'b1;
          end
        end
      end
      Lcp1Fetch: begin
        enable_op_request    = 1'b1;
        enforce_rf_writeback = 1'b1;
        if (issued) begin
          state_d = WaitForLcp1Result;
        end
        if (retired) begin
          state_d = Lcp2Init;
          enable_capture_consumers = 1'b1;
        end
      end
      WaitForLcp1Result: begin
        enforce_rf_writeback = 1'b1;
        if (retired) begin
          state_d = Lcp2Init;
          enable_capture_consumers = 1'b1;
        end
      end
      Lcp2Init: begin
        // Enforce the writeback for the multicycle LCP1 result. Otherwise the result is lost.
        enforce_rf_writeback = 1'b1;
        // Disable fetching because there could be a new producer for LCP2
        // Still capture consumers until we receive the LCP2 result
        enable_capture_consumers = 1'b1;
        if (disp_req_valid_i) begin
          state_d              = Lcp2Fetch;
          enable_op_request    = 1'b1;
          if (issued) begin
            state_d = WaitForLcp2Result;
          end
          if (retired) begin
            enable_capture_consumers = 1'b0;
            state_d = Lep;
          end
        end
      end
      Lcp2Fetch: begin
        enable_op_request    = 1'b1;
        enforce_rf_writeback = 1'b1; // enabled for LCP1 and LCP2 result
        // Still capture consumers until we receive the LCP2 result
        enable_capture_consumers = 1'b1;
        if (issued) begin
          state_d = WaitForLcp2Result;
        end
        if (retired) begin
          enable_capture_consumers = 1'b0;
          state_d = Lep;
        end
      end
      WaitForLcp2Result: begin
        // we must keep the enforce rf writeback enabled until the result of LCP2 returns.
        enable_op_request    = 1'b1;
        enforce_rf_writeback = 1'b1; // enabled for LCP1 and LCP2 result
        // Still capture consumers until we receive the LCP2 result
        enable_capture_consumers = 1'b1;
        if (retired) begin
          state_d = Lep;
          enable_capture_consumers = 1'b0;
        end
      end
      Lep: begin
        // Wait here. We can fetch everything.
        enable_op_request = 1'b1;
        if (is_last_disp_iter_i && issued) begin
          state_d = LepFinished;
        end
      end
      LepFinished: begin
        // Do not request operands which will never be produced. This leads to deadlocks.
        enable_op_request = 1'b0;
        // We will only exit LEP when restarting.
      end
      default: ; // use default of above
    endcase

    // Initialization of the slot has highest prio
    if (restart_i) begin
      state_d              = Lcp1Init;
      enable_op_request    = 1'b0;
      enforce_rf_writeback = 1'b0;
    end
  end

  // ---------------------------
  // Slot FF Update
  // ---------------------------
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

  // ---------------------------
  // Slot Selection
  // ---------------------------
  rs_slot_t selected_slot;
  rs_slot_t slot_lcp2;
  always_comb begin : slot_selection
    // Update the slot depending on the state.
    selected_slot = slot_q;
    unique case(state_q)
      Lcp1Init: begin
        if (disp_req_valid_i) begin
          selected_slot = slot_lcp1; // Load the new instruction
        end
      end
      Lcp2Init: begin
        if (disp_req_valid_i) begin
          // Update producers if there is not yet one set.
          selected_slot = slot_lcp2;
        end
      end
      Lcp1Fetch,
      Lcp2Fetch,
      WaitForLcp2Result,
      Lep,
      LepFinished: ; // Regular update
      default: ; // TODO: Crash?
    endcase

    // Slot initialization has highest priority
    if (restart_i) begin
      selected_slot = slot_reset_state;
    end
  end

  // ---------------------------
  // Operand handling
  // ---------------------------
  rs_slot_t slot_op;
  always_comb begin : slot_operand_handling
    slot_op = selected_slot;
    for (int op = 0; op < NofOperands; op++) begin : gen_operand_req_op
      // Operand request generation
      op_reqs_o[op] = '{
        producer: slot_op.operands[op].producer,
        request: res_req_t'{
          // Invert the iteration flag if we desire the result from the previous loop iteration
          requested_iter: slot_op.operands[op].is_from_current_iter ?  slot_op.instruction_iter :
                                                                      ~slot_op.instruction_iter,
          consumer:       operand_id_t'(op_start_id_i + op)
        }
      };

      op_reqs_valid_o[op] = slot_op.operands[op].is_produced && !slot_op.operands[op].is_valid &&
                            !slot_op.operands[op].requested &&
                            slot_op.is_occupied && // Request the operand only if slot is active.
                            enable_op_request;

      // Capture request placement at handshake
      if (op_reqs_valid_o[op] && op_reqs_ready_i[op]) begin
        slot_op.operands[op].requested = 1'b1;
      end

      // Operand response handling
      // Handle the response after the request generation to allow same cycle responses.
      // We won't place two requests due to the requested flag.
      op_rsps_ready_o[op] = 1'b0;
      if (slot_op.is_occupied && slot_op.operands[op].is_produced && op_rsps_valid_i[op]) begin
        slot_op.operands[op].value     = op_rsps_i[op];
        slot_op.operands[op].is_valid  = 1'b1;
        slot_op.operands[op].requested = 1'b0;
        // Acknowledge the response
        op_rsps_ready_o[op] = 1'b1;
      end
    end
  end

  // ---------------------------
  // Issue instruction
  // ---------------------------
  rs_slot_t slot_issue;
  always_comb begin : slot_issue_update
    slot_issue = slot_op;

    disp_req_ready_o = 1'b0;
    // Issue the operation if all operands are valid. The FU exerts back-pressure if its pipeline
    // is full or the result cannot be written because the current result has not been consumed
    // by all consumers yet.
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
    issue_req_o.tag.dest_reg         = slot_issue.dest_id;
    issue_req_o.tag.dest_reg_is_fp   = slot_issue.dest_is_fp;
    issue_req_o.tag.is_branch        = 1'b0; // Not supported in FREP
    issue_req_o.tag.is_jump          = 1'b0; // Not supported in FREP

    for (int i = 0; i < NofOperands; i++) begin
      op_valid[i] = slot_issue.operands[i].is_valid;
    end
    all_ops_valid = &op_valid;

    issue_req_valid_o = 1'b0;
    if (all_ops_valid && slot_issue.is_occupied) begin
      issue_req_valid_o = disp_req_valid_i;
    end
    // Capture handshake
    issued = issue_req_valid_o && issue_req_ready_i;
    if (issued) begin
      // Toggle instruction state
      slot_issue.instruction_iter = ~slot_issue.instruction_iter;
      // Reset the operands' valid flags depending on loop phase and production state
      // In LCP1 we reset all valid flags
      // In LCP2 and LEP we only reset produced operands' valid flags
      enforce_valid_reset = 1'b0;
      unique case(state_q)
        Lcp1Init:  if (disp_req_valid_i) enforce_valid_reset = 1'b1;
        Lcp1Fetch: enforce_valid_reset = 1'b1;
        default: ;
      endcase

      for (int op = 0; op < NofOperands; op++) begin
        slot_issue.operands[op].is_valid =
          enforce_valid_reset                 ? 1'b0 :
          slot_issue.operands[op].is_produced ? 1'b0 :
                                                slot_issue.operands[op].is_valid;
      end

      // When we issue the instruction, the dispatch request is complete
      disp_req_ready_o = 1'b1;
    end
  end

  // ---------------------------
  // Capture Result and result request / response handling
  // ---------------------------
  rs_slot_t slot_wb;
  logic     enable_rf_writeback;
  always_comb begin : result_wb_request_response
    slot_wb = slot_issue;
    // ---------------------------
    // Handle result requests
    // ---------------------------
    // We feed forward the current request directly to the response handling. Here we could add a
    // queue or a timing cut.
    current_dest_mask       = res_req_i;
    current_dest_mask_valid = res_req_valid_i;
    current_dest_mask_ready = res_rsp_ready_i;
    res_req_ready_o         = current_dest_mask_ready;

    // ---------------------------
    // Generate result responses
    // ---------------------------
    // Always answer requests using the "old" result (from the previous cycle) as otherwise we
    // would create a loop. The loop comes from the connection back to the operand response
    // handling. The generated result response is sent back to the operand interface.
    res_rsp_o.dest_mask = current_dest_mask;
    res_rsp_o.operand   = slot_q.result.value;
    // We don't need to check the iteration here as it is already checked in the request crossbar.
    res_rsp_valid_o     = current_dest_mask_valid &&
                          slot_q.result.is_valid;

    // When we served a result request, update consumer counter
    if (res_rsp_valid_o && res_rsp_ready_i) begin
      // count the bits in the destination mask
      slot_wb.consumed_by = slot_wb.consumed_by + $countones(current_dest_mask);
      // During LCP there may be only one request at at time.. We still count all requests.
      if (slot_q.do_capture_consumers) begin
        slot_wb.consumer_count = slot_wb.consumer_count + $countones(current_dest_mask);
      end
    end

    // ---------------------------
    // Capture result
    // ---------------------------
    // Capture the result:
    // - If the current result is valid
    //   - Result must have been consumed by all consumers
    // - Always if the current result is invalid
    //
    // We must check also the RF writeback for LCP and last LEP.
    // This is handled with a special stream fork.
    rf_wb_result_o             = result_i;
    rf_wb_tag_o                = '0;
    rf_wb_tag_o.dest_reg       = slot_wb.dest_id;
    rf_wb_tag_o.dest_reg_is_fp = slot_wb.dest_is_fp;
    // Check if we want to write back to the RF. If so, enable the RF path for the dynamic stream
    // fork. A store has no writeback and the last result iteration is "immediately" reached.
    enable_rf_writeback = is_last_result_iter_i && !slot_wb.is_store;
    do_rf_writeback = (slot_wb.do_writeback && enable_rf_writeback) || enforce_rf_writeback;
    wb_sel          = {do_rf_writeback, 1'b1}; // always write back to RSS

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
    if (retired) begin
      slot_wb.result.is_valid  = 1'b1;
      slot_wb.result.iteration = ~slot_wb.result.iteration;
      // Don't update the result FFs for stores.
      // TODO: Does this MUX really save power (by not updating the FFs) or will it add too much
      //        logic?
      slot_wb.result.value     = slot_wb.is_store ? '0 : result_i;
      slot_wb.consumed_by      = '0;
    end
    // This signal is generated in the main FSM.
    slot_wb.do_capture_consumers = enable_capture_consumers;
  end

  // The slot FF update after all manipulations
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
  assign retired_o = slot_wb.is_store ? 1'b1 : retired;

  // Fork the request from the FU to the RSS and RF writeback. The RF writeback is only enabled if
  // we are in LCP or the last LEP iteration. We must ensure that these streams handshake at the
  // same time as otherwise the result is captured / written back before the instruction is issued.
  // This is a problem if the FU is single cycle. If the issue request is valid, the result is also
  // valid and distributed by the stream fork. Now if either the RSS or RF is ready, but the other
  // not, the result is "captured" but the issue request is still pending.
  // To keep the correct order, we must synchronize the two streams such that they handshake in the
  // same cycle.
  // Therefore, the RSS must signal whether it is ready to accept the result. Only then the request
  // may be forwarded to the RF. And the actual RSS handshake must be delayed until the RF
  // handshakes.
  //
  //    +-----------+                               +-----------+
  // +--|    RSS    |                               |   RF WB   |
  // |  +-----------+                               +-----------+
  // |    ^       |                                   ^       |
  // |    |       o-----------------------+           |       |
  // |    | V     | R     +-- do_rf_wb    |           |       |
  // |    |       |       |               |   +---+   |       |
  // |    |       v       v               |   |   |<--o       |
  // |  +---+   +---+    /1|<-------------|---| & |   |       |
  // |  | & |---| & |<---| |              |   |   |<--|-------o
  // |  +---+   +---+    \0|<-- 1'b1      |   +---+   |       |
  // |    ^       |                       |           | V     | R
  // |    |       |                       |           |       v
  // |    | V     | R                     |         +---+   +---+
  // |    | raw   | raw                   +-------->| & |---| & |
  // |    |       |                                 +---+   +---+
  // |    |       |                                   ^       |
  // |    |       |                                   | V raw | R raw
  // |    |       +--------------------+    +---------+       |
  // |    +-----------------------+    |    |    +------------+
  // |                            |    |    |    |
  // |                            |    v    |    v
  // |     +----+               +------------------+
  // +---->| FU |-------------->|   Stream Fork    |
  //       +----+               +------------------+
  //

  logic rf_wb_valid_raw;
  logic rf_wb_ready_raw;
  logic rss_wb_valid_raw;
  logic rss_wb_ready_raw;
  logic rss_wb_enable;

  assign rss_wb_enable = do_rf_writeback ? (rf_wb_valid_o & rf_wb_ready_i) : 1'b1;

  assign rf_wb_ready_raw = rf_wb_ready_i & rss_wb_ready;
  assign rf_wb_valid_o = rf_wb_valid_raw & rss_wb_ready;

  assign rss_wb_valid = rss_wb_valid_raw & rss_wb_enable;
  assign rss_wb_ready_raw = rss_wb_ready & rss_wb_enable;

  stream_fork_dynamic #(
    .N_OUP(32'd2)
  ) i_result_fork (
    .clk_i,
    .rst_ni     (~rst_i),
    .valid_i    (result_valid_i),
    .ready_o    (result_ready_o),
    .sel_i      (wb_sel),
    .sel_valid_i(1'b1),
    .sel_ready_o(),
    .valid_o    ({rf_wb_valid_raw, rss_wb_valid_raw}),
    .ready_i    ({rf_wb_ready_raw, rss_wb_ready_raw})
  );

  // The default slot values when accepting a new instruction.
  rss_operand_t [2:0] ops_lcp1;
  rss_operand_t op_a_lcp1;
  rss_operand_t op_b_lcp1;
  rss_operand_t op_c_lcp1;

  // arrays for loop assignments
  assign ops_lcp1[0] = op_a_lcp1;
  assign ops_lcp1[1] = op_b_lcp1;
  assign ops_lcp1[2] = op_c_lcp1;

  assign op_a_lcp1 = '{
    producer:             disp_req_i.producer_op_a.producer,
    is_produced:          disp_req_i.producer_op_a.is_produced,
    is_from_current_iter: disp_req_i.producer_op_a.is_produced,
    value:                disp_req_i.producer_op_a.is_produced ?
                            '0 : disp_req_i.fu_data.operand_a,
    is_valid:             !disp_req_i.producer_op_a.is_produced,
    requested:            1'b0
  };

  assign op_b_lcp1 = '{
    producer:             disp_req_i.producer_op_b.producer,
    is_produced:          disp_req_i.producer_op_b.is_produced,
    is_from_current_iter: disp_req_i.producer_op_b.is_produced,
    value:                disp_req_i.producer_op_b.is_produced ?
                            '0 : disp_req_i.fu_data.operand_b,
    is_valid:             !disp_req_i.producer_op_b.is_produced,
    requested:            1'b0
  };

  assign op_c_lcp1 = '{
    producer:             disp_req_i.producer_op_c.producer,
    is_produced:          disp_req_i.producer_op_c.is_produced,
    is_from_current_iter: disp_req_i.producer_op_c.is_produced,
    value:                disp_req_i.producer_op_c.is_produced ?
                            '0 : disp_req_i.fu_data.imm,
    is_valid:             !disp_req_i.producer_op_c.is_produced,
    requested:            1'b0
  };

  always_comb begin
    slot_lcp1 = '{
      is_occupied:          1'b1,
      consumer_count:       '0,
      consumed_by:          '0,
      do_capture_consumers: 1'b0,
      alu_op:               disp_req_i.fu_data.alu_op,
      lsu_op:               disp_req_i.fu_data.lsu_op,
      fpu_op:               disp_req_i.fu_data.fpu_op,
      // Duplicate logic for is_store. Once in LSU and once here.
      // TODO: Optimize by passing this to the LSU instead of regenerating it inside the LSU?
      is_store:             (disp_req_i.fu_data.fu == STORE) &&
                            (disp_req_i.fu_data.fpu_op inside {LsuOpStore, LsuOpFpStore}),
      lsu_size:             disp_req_i.fu_data.lsu_size,
      fpu_fmt_src:          disp_req_i.fu_data.fpu_fmt_src,
      fpu_fmt_dst:          disp_req_i.fu_data.fpu_fmt_dst,
      fpu_rnd_mode:         disp_req_i.fu_data.fpu_rnd_mode,
      // We must set the result iteration flag to 1. It gets toggled when writing the first result.
      result:               rss_result_t '{
        value:     '0,
        is_valid:  1'b0,
        iteration: 1'b1
      },
      instruction_iter:     1'b0,
      dest_id:              disp_req_i.tag.dest_reg,
      dest_is_fp:           disp_req_i.tag.dest_reg_is_fp,
      do_writeback:         1'b0,
      operands:             '0
    };

    // Operands must be assigned depending on the number we have
    for (int op = 0; op < NofOperands; op++) begin
      slot_lcp1.operands[op] = ops_lcp1[op];
    end
  end

  always_comb begin
    slot_lcp2 = slot_q;

    // Update producers if there is not yet one set.
    if (!slot_lcp2.operands[0].is_produced) begin
      slot_lcp2.operands[0].producer    = disp_req_i.producer_op_a.producer;
      slot_lcp2.operands[0].is_produced = disp_req_i.producer_op_a.is_produced;
      slot_lcp2.operands[0].is_valid    = !disp_req_i.producer_op_a.is_produced;
      slot_lcp2.operands[0].value       = disp_req_i.fu_data.operand_a;
    end
    if (!slot_lcp2.operands[1].is_produced) begin
      slot_lcp2.operands[1].producer    = disp_req_i.producer_op_b.producer;
      slot_lcp2.operands[1].is_produced = disp_req_i.producer_op_b.is_produced;
      slot_lcp2.operands[1].is_valid    = !disp_req_i.producer_op_b.is_produced;
      slot_lcp2.operands[1].value       = disp_req_i.fu_data.operand_b;
    end
    if (NofOperands >= 3) begin
      if (!slot_lcp2.operands[2].is_produced) begin
        slot_lcp2.operands[2].producer    = disp_req_i.producer_op_c.producer;
        slot_lcp2.operands[2].is_produced = disp_req_i.producer_op_c.is_produced;
        slot_lcp2.operands[2].is_valid    = !disp_req_i.producer_op_c.is_produced;
        slot_lcp2.operands[2].value       = disp_req_i.fu_data.imm;
      end
    end
    // Set the writeback flag if we are the last RSS writing to this destination
    if ((own_producer_id_i == disp_req_i.current_producer_dest.producer) &&
        disp_req_i.current_producer_dest.is_produced) begin
      slot_lcp2.do_writeback = 1'b1;
    end
  end

  assign slot_reset_state = '{
    is_occupied:          1'b0, // suppresses operand requests
    consumer_count:       '0,
    consumed_by:          '0,
    do_capture_consumers: 1'b0,
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

endmodule
