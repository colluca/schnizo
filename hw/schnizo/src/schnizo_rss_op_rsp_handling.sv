// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Handle the response after the request generation to allow same cycle responses.
// We won't place two requests due to the requested flag.

module schnizo_rss_op_rsp_handling import schnizo_pkg::*; #(
  parameter int unsigned NofOperands = 2,
  parameter type         rs_slot_t = logic,
  parameter type         operand_t = logic
) (
  // Slot data after sending operand request
  input  rs_slot_t slot_i,
  // Slot data after handling responses
  output rs_slot_t slot_o,
  // Operand response interface - incoming - returning result as operand
  input  operand_t [NofOperands-1:0] op_rsps_i,
  input  logic     [NofOperands-1:0] op_rsps_valid_i,
  output logic     [NofOperands-1:0] op_rsps_ready_o
);

  // Operand response handling
  always_comb begin : operand_response_handling
    slot_o = slot_i;
    for (int op = 0; op < NofOperands; op++) begin
      op_rsps_ready_o[op] = 1'b0;
      if (slot_i.is_occupied && slot_i.operands[op].is_produced && op_rsps_valid_i[op]) begin
        slot_o.operands[op].value     = op_rsps_i[op];
        slot_o.operands[op].is_valid  = 1'b1;
        slot_o.operands[op].requested = 1'b0;
        // Acknowledge the response
        op_rsps_ready_o[op] = 1'b1;
      end
    end
  end

endmodule
