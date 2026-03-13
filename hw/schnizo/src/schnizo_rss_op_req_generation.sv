// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Sends operand requests and accepts responses based on the state of the slot after the
// slot selection stage.
// Also updates the slot after requesting operands (operands[i].requested field) and after
// receiving responses (operands[i].{value,is_valid,requested} fields).

module schnizo_rss_op_req_generation import schnizo_pkg::*; #(
  parameter int unsigned NofOperands    = 2,
  parameter type         rs_slot_t      = logic,
  parameter type         operand_req_t  = logic,
  parameter type         res_req_t      = logic
) (
  // Slot data before sending the operand request
  input  rs_slot_t slot_i,
  // Slot data after sending the operand request
  output rs_slot_t slot_o,
  // Dispatch interface
  input  logic     disp_req_valid_i,
  // Operand request interface - outgoing - request a result as operand
  output operand_req_t [NofOperands-1:0] op_reqs_o,
  output logic         [NofOperands-1:0] op_reqs_valid_o,
  input  logic         [NofOperands-1:0] op_reqs_ready_i
);

  // Operand request generation
  always_comb begin: operand_request_generation
    for (int op = 0; op < NofOperands; op++) begin
      op_reqs_o[op] = '{
        producer: slot_i.operands[op].producer.rs_id,
        request: res_req_t'{
          // Invert the iteration flag if we desire the result from the previous loop iteration
          requested_iter: slot_i.operands[op].is_from_current_iter ?  slot_i.instruction_iter :
                                                                      ~slot_i.instruction_iter,
          slot_id:        slot_i.operands[op].producer.slot_id
        }
      };

      op_reqs_valid_o[op] = disp_req_valid_i && slot_i.is_occupied &&
                            slot_i.operands[op].is_produced &&
                            !slot_i.operands[op].is_valid &&
                            !slot_i.operands[op].requested;
    end
  end

  // Capture request placement at handshake
  always_comb begin : slot_requested_update
    slot_o = slot_i;
    for (int op = 0; op < NofOperands; op++) begin
      if (op_reqs_valid_o[op] && op_reqs_ready_i[op]) begin
        slot_o.operands[op].requested = 1'b1;
      end
    end
  end

endmodule
