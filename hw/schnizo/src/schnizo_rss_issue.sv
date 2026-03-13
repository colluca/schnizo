// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnizo_rss_issue import schnizo_pkg::*; #(
  parameter int unsigned NofOperands  = 2,
  parameter type         rss_idx_t    = logic,
  parameter type         rs_slot_t    = logic,
  parameter type         issue_req_t  = logic
) (
  input  rs_slot_t   slot_i,
  input  rss_idx_t   slot_id_i,
  input  logic       disp_req_valid_i,
  input  logic       issue_req_ready_i,
  output logic       disp_req_ready_o,
  output rs_slot_t   slot_o,
  output issue_req_t issue_req_o,
  output logic       issue_req_valid_o,
  output logic       issue_hs_o
);

  logic [NofOperands-1:0] operand_valid;
  logic                   all_operands_valid;
  logic                   issue_hs;

  // Issue an instruction if all operands have been received, based on the slot state after
  // operand handling. Also updates the slot (instruction_iter and operands[i].is_valid fields).

  always_comb begin : issue_req
    // Issue the operation if all operands are valid. The FU exerts backpressure if its pipeline
    // is full or the result cannot be written because the current result has not been consumed
    // by all consumers yet.
    // Tag used for the operation is the slot_id, to identify the result destination in case
    // results can come back OoO from the FU (as is the case for the FPU).
    issue_req_o                      = '0;
    issue_req_o.fu_data.fu           = NONE; // Not required by FU
    issue_req_o.fu_data.alu_op       = slot_i.alu_op;
    issue_req_o.fu_data.lsu_op       = slot_i.lsu_op;
    issue_req_o.fu_data.csr_op       = CsrOpNone; // Not supported in FREP
    issue_req_o.fu_data.fpu_op       = slot_i.fpu_op;
    issue_req_o.fu_data.operand_a    = slot_i.operands[0].value;
    issue_req_o.fu_data.operand_b    = slot_i.operands[1].value;
    issue_req_o.fu_data.imm          = (NofOperands >= 3) ? slot_i.operands[2].value : '0;
    issue_req_o.fu_data.lsu_size     = slot_i.lsu_size;
    issue_req_o.fu_data.fpu_fmt_src  = slot_i.fpu_fmt_src;
    issue_req_o.fu_data.fpu_fmt_dst  = slot_i.fpu_fmt_dst;
    issue_req_o.fu_data.fpu_rnd_mode = slot_i.fpu_rnd_mode;
    issue_req_o.tag                  = slot_id_i;
  end

  for (genvar i = 0; i < NofOperands; i++) begin : gen_operand_valid
    assign operand_valid[i] = slot_i.operands[i].is_valid;
  end
  assign all_operands_valid = &operand_valid;
  assign issue_req_valid_o = disp_req_valid_i && slot_i.is_occupied && all_operands_valid;
  assign issue_hs = issue_req_valid_o && issue_req_ready_i;
  // TODO(colluca): does this need to depend on both ready and valid? might affect critical path
  assign disp_req_ready_o = issue_hs;

  // Update the slot after issuing the instruction (instruction_iter and
  // operands[i].is_valid fields).

  always_comb begin : slot_issue_update
    slot_o = slot_i;

    if (issue_hs) begin
      // Toggle instruction state
      slot_o.instruction_iter = ~slot_o.instruction_iter;
      // If an operand is produced, we have to reset the is_valid flag when the operand is
      // consumed (upon issue), since a new value will have to be captured in the next iteration.
      for (int i = 0; i < NofOperands; i++) begin
        slot_o.operands[i].is_valid = slot_o.operands[i].is_produced ? 1'b0 :
                                      slot_o.operands[i].is_valid;
      end
    end
  end

endmodule
