// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"

// Combines initial slot update, operand request generation, operand response handling,
// and issue logic into a single module.
module schnizo_rss_dispatch_pipeline import schnizo_pkg::*; #(
  parameter int unsigned NofOperands      = 2,
  parameter int unsigned NofConstantPorts = 2,
  parameter type         disp_req_t       = logic,
  parameter type         producer_id_t    = logic,
  parameter type         rs_slot_issue_t  = logic,
  parameter type         rs_slot_result_t = logic,
  parameter type         rss_operand_t    = logic,
  parameter type         rss_result_t     = logic,
  parameter type         operand_req_t    = logic,
  parameter type         const_op_addr_t  = logic,
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

  // Constant memory interface
  output logic           [NofConstantPorts-1:0] alloc_const_op_valid_o,
  output operand_t       [NofConstantPorts-1:0] alloc_const_op_data_o,
  input  const_op_addr_t [NofConstantPorts-1:0] alloc_const_op_addr_i,

  // Result slot interface
  input  rs_slot_result_t slot_result_i,
  input  rs_slot_result_t slot_result_reset_val_i,
  output rs_slot_result_t slot_result_o,

  // Dispatch
  input  disp_req_t disp_req_i,
  input  logic      disp_req_valid_i,
  output logic      disp_req_ready_o,

  // Operand request
  // To ODN
  output operand_req_t [NofOperands-1:0] odn_op_reqs_o,
  output logic         [NofOperands-1:0] odn_op_reqs_valid_o,
  input  logic         [NofOperands-1:0] odn_op_reqs_ready_i,
  // To constant memory
  output const_op_addr_t [NofConstantPorts-1:0] const_op_reqs_o,
  output logic           [NofConstantPorts-1:0] const_op_reqs_valid_o,

  // Operand response
  // From ODN
  input  operand_t [NofOperands-1:0] odn_op_rsps_i,
  input  logic     [NofOperands-1:0] odn_op_rsps_valid_i,
  output logic     [NofOperands-1:0] odn_op_rsps_ready_o,
  // From constant memory
  input  operand_t [NofConstantPorts-1:0] const_op_rsps_i,

  // Issue
  output issue_req_t issue_req_o,
  output logic       issue_req_valid_o,
  input  logic       issue_req_ready_i
);

  //////////////////////
  // Type definitions //
  //////////////////////

  typedef struct packed {
    operand_t value;
    logic     is_valid;
    logic     requested;
  } operand_slot_t;

  typedef operand_slot_t [NofOperands-1:0] operand_slots_t; 

  //////////////////////////
  // Forward declarations //
  //////////////////////////

  operand_slots_t op_slots_q;
  logic           disp_hs, issue_hs;

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
  operand_slot_t op_a_slot_lcp1;
  operand_slot_t op_b_slot_lcp1;
  operand_slot_t op_c_slot_lcp1;

  assign op_a_lcp1 = '{
    is_used:              disp_req_i.fu_data.use_operand_a,
    producer:             disp_req_i.producer_op_a.producer,
    is_produced:          disp_req_i.producer_op_a.valid,
    is_from_current_iter: disp_req_i.producer_op_a.valid
  };
  assign op_a_slot_lcp1 = '{
    value:                disp_req_i.fu_data.operand_a,
    is_valid:             !disp_req_i.producer_op_a.valid,
    requested:            1'b0
  };

  assign op_b_lcp1 = '{
    is_used:              disp_req_i.fu_data.use_operand_b,
    producer:             disp_req_i.producer_op_b.producer,
    is_produced:          disp_req_i.producer_op_b.valid,
    is_from_current_iter: disp_req_i.producer_op_b.valid
  };
  assign op_b_slot_lcp1 = '{
    value:                disp_req_i.fu_data.operand_b,
    is_valid:             !disp_req_i.producer_op_b.valid,
    requested:            1'b0
  };

  assign op_c_lcp1 = '{
    is_used:              disp_req_i.fu_data.use_imm,
    producer:             disp_req_i.producer_op_c.producer,
    is_produced:          disp_req_i.producer_op_c.valid,
    is_from_current_iter: disp_req_i.producer_op_c.valid
  };
  assign op_c_slot_lcp1 = '{
    value:                disp_req_i.fu_data.imm,
    is_valid:             !disp_req_i.producer_op_c.valid,
    requested:            1'b0
  };

  // Initial value of the slot upon accepting a new instruction
  rs_slot_issue_t slot_lcp1;
  operand_slots_t op_slots_lcp1;
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
    slot_lcp1.operands[0] = op_a_lcp1;
    slot_lcp1.operands[1] = op_b_lcp1;
    op_slots_lcp1[0] = op_a_slot_lcp1;
    op_slots_lcp1[1] = op_b_slot_lcp1;
    if (NofOperands >= 3) begin
      slot_lcp1.operands[2] = op_c_lcp1;
      op_slots_lcp1[2] = op_c_slot_lcp1;
    end
  end

  // Initial value of the slot upon accepting an instruction in LCP2.
  // Now all operand producers should be known, so we can update the missing producer information.
  rs_slot_issue_t slot_lcp2;
  operand_slots_t op_slots_lcp2;
  always_comb begin
    slot_lcp2 = slot_issue_i;
    op_slots_lcp2 = op_slots_q;

    // Update producers if there is not yet one set.
    // TODO(colluca): could we also update the producer for operands which already
    // have a producer? Probably yes, then this would be an energy-saving optimization.
    // Test this so we can better document it.
    if (!slot_lcp2.operands[0].is_produced) begin
      slot_lcp2.operands[0].producer    = disp_req_i.producer_op_a.producer;
      slot_lcp2.operands[0].is_produced = disp_req_i.producer_op_a.valid;
      op_slots_lcp2[0].is_valid         = !disp_req_i.producer_op_a.valid;
      op_slots_lcp2[0].value            = disp_req_i.fu_data.operand_a;
    end
    if (!slot_lcp2.operands[1].is_produced) begin
      slot_lcp2.operands[1].producer    = disp_req_i.producer_op_b.producer;
      slot_lcp2.operands[1].is_produced = disp_req_i.producer_op_b.valid;
      op_slots_lcp2[1].is_valid         = !disp_req_i.producer_op_b.valid;
      op_slots_lcp2[1].value            = disp_req_i.fu_data.operand_b;
    end
    if (NofOperands >= 3) begin
      if (!slot_lcp2.operands[2].is_produced) begin
        slot_lcp2.operands[2].producer    = disp_req_i.producer_op_c.producer;
        slot_lcp2.operands[2].is_produced = disp_req_i.producer_op_c.valid;
        op_slots_lcp2[2].is_valid         = !disp_req_i.producer_op_c.valid;
        op_slots_lcp2[2].value            = disp_req_i.fu_data.imm;
      end
    end
  end

  // INFO(soderma):
  // We can use the regular state. The reason pascal probably did this is because of multi cycle updates.
  // so that you don't overwrite the dispatch request. But the dispatch request valid signal is only valid for one cycle anyway in LCP1 and LCP2
  // reason being is that all operands are ready and the instruction can be immediately issued.
  rs_slot_issue_t selected_slot;
  operand_slots_t selected_op_slots;
  always_comb begin : slot_selection
    // Update the slot depending on the state.
    selected_slot = slot_issue_i;
    selected_op_slots = op_slots_q;
    unique case (loop_state_i)
      LoopLcp1: begin
        if (disp_req_valid_i) begin
          selected_slot = slot_lcp1; // Load the new instruction
          selected_op_slots = op_slots_lcp1;
        end
      end
      LoopLcp2: begin
        if (disp_req_valid_i) begin
          // Update producers if there is not yet one set.
          selected_slot = slot_lcp2;
          selected_op_slots = op_slots_lcp2;
        end
      end
      default: ;
    endcase

    // Slot initialization has highest priority
    if (restart_i) begin
      selected_slot = slot_issue_reset_val;
      selected_op_slots = '0;
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

  ////////////////////////////////
  // Constant memory allocation //
  ////////////////////////////////

  rs_slot_issue_t alloc_const_op_slot;

  always_comb begin: const_op_allocation
    automatic int unsigned port = 0;

    alloc_const_op_slot = selected_slot;
    alloc_const_op_valid_o = '0;
    alloc_const_op_data_o = '0;

    for (int op = 0; op < NofOperands; op++) begin
      if (selected_slot.operands[op].is_used && !selected_slot.operands[op].is_produced) begin
        alloc_const_op_data_o[port] = selected_op_slots[op].value;
        // Dispatch handshake ensures operand is only allocated once
        if ((loop_state_i == LoopLcp2) && disp_hs) begin
          alloc_const_op_valid_o[port] = 1'b1;
          alloc_const_op_slot.operands[op].producer = alloc_const_op_addr_i[port];
        end
        port++;
        if (port == NofConstantPorts) break;
      end
    end
  end

  ////////////////////////////
  // Operand req generation //
  ////////////////////////////

  operand_slots_t request_op_slots;

  // ODN operand request generation
  always_comb begin: odn_op_req_generation
    for (int op = 0; op < NofOperands; op++) begin
      odn_op_reqs_o[op] = '{
        producer: alloc_const_op_slot.operands[op].producer.rs_id,
        request: res_req_t'{
          // Invert the iteration flag if we desire the result from the previous loop iteration
          requested_iter: alloc_const_op_slot.operands[op].is_from_current_iter ?
                          alloc_const_op_slot.instruction_iter :
                          ~alloc_const_op_slot.instruction_iter,
          slot_id:        alloc_const_op_slot.operands[op].producer.slot_id
        }
      };

      odn_op_reqs_valid_o[op] = alloc_const_op_slot.is_occupied &&
        !(loop_state_i == LoopLcp1 && alloc_const_op_slot.instruction_iter == 1'b1) &&
        alloc_const_op_slot.operands[op].is_produced &&
        !selected_op_slots[op].is_valid &&
        !selected_op_slots[op].requested;
    end
  end

  // Constant memory request generation
  always_comb begin: const_op_req_generation
    automatic int unsigned port = 0;

    const_op_reqs_o = '0;
    const_op_reqs_valid_o = '0;

    for (int op = 0; op < NofOperands; op++) begin
      if (alloc_const_op_slot.operands[op].is_used &&
          !alloc_const_op_slot.operands[op].is_produced && (loop_state_i == LoopLep)) begin
        const_op_reqs_o[port] = const_op_addr_t'(alloc_const_op_slot.operands[op].producer);
        const_op_reqs_valid_o[port] = !selected_op_slots[op].is_valid;
        port++;
        if (port == NofConstantPorts) break;
      end
    end
  end

  logic [NofOperands-1:0] odn_op_reqs_hs;
  assign odn_op_reqs_hs = odn_op_reqs_valid_o & odn_op_reqs_ready_i;

  // Capture request placement at handshake
  always_comb begin : slot_requested_update
    request_op_slots = selected_op_slots;
    for (int op = 0; op < NofOperands; op++) begin
      // Operands requested from the constant memory are immediately valid, no need
      // to toggle the intermediate `requested` state.
      if (alloc_const_op_slot.operands[op].is_produced && odn_op_reqs_hs[op]) begin
        request_op_slots[op].requested = 1'b1;
      end
    end
  end

  //////////////////////////
  // Operand rsp handling //
  //////////////////////////

  operand_slots_t response_op_slots;

  logic [NofOperands-1:0] odn_op_rsps_hs;
  assign odn_op_rsps_hs = odn_op_rsps_valid_i & odn_op_rsps_ready_o;

  // Always ready to accept a response after placing an operand request
  assign odn_op_rsps_ready_o = '1;

  // Direct the operand responses from the constant memory ports to the respective operands
  operand_t [NofOperands-1:0] const_mem_rsp_operands;
  always_comb begin : redirect_const_mem_responses
    automatic int unsigned port = 0;

    const_mem_rsp_operands = '0;

    for (int op = 0; op < NofOperands; op++) begin
      if (alloc_const_op_slot.operands[op].is_used &&
          !alloc_const_op_slot.operands[op].is_produced) begin
        const_mem_rsp_operands[op] = const_op_rsps_i[port];
        port++;
        if (port == NofConstantPorts) break;
      end
    end
  end

  // Handle ODN operand responses
  always_comb begin : operand_response_handling
    response_op_slots = request_op_slots;

    for (int op = 0; op < NofOperands; op++) begin      
      if (alloc_const_op_slot.operands[op].is_produced) begin
        if (odn_op_rsps_hs[op]) begin
          response_op_slots[op].value     = odn_op_rsps_i[op];
          response_op_slots[op].is_valid  = 1'b1;
        end
      end else if (loop_state_i == LoopLep) begin
        response_op_slots[op].value    = const_mem_rsp_operands[op];
        response_op_slots[op].is_valid = alloc_const_op_slot.operands[op].is_used;
      end
    end
  end

  //////////////
  // Dispatch //
  //////////////

  // 1-bit FSM
  logic dispatched_q, dispatched_d;
  always_comb begin : fsm
    dispatched_d = dispatched_q;
    if (disp_hs) begin
      dispatched_d = 1'b1;
    end
    if (issue_hs) begin
      dispatched_d = 1'b0;
    end
  end
  `FF(dispatched_q, dispatched_d, 1'b0)

  assign disp_req_ready_o = !dispatched_q;
  assign disp_hs = disp_req_ready_o && disp_req_valid_i;

  ///////////
  // Issue //
  ///////////

  // Issue an instruction if all operands have been received, based on the slot state after
  // operand handling. Also updates the slot (instruction_iter and operands[i].is_valid fields).

  logic [NofOperands-1:0] operand_valid;
  logic                   all_operands_valid;

  // Compose issue request
  always_comb begin : issue_req
    // Issue the operation if all operands are valid. The FU exerts backpressure if its pipeline
    // is full or the result cannot be written because the current result has not been consumed
    // by all consumers yet.
    // Tag used for the operation is the slot_id, to identify the result destination in case
    // results can come back OoO from the FU (as is the case for the FPU).
    issue_req_o                      = '0;
    issue_req_o.fu_data.fu           = NONE; // Not required by FU
    issue_req_o.fu_data.alu_op       = alloc_const_op_slot.alu_op;
    issue_req_o.fu_data.lsu_op       = alloc_const_op_slot.lsu_op;
    issue_req_o.fu_data.csr_op       = CsrOpNone; // Not supported in FREP
    issue_req_o.fu_data.fpu_op       = alloc_const_op_slot.fpu_op;
    issue_req_o.fu_data.operand_a    = response_op_slots[0].value;
    issue_req_o.fu_data.operand_b    = response_op_slots[1].value;
    issue_req_o.fu_data.imm          = (NofOperands >= 3) ? response_op_slots[2].value : '0;
    issue_req_o.fu_data.lsu_size     = alloc_const_op_slot.lsu_size;
    issue_req_o.fu_data.fpu_fmt_src  = alloc_const_op_slot.fpu_fmt_src;
    issue_req_o.fu_data.fpu_fmt_dst  = alloc_const_op_slot.fpu_fmt_dst;
    issue_req_o.fu_data.fpu_rnd_mode = alloc_const_op_slot.fpu_rnd_mode;
    issue_req_o.tag                  = issue_producer_id_i.slot_id;
  end

  // Check operand validity
  for (genvar i = 0; i < NofOperands; i++) begin : gen_operand_valid
    assign operand_valid[i] = !alloc_const_op_slot.operands[i].is_used ||
                              response_op_slots[i].is_valid;
  end
  assign all_operands_valid = &operand_valid;

  // Issue when instruction has been dispatched (previously or in current cycle), the slot is
  // occupied, all operands are valid and the current slot hasn't been already issued
  assign issue_req_valid_o = (dispatched_q || disp_hs) && alloc_const_op_slot.is_occupied &&
                             all_operands_valid;  // && !already_issued;
  assign issue_hs = issue_req_valid_o && issue_req_ready_i;
  assign retire_at_issue_o = issue_hs && alloc_const_op_slot.no_dest;

  // Update slot after issue
  operand_slots_t op_slots_d;
  always_comb begin : slot_issue_update
    slot_issue_o = alloc_const_op_slot;
    op_slots_d = response_op_slots;
    // We can update the slot upon dispatch (new instruction) or when issuing
    // (toggle iteration and invalidate operands)
    slot_issue_wen_o = disp_hs || issue_hs;

    if (issue_hs) begin
      // Toggle instruction state
      slot_issue_o.instruction_iter = ~slot_issue_o.instruction_iter;
      // We have to reset the `is_valid` flag when the operand is consumed (upon issue),
      // since a new value will have to be captured in the next iteration.
      // Similarly, we have to clear the `requested` flag, since the operand will
      // have to be requested again. 
      for (int i = 0; i < NofOperands; i++) begin
        op_slots_d[i].is_valid = 1'b0;
        op_slots_d[i].requested = 1'b0;
      end
      // Free the slot on the last issue iteration so it can be reused in the next LCP1.
      if (last_issue_iter_i) slot_issue_o.is_occupied = 1'b0;
    end
  end

  // Operand slots for instruction currently being issued
  `FF(op_slots_q, op_slots_d, '0)

  ////////////////
  // Assertions //
  ////////////////

  // A dispatch request cannot be accepted in LCP2 and LEP if the slot is not occupied
  `ASSERT(DispLcp2LepSlotOccupied,
    (disp_hs && loop_state_i inside {LoopLcp2, LoopLep}) |-> slot_issue_i.is_occupied)

  // A response can only arrive if a request was placed, which requires is_occupied, is_produced
  // and requested
  for (genvar op = 0; op < NofOperands; op++) begin : gen_op_rsp_assertions
    `ASSERT(OpRspImpliesOccupied,  odn_op_rsps_valid_i[op] |-> alloc_const_op_slot.is_occupied)
    `ASSERT(OpRspImpliesProduced,  odn_op_rsps_valid_i[op] |->
            alloc_const_op_slot.operands[op].is_produced)
    `ASSERT(OpRspImpliesRequested, odn_op_rsps_valid_i[op] |-> request_op_slots[op].requested) 
  end

  // There can't be more than NofConstantPorts constants per instruction
  // TODO(colluca): replace with fallback to HWLOOP mode
  logic [1:0] num_constants;
  always_comb begin
    num_constants = 0;
    for (int unsigned op = 0; op < NofOperands; op++) begin
      num_constants += !selected_slot.operands[op].is_produced;
    end
  end
  `ASSERT(MaxConstantsPerInsn, ((loop_state_i == LoopLcp2) && disp_hs) |-> (num_constants <= NofConstantPorts))

endmodule
