// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"

// Combines initial slot update, operand request generation, operand response handling,
// and issue logic into a single module.
module schnizo_rss_dispatch_pipeline import schnizo_pkg::*; #(
  parameter int unsigned NofOperands      = 2,
  parameter type         disp_req_t       = logic,
  parameter type         producer_id_t    = logic,
  parameter type         rs_slot_issue_t  = logic,
  parameter type         rs_slot_result_t = logic,
  parameter type         rss_operand_t    = logic,
  parameter type         rss_result_t     = logic,
  parameter type         operand_req_t    = logic,
  parameter type         res_req_t        = logic,
  parameter type         operand_t        = logic,
  parameter type         rss_idx_t        = logic,
  parameter type         issue_req_t      = logic
) (
  input  logic            clk_i,
  input  logic            rst_ni,

  // Control
  input  logic            restart_i,
  input  producer_id_t    disp_producer_id_i,
  input  producer_id_t    issue_producer_id_i,
  input  loop_state_e     loop_state_i,
  input  logic            last_issue_iter_i,
  output logic            retire_at_issue_o,
  
  // Issue slot interface
  input  rs_slot_issue_t  slot_issue_i,
  output rs_slot_issue_t  slot_issue_o,
  output logic            slot_issue_wen_o,
  
  // Result slot interface
  input  rs_slot_result_t slot_result_i,
  input  rs_slot_result_t slot_result_reset_val_i,
  output rs_slot_result_t slot_result_o,

  // Dispatch
  input  disp_req_t disp_req_i,
  input  logic      disp_req_valid_i,
  output logic      disp_req_ready_o,

  // Operand request
  output operand_req_t [NofOperands-1:0] op_reqs_o,
  output logic         [NofOperands-1:0] op_reqs_valid_o,
  input  logic         [NofOperands-1:0] op_reqs_ready_i,

  // Operand response
  input  operand_t [NofOperands-1:0] op_rsps_i,
  input  logic     [NofOperands-1:0] op_rsps_valid_i,
  output logic     [NofOperands-1:0] op_rsps_ready_o,

  // Issue
  output issue_req_t issue_req_o,
  output logic       issue_req_valid_o,
  input  logic       issue_req_ready_i
);

  /////////////////////////
  // Initial slot update //
  /////////////////////////

  // This stage performs an initial state-dependent slot update.

  rs_slot_issue_t slot_issue_reset_val;
  assign slot_issue_reset_val = '{
    is_occupied:      1'b0, // suppresses operand requests
    alu_op:           AluOpAdd,
    lsu_op:           LsuOpLoad, // avoid store because the store flag has to be 0
    fpu_op:           FpuOpFadd,
    lsu_size:         Byte,
    fpu_fmt_src:      fpnew_pkg::FP32,
    fpu_fmt_dst:      fpnew_pkg::FP32,
    fpu_rnd_mode:     fpnew_pkg::RNE,
    instruction_iter: 1'b0,
    no_dest:          1'b0,
    operands:         '0 // invalid operands lead to no issue requests
  };

  // The initial operand values when accepting a new instruction
  rss_operand_t op_a_lcp1;
  rss_operand_t op_b_lcp1;
  rss_operand_t op_c_lcp1;

  assign op_a_lcp1 = '{
    producer:             disp_req_i.producer_op_a.producer,
    is_produced:          disp_req_i.producer_op_a.valid,
    is_from_current_iter: disp_req_i.producer_op_a.valid,
    value:                disp_req_i.fu_data.operand_a,
    is_valid:             !disp_req_i.producer_op_a.valid,
    requested:            1'b0
  };

  assign op_b_lcp1 = '{
    producer:             disp_req_i.producer_op_b.producer,
    is_produced:          disp_req_i.producer_op_b.valid,
    is_from_current_iter: disp_req_i.producer_op_b.valid,
    value:                disp_req_i.fu_data.operand_b,
    is_valid:             !disp_req_i.producer_op_b.valid,
    requested:            1'b0
  };

  assign op_c_lcp1 = '{
    producer:             disp_req_i.producer_op_c.producer,
    is_produced:          disp_req_i.producer_op_c.valid,
    is_from_current_iter: disp_req_i.producer_op_c.valid,
    value:                disp_req_i.fu_data.imm,
    is_valid:             !disp_req_i.producer_op_c.valid,
    requested:            1'b0
  };

  // Array to simplify initial operand assignment
  rss_operand_t [2:0] ops_lcp1;
  assign ops_lcp1[0] = op_a_lcp1;
  assign ops_lcp1[1] = op_b_lcp1;
  assign ops_lcp1[2] = op_c_lcp1;

  // Initial value of the slot upon accepting a new instruction
  rs_slot_issue_t slot_lcp1;
  always_comb begin
    slot_lcp1 = slot_issue_i;

    slot_lcp1 = '{
      is_occupied:      1'b1,
      alu_op:           disp_req_i.fu_data.alu_op,
      lsu_op:           disp_req_i.fu_data.lsu_op,
      fpu_op:           disp_req_i.fu_data.fpu_op,
      lsu_size:         disp_req_i.fu_data.lsu_size,
      fpu_fmt_src:      disp_req_i.fu_data.fpu_fmt_src,
      fpu_fmt_dst:      disp_req_i.fu_data.fpu_fmt_dst,
      fpu_rnd_mode:     disp_req_i.fu_data.fpu_rnd_mode,
      instruction_iter: 1'b0,
      no_dest:          (disp_req_i.fu_data.fu == STORE) &&
                        (disp_req_i.fu_data.fpu_op inside {LsuOpStore, LsuOpFpStore}),
      operands:         '0
    };

    // Operands must be assigned depending on the number we have
    for (int op = 0; op < NofOperands; op++) begin
      slot_lcp1.operands[op] = ops_lcp1[op];
    end
  end

  // Initial value of the slot upon accepting an instruction in LCP2.
  // Now all operand producers should be known, so we can update the missing producer information.
  rs_slot_issue_t slot_lcp2;
  always_comb begin
    slot_lcp2 = slot_issue_i;

    // Update producers if there is not yet one set.
    // TODO(colluca): could we also update the producer for operands which already
    // have a producer? Probably yes, then this would be an energy-saving optimization.
    // Test this so we can better document it.
    if (!slot_lcp2.operands[0].is_produced) begin
      slot_lcp2.operands[0].producer    = disp_req_i.producer_op_a.producer;
      slot_lcp2.operands[0].is_produced = disp_req_i.producer_op_a.valid;
      slot_lcp2.operands[0].is_valid    = !disp_req_i.producer_op_a.valid;
      slot_lcp2.operands[0].value       = disp_req_i.fu_data.operand_a;
    end
    if (!slot_lcp2.operands[1].is_produced) begin
      slot_lcp2.operands[1].producer    = disp_req_i.producer_op_b.producer;
      slot_lcp2.operands[1].is_produced = disp_req_i.producer_op_b.valid;
      slot_lcp2.operands[1].is_valid    = !disp_req_i.producer_op_b.valid;
      slot_lcp2.operands[1].value       = disp_req_i.fu_data.operand_b;
    end
    if (NofOperands >= 3) begin
      if (!slot_lcp2.operands[2].is_produced) begin
        slot_lcp2.operands[2].producer    = disp_req_i.producer_op_c.producer;
        slot_lcp2.operands[2].is_produced = disp_req_i.producer_op_c.valid;
        slot_lcp2.operands[2].is_valid    = !disp_req_i.producer_op_c.valid;
        slot_lcp2.operands[2].value       = disp_req_i.fu_data.imm;
      end
    end
  end

  // INFO(soderma):
  // We can use the regular state. The reason pascal probably did this is because of multi cycle updates.
  // so that you don't overwrite the dispatch request. But the dispatch request valid signal is only valid for one cycle anyway in LCP1 and LCP2
  // reason being is that all operands are ready and the instruction can be immediately issued.
  rs_slot_issue_t selected_slot;
  always_comb begin : slot_selection
    // Update the slot depending on the state.
    selected_slot = slot_issue_i;
    unique case (loop_state_i)
      LoopLcp1: begin
        if (disp_req_valid_i) begin
          selected_slot = slot_lcp1; // Load the new instruction
        end
      end
      LoopLcp2: begin
        if (disp_req_valid_i) begin
          // Update producers if there is not yet one set.
          selected_slot = slot_lcp2;
        end
      end
      default: ;
    endcase

    // Slot initialization has highest priority
    if (restart_i) begin
      selected_slot = slot_issue_reset_val;
    end
  end

  // Compute the updated result slot state depending on loop phase:
  // - LCP1: full initialization for a newly dispatched instruction.
  //         We must set the result iteration flag to 1 — it gets toggled when writing the first result.
  //         TODO(colluca): is this the right place for the no_dest logic? Perhaps move it to the decoder.
  // - LCP2: pass through the current result state, only updating `do_writeback` if needed.
  // This output is fed into res_req_handling as slot_i (instead of slot_result_qs) when dispatching,
  // so any concurrent consumer reads are applied on top of the dispatch update — no bypass needed.
  always_comb begin
    slot_result_o = slot_result_i;
    unique case (loop_state_i)
      LoopLcp1: begin
        slot_result_o = '{
          consumer_count: '0,
          consumed_by:    '0,
          result:         rss_result_t'{ value: '0, is_valid: 1'b0, iteration: 1'b1 },
          // TODO(colluca): can't we just use dest x0 to communicate this info?
          no_dest:        (disp_req_i.fu_data.fu == STORE) &&
                          (disp_req_i.fu_data.fpu_op inside {LsuOpStore, LsuOpFpStore}),
          dest_id:        disp_req_i.tag.dest_reg,
          dest_is_fp:     disp_req_i.tag.dest_reg_is_fp,
          do_writeback:   1'b0
        };
      end
      LoopLcp2: begin
        // TODO(colluca): this could be provided by the dispatcher directly
        if ((disp_producer_id_i == disp_req_i.current_producer_dest.producer) &&
            disp_req_i.current_producer_dest.valid) begin
          slot_result_o.do_writeback = 1'b1;
        end
      end
      default: ;
    endcase

    if (restart_i) begin
      slot_result_o = slot_result_reset_val_i;
    end
  end

  //////////////////////////
  // Operand req generation//
  //////////////////////////

  rs_slot_issue_t slot_op;

  // Operand request generation
  always_comb begin: operand_request_generation
    for (int op = 0; op < NofOperands; op++) begin
      op_reqs_o[op] = '{
        producer: selected_slot.operands[op].producer.rs_id,
        request: res_req_t'{
          // Invert the iteration flag if we desire the result from the previous loop iteration
          requested_iter: selected_slot.operands[op].is_from_current_iter ?  selected_slot.instruction_iter :
                                                                             ~selected_slot.instruction_iter,
          slot_id:        selected_slot.operands[op].producer.slot_id
        }
      };

      op_reqs_valid_o[op] = selected_slot.is_occupied &&
                            selected_slot.operands[op].is_produced &&
                            !selected_slot.operands[op].is_valid &&
                            !selected_slot.operands[op].requested;
    end
  end

  logic [NofOperands-1:0] op_reqs_hs;
  assign op_reqs_hs = op_reqs_valid_o & op_reqs_ready_i;

  // Capture request placement at handshake
  always_comb begin : slot_requested_update
    slot_op = selected_slot;
    for (int op = 0; op < NofOperands; op++) begin
      if (op_reqs_hs[op]) begin
        slot_op.operands[op].requested = 1'b1;
      end
    end
  end

  //////////////////////////
  // Operand rsp handling //
  //////////////////////////

  rs_slot_issue_t slot_op_rsp;

  logic [NofOperands-1:0] op_rsps_hs;
  assign op_rsps_hs = op_rsps_valid_i & op_rsps_ready_o;

  // Operand response handling
  always_comb begin : operand_response_handling
    slot_op_rsp = slot_op;
    for (int op = 0; op < NofOperands; op++) begin
      op_rsps_ready_o[op] = 1'b0;
      if (slot_op.is_occupied && slot_op.operands[op].is_produced && op_rsps_valid_i[op]) begin
        slot_op_rsp.operands[op].value     = op_rsps_i[op];
        slot_op_rsp.operands[op].is_valid  = 1'b1;
        slot_op_rsp.operands[op].requested = 1'b0;
        // Acknowledge the response
        // TODO(colluca): does this need to depend on valid?
        op_rsps_ready_o[op] = 1'b1;
      end
    end
  end

  ///////////
  // Issue //
  ///////////

  // Issue an instruction if all operands have been received, based on the slot state after
  // operand handling. Also updates the slot (instruction_iter and operands[i].is_valid fields).

  logic [NofOperands-1:0] operand_valid;
  logic                   all_operands_valid;
  logic                   issue_hs;

  always_comb begin : issue_req
    // Issue the operation if all operands are valid. The FU exerts backpressure if its pipeline
    // is full or the result cannot be written because the current result has not been consumed
    // by all consumers yet.
    // Tag used for the operation is the slot_id, to identify the result destination in case
    // results can come back OoO from the FU (as is the case for the FPU).
    issue_req_o                      = '0;
    issue_req_o.fu_data.fu           = NONE; // Not required by FU
    issue_req_o.fu_data.alu_op       = slot_op_rsp.alu_op;
    issue_req_o.fu_data.lsu_op       = slot_op_rsp.lsu_op;
    issue_req_o.fu_data.csr_op       = CsrOpNone; // Not supported in FREP
    issue_req_o.fu_data.fpu_op       = slot_op_rsp.fpu_op;
    issue_req_o.fu_data.operand_a    = slot_op_rsp.operands[0].value;
    issue_req_o.fu_data.operand_b    = slot_op_rsp.operands[1].value;
    issue_req_o.fu_data.imm          = (NofOperands >= 3) ? slot_op_rsp.operands[2].value : '0;
    issue_req_o.fu_data.lsu_size     = slot_op_rsp.lsu_size;
    issue_req_o.fu_data.fpu_fmt_src  = slot_op_rsp.fpu_fmt_src;
    issue_req_o.fu_data.fpu_fmt_dst  = slot_op_rsp.fpu_fmt_dst;
    issue_req_o.fu_data.fpu_rnd_mode = slot_op_rsp.fpu_rnd_mode;
    issue_req_o.tag                  = issue_producer_id_i.slot_id;
  end

  for (genvar i = 0; i < NofOperands; i++) begin : gen_operand_valid
    assign operand_valid[i] = slot_op_rsp.operands[i].is_valid;
  end
  assign all_operands_valid = &operand_valid;
  // In LCP1, dispatch and issue are decoupled, so we can use the dispatch handshake to initialize
  // the slot, and update it as the operands become valid.
  assign issue_req_valid_o = (loop_state_i == LoopLcp1 ? slot_op_rsp.is_occupied : disp_req_valid_i) && all_operands_valid;
  assign issue_hs = issue_req_valid_o && issue_req_ready_i;
  // TODO(colluca): does this need to depend on both ready and valid? might affect critical path
  assign disp_req_ready_o = (loop_state_i == LoopLcp1) || issue_hs;
  assign disp_hs = disp_req_ready_o && disp_req_valid_i;
  assign retire_at_issue_o = issue_hs && slot_op_rsp.no_dest;

  // Update the slot after issuing the instruction (instruction_iter and
  // operands[i].is_valid fields).

  always_comb begin : slot_issue_update
    slot_issue_o = slot_op_rsp;
    slot_issue_wen_o = disp_hs || |op_reqs_hs || |op_rsps_hs || issue_hs; // We can update the slot upon dispatch (new instruction) or when issuing (toggle iteration and invalidate operands)

    if (issue_hs) begin
      // Toggle instruction state
      slot_issue_o.instruction_iter = ~slot_issue_o.instruction_iter;
      // If an operand is produced, we have to reset the is_valid flag when the operand is
      // consumed (upon issue), since a new value will have to be captured in the next iteration.
      for (int i = 0; i < NofOperands; i++) begin
        slot_issue_o.operands[i].is_valid = slot_issue_o.operands[i].is_produced ? 1'b0 :
                                            slot_issue_o.operands[i].is_valid;
      end
      // Free the slot on the last issue iteration so it can be reused in the next LCP1.
      if (last_issue_iter_i) slot_issue_o.is_occupied = 1'b0;
    end
  end

  ////////////////
  // Assertions //
  ////////////////

  // A dispatch request cannot be accepted in LCP1 if the slot is occupied
  `ASSERT(DispLcp1SlotNotOccupied,
    (disp_hs && loop_state_i == LoopLcp1) |-> !slot_issue_i.is_occupied)

  // A dispatch request cannot be accepted in LCP2 and LEP if the slot is not occupied
  `ASSERT(DispLcp2LepSlotOccupied,
    (disp_hs && loop_state_i inside {LoopLcp2, LoopLep}) |-> slot_issue_i.is_occupied)

endmodule
