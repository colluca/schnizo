// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Combines initial slot update, operand request generation, operand response handling,
// and issue logic into a single module.
module schnova_rss_dispatch_pipeline import schnizo_pkg::*; #(
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
  // Control
  input  logic            restart_i,
  input  producer_id_t    producer_id_i,
  input  disp_req_t       disp_req_i,
  input  logic            disp_req_valid_i,
  input  rs_slot_issue_t  slot_issue_i,
  input  rs_slot_result_t slot_result_i,
  input  rs_slot_result_t slot_result_reset_val_i,
  output rs_slot_issue_t  slot_issue_o,
  output rs_slot_result_t slot_result_o,

  // Operand request
  output operand_req_t [NofOperands-1:0] op_reqs_o,
  output logic         [NofOperands-1:0] op_reqs_valid_o,
  input  logic         [NofOperands-1:0] op_reqs_ready_i,

  // Operand response
  input  operand_t     [NofOperands-1:0] op_rsps_i,
  input  logic         [NofOperands-1:0] op_rsps_valid_i,
  output logic         [NofOperands-1:0] op_rsps_ready_o,

  // Issue
  input  logic         issue_req_ready_i,
  output logic         disp_req_ready_o,
  output issue_req_t   issue_req_o,
  output logic         issue_req_valid_o,
  output logic         issue_hs_o
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
    operands:         '0 // invalid operands lead to no issue requests
  };

  // The initial operand values when accepting a new instruction
  rss_operand_t op_a_init;
  rss_operand_t op_b_init;
  rss_operand_t op_c_init;

  assign op_a_init = '{
    producer:             disp_req_i.producer_op_a.producer,
    is_produced:          disp_req_i.producer_op_a.valid,
    is_from_current_iter: disp_req_i.producer_op_a.valid,
    value:                disp_req_i.fu_data.operand_a,
    is_valid:             !disp_req_i.producer_op_a.valid,
    requested:            1'b0
  };

  assign op_b_init = '{
    producer:             disp_req_i.producer_op_b.producer,
    is_produced:          disp_req_i.producer_op_b.valid,
    value:                disp_req_i.fu_data.operand_b,
    is_valid:             !disp_req_i.producer_op_b.valid,
    requested:            1'b0
  };

  assign op_c_init = '{
    producer:             disp_req_i.producer_op_c.producer,
    is_produced:          disp_req_i.producer_op_c.valid,
    value:                disp_req_i.fu_data.imm,
    is_valid:             !disp_req_i.producer_op_c.valid,
    requested:            1'b0
  };

  // Array to simplify initial operand assignment
  rss_operand_t [2:0] ops_init;
  assign ops_init[0] = op_a_init;
  assign ops_init[1] = op_b_init;
  assign ops_init[2] = op_c_init;

  // Initial value of the slot upon accepting a new instruction
  rs_slot_issue_t slot_init;
  always_comb begin
    slot_init = '{
      is_occupied:      1'b1,
      alu_op:           disp_req_i.fu_data.alu_op,
      lsu_op:           disp_req_i.fu_data.lsu_op,
      fpu_op:           disp_req_i.fu_data.fpu_op,
      lsu_size:         disp_req_i.fu_data.lsu_size,
      fpu_fmt_src:      disp_req_i.fu_data.fpu_fmt_src,
      fpu_fmt_dst:      disp_req_i.fu_data.fpu_fmt_dst,
      fpu_rnd_mode:     disp_req_i.fu_data.fpu_rnd_mode,
      operands:         '0
    };

    // Operands must be assigned depending on the number we have
    for (int op = 0; op < NofOperands; op++) begin
      slot_init.operands[op] = ops_init[op];
    end
  end

  rs_slot_issue_t selected_slot;
  always_comb begin : slot_selection
    // Update the slot depending on the state.
    selected_slot = slot_issue_i;
    // If we have a valid dispatch request this cycle
    // the slot is forwarded from the dispatch request.
    if (disp_req_valid_i) begin
      selected_slot = slot_init;
    end
    // Slot initialization has highest priority
    if (restart_i) begin
      selected_slot = slot_issue_reset_val;
    end
  end

  // Compute the updated result slot state
  // If we have a new dispatch request for this slot
  // we have to initialize the result
  // otherwise we forward the current result.
  always_comb begin
    slot_result_o = slot_result_i;

    // We initialize for every new dispatch request
    if (disp_req_valid_i) begin
      slot_result_o = '{
          result:         rss_result_t'{ value: '0, is_valid: 1'b0, iteration: 1'b1 },
          has_dest:       (disp_req_i.fu_data.fu == STORE) &&
                          (disp_req_i.fu_data.fpu_op inside {LsuOpStore, LsuOpFpStore}),
          dest_id:        disp_req_i.tag.dest_reg,
          dest_is_fp:     disp_req_i.tag.dest_reg_is_fp
        };
    end

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
          slot_id:        selected_slot.operands[op].producer.slot_id
        }
      };

      op_reqs_valid_o[op] = disp_req_valid_i && selected_slot.is_occupied &&
                            selected_slot.operands[op].is_produced &&
                            !selected_slot.operands[op].is_valid &&
                            !selected_slot.operands[op].requested;
    end
  end

  // Capture request placement at handshake
  always_comb begin : slot_requested_update
    slot_op = selected_slot;
    for (int op = 0; op < NofOperands; op++) begin
      if (op_reqs_valid_o[op] && op_reqs_ready_i[op]) begin
        slot_op.operands[op].requested = 1'b1;
      end
    end
  end

  //////////////////////////
  // Operand rsp handling //
  //////////////////////////

  rs_slot_issue_t slot_op_rsp;

  // Operand response handling
  always_comb begin : operand_response_handling
    slot_op_rsp = slot_op;
    for (int op = 0; op < NofOperands; op++) begin
      op_rsps_ready_o[op] = 1'b0;
      if (slot_op.is_occupied && slot_op.operands[op].is_produced && op_rsps_valid_i[op]) begin
        slot_op_rsp.operands[op].value     = op_rsps_i[op];
        slot_op_rsp.operands[op].is_valid  = 1'b1;
        // Acknowledge the response
        op_rsps_ready_o[op] = 1'b1;
      end
    end
  end

  ///////////
  // Issue //
  ///////////

  // Issue an instruction if all operands have been received, based on the slot state after

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
    issue_req_o.tag                  = producer_id_i.slot_id;
  end

  for (genvar i = 0; i < NofOperands; i++) begin : gen_operand_valid
    assign operand_valid[i] = slot_op_rsp.operands[i].is_valid;
  end
  assign all_operands_valid = &operand_valid;
  assign issue_req_valid_o = disp_req_valid_i && slot_op_rsp.is_occupied && all_operands_valid;
  assign issue_hs = issue_req_valid_o && issue_req_ready_i;
  // TODO(colluca): does this need to depend on both ready and valid? might affect critical path
  assign disp_req_ready_o = issue_hs;
  assign issue_hs_o = issue_hs;

endmodule
