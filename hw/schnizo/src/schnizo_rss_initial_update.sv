// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Performs the initial state-dependent slot update for the reservation station slot.
// Based on the current loop state and dispatch request, computes the next slot value.
module schnizo_rss_initial_update import schnizo_pkg::*; #(
  parameter int unsigned NofOperands    = 2,
  parameter type         disp_req_t     = logic,
  parameter type         producer_id_t  = logic,
  parameter type         rs_slot_t      = logic,
  parameter type         rss_operand_t  = logic,
  parameter type         rss_result_t   = logic
) (
  input  logic         restart_i,
  input  producer_id_t own_producer_id_i,
  input  loop_state_e  loop_state_i,
  input  disp_req_t    disp_req_i,
  input  logic         disp_req_valid_i,
  input  rs_slot_t     slot_i,
  input  rs_slot_t     slot_reset_state_i,
  output rs_slot_t     slot_o
);

  ////////////////////
  // Slot selection //
  ////////////////////

  // This stage performs an initial state-dependent slot update.

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
  rs_slot_t slot_lcp1;
  always_comb begin
    slot_lcp1 = '{
      is_occupied:          1'b1,
      consumer_count:       '0,
      consumed_by:          '0,
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

  // Initial value of the slot upon accepting an instruction in LCP2.
  // Now all operand producers should be known, so we can update the missing producer information.
  // We also now know which instruction is the last in the loop to write to a certain register.
  // We can therefore also update the `do_writeback` flag.
  rs_slot_t slot_lcp2;
  always_comb begin
    slot_lcp2 = slot_i;

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
    // Set the writeback flag if we are the last RSS writing to this destination
    // TODO(colluca): couldn't we have the dispatcher calculate `do_writeback` instead?
    // This way we don't need to store it in the cut. It may increase the critical path
    // if the critical path is before the cut.
    if ((own_producer_id_i == disp_req_i.current_producer_dest.producer) &&
        disp_req_i.current_producer_dest.valid) begin
      slot_lcp2.do_writeback = 1'b1;
    end
  end

  // INFO(soderma):
  // We can use the regular state. The reason pascal probably did this is because of multi cycle updates.
  // so that you don't overwrite the dispatch request. But the dispatch request valid signal is only valid for one cycle anyway in LCP1 and LCP2
  // reason being is that all operands are ready and the instruction can be immediately issued.
  always_comb begin : slot_selection
    // Update the slot depending on the state.
    slot_o = slot_i;
    unique case (loop_state_i)
      LoopLcp1: begin
        if (disp_req_valid_i) begin
          slot_o = slot_lcp1; // Load the new instruction
        end
      end
      LoopLcp2: begin
        if (disp_req_valid_i) begin
          // Update producers if there is not yet one set.
          slot_o = slot_lcp2;
        end
      end
      default: ;
    endcase

    // Slot initialization has highest priority
    if (restart_i) begin
      slot_o = slot_reset_state_i;
    end
  end

endmodule
