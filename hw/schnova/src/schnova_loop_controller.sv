// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// The Schnova loop controller.
//
// Manages control flow for sequential HW loop execution, i.e. LCP and naive HW loop modes.
// Superscalar (LEP) mode is handled directly in the reservation stations.
module schnova_loop_controller import schnova_pkg::*, schnova_pkg::*; #(
  parameter int unsigned PipeWidth          = 1,
  parameter int unsigned AddrWidth          = 32,
  parameter int unsigned MaxBodysizeWidth   = 12,
  parameter int unsigned MaxIterationsWidth = 6,
  parameter type block_ctrl_info_t      = logic,
  parameter type         instr_dec_t    = logic
) (
  input logic clk_i,
  input logic rst_i,
  input  logic [PipeWidth-1:0] instr_valid_i,
  input  instr_dec_t [PipeWidth-1:0] instr_decoded_i,
  output logic [PipeWidth-1:0] valid_mask_o,
  input  logic [AddrWidth-1:0] instr_addr_i,
  input  block_ctrl_info_t     blk_ctrl_info_i,
  input  logic                 dispatched_i,
  // The instruction address following the current instruction (i.e., the first loop instruction)
  input  logic [AddrWidth-1:0] next_instr_addr_i,
  // If we stall, do not update state / step in loop body.
  input  logic stall_i,
  // If there is an exception abort the loop
  input  logic exception_i,
  // Request a loop start at the current instruction address. Any errors will be checked by the
  // controller which then asserts the commit signal if no errors arose.
  input  logic                      loop_start_req_i,
  input  logic                      loop_start_commit_i,
  input  logic [MaxBodysizeWidth-1:0]   loop_bodysize_i,
  input  logic [MaxIterationsWidth-1:0] loop_iterations_i,
  input  frep_mode_e                frep_mode_i,
  // Request to jump to the loop start address
  output logic                      loop_jump_o,
  output logic [AddrWidth-1:0]      loop_jump_addr_o,
  // Asserted when a wrong config is supplied at loop start or end.
  output logic                      sw_err_o,
  // The current state of the loop
  output loop_state_e               loop_state_o,
  output logic                      en_superscalar_o,

  // Asserted if all reservation stations have no instructions in flight.
  input  logic                      all_rs_finish_i,
  output logic                      loop_stall_o
);

  typedef struct packed {
    logic [AddrWidth-1:0] loop_start;
    logic [AddrWidth-1:0] loop_end;
  } loop_addr_info_t;

  typedef struct packed {
    loop_addr_info_t           loop_addr_info;
    logic [MaxIterationsWidth-1:0] loop_iterations;
    loop_state_e  loop_state;
  } loop_info_t;

  loop_info_t                 new_loop;
  logic       [AddrWidth-1:0] new_loop_end_addr;

  logic                      current_loop_finish;

  // Per instruction signal, whether the instruction is unsuported during
  // superscalar execution
  logic [PipeWidth-1:0] is_unsupported_instr;
  logic                 exit_dep;

  assign new_loop_end_addr = AddrWidth'(instr_addr_i) + AddrWidth'({loop_bodysize_i, 2'b00});

  assign new_loop = '{
    loop_addr_info:  '{loop_start: next_instr_addr_i, loop_end: new_loop_end_addr},
    loop_iterations: loop_iterations_i,
    loop_state:      ((frep_mode_i == FrepModeHwLoop)) ?
                      LoopHwLoop : LoopDep
  };

  loop_info_t loop_info_d, loop_info_q, loop_info_reset;
  assign loop_info_reset = '{
    loop_addr_info:  '0,
    loop_iterations: '0,
    loop_state:      LoopRegular
  };
  `FFAR(loop_info_q, loop_info_d, loop_info_reset, clk_i, rst_i);

  logic loop_valid_d, loop_valid_q;
  `FFAR(loop_valid_q, loop_valid_d, '0, clk_i, rst_i);

  logic wait_dep_retirement_d, wait_dep_retirement_q;
  `FFAR(wait_dep_retirement_q, wait_dep_retirement_d, '0, clk_i, rst_i);

  logic wait_hwl_retirement_d, wait_hwl_retirement_q;
  `FFAR(wait_hwl_retirement_q, wait_hwl_retirement_d, '0, clk_i, rst_i);

  logic [MaxIterationsWidth-1:0] total_iterations_q, total_iterations_d;
  `FFAR(total_iterations_q, total_iterations_d, '0, clk_i, rst_i);

  logic [PipeWidth-1:0] at_loop_end_instr;
  logic is_at_loop_end;

  // Check for every instruction if it is at the loop end
  // or if it is an invalid instruction
  always_comb begin : gen_per_instr_info
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      at_loop_end_instr[i] = loop_valid_q                                                       &&
                            (loop_info_q.loop_addr_info.loop_end == (instr_addr_i + (i << 2 ))) &&
                            instr_valid_i[i];

      // All these instructions except for frep are unsuported during superscalar execution
      is_unsupported_instr[i] = (instr_decoded_i[i].fu inside {NONE, MULDIV, CSR, DMA}) &
                                        en_superscalar_o                            &
                                        instr_valid_i[i];
    end
  end

  // Check if loop end instruction is jump or branch
  logic ctrl_at_loop_end;
  assign ctrl_at_loop_end = at_loop_end_instr[blk_ctrl_info_i.instr_idx] &
                          instr_valid_i[blk_ctrl_info_i.instr_idx]       &
                          blk_ctrl_info_i.is_ctrl;

  always_comb begin : gen_valid_mask
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      if (i == 0) begin
        // The first instruction never has to be masked
        // either a younger instruction is the instruction at the loop end
        // or the first instruction is at the loop end
        valid_mask_o[0] = 1'b1;
      end else begin
        // We have to invalidate the valid bit if a previous instruction
        // was the loop end instruction or if it was invalidated
        // or if this instruction is unsupported
        valid_mask_o[i] = valid_mask_o[i-1] & !at_loop_end_instr[i-1] & !is_unsupported_instr[i];
      end
    end
  end

  // We are at the end of the loop if one instruction of the block is at the end
  assign is_at_loop_end = |(at_loop_end_instr & valid_mask_o);

  assign exit_dep = |(is_unsupported_instr & valid_mask_o);

  logic dispatch_loop_end_instr;
  assign dispatch_loop_end_instr = is_at_loop_end && !stall_i;

  assign current_loop_finish = dispatch_loop_end_instr && (loop_info_q.loop_iterations == 1);

  assign loop_jump_addr_o = loop_info_q.loop_addr_info.loop_start;

  logic decrement_loop_iterations;

  always_comb begin
    loop_info_d  = loop_info_q;
    loop_valid_d = loop_valid_q;
    total_iterations_d = total_iterations_q;
    wait_dep_retirement_d = wait_dep_retirement_q;
    wait_hwl_retirement_d = wait_hwl_retirement_q;

    en_superscalar_o          = 1'b0;
    loop_jump_o               = 1'b0;
    decrement_loop_iterations = 1'b0;

    unique case (loop_info_q.loop_state)
      LoopRegular: begin
        if (loop_start_commit_i) begin
          loop_info_d  = new_loop; // jumps to HwLoop or DEP
          loop_valid_d = 1'b1;
          total_iterations_d = loop_iterations_i;
        end
      end
      LoopHwLoop: begin
        // TODO(colluca): I believe here in place of current_loop_finish we should only check that
        //                we are not in the last iteration
        loop_jump_o  = is_at_loop_end && !current_loop_finish;
        if (dispatch_loop_end_instr) begin
          decrement_loop_iterations = 1'b1;
        end

        if (exception_i || current_loop_finish) begin
          loop_valid_d           = 1'b0;
          loop_info_d            = loop_info_reset;
          loop_info_d.loop_state = LoopRegular;
          total_iterations_d     = '0;
        end
      end
      LoopDep: begin
        // We enter superscalar execution
        en_superscalar_o = 1'b1;
        loop_jump_o = is_at_loop_end && !current_loop_finish;
        if (exit_dep || wait_hwl_retirement_q) begin
          // If no RS is busy and we did not dispatch an instruction in this cycle
          // it is save to change to Hardware loop.
          if (all_rs_finish_i && !dispatched_i) begin
            // Change back to hardware loop in the next cycle
            wait_hwl_retirement_d = 1'b0;
            loop_info_d.loop_state = LoopHwLoop;
          end else begin
            wait_hwl_retirement_d = 1'b1;
          end
        end

        if (dispatch_loop_end_instr) begin
          decrement_loop_iterations = 1'b1;
        end

        if (current_loop_finish || exception_i || wait_dep_retirement_q) begin
          // If no RS is busy and we did not dispatch an instruction in this cycle
          // it is save to change to Hardware loop.
          if (all_rs_finish_i && !dispatched_i) begin
            wait_dep_retirement_d  = 1'b0;
            loop_valid_d           = 1'b0;
            loop_info_d            = loop_info_reset;
            loop_info_d.loop_state = LoopRegular;
            total_iterations_d     = '0;
          end else begin
            wait_dep_retirement_d = 1'b1;
          end
        end
      end
      default: ;
    endcase


    if (decrement_loop_iterations) begin
      loop_info_d.loop_iterations = loop_info_d.loop_iterations - 1;
    end
  end

  // We have to stall, whenever we wait for a retirement
  assign loop_stall_o = wait_dep_retirement_q || wait_hwl_retirement_q;

  assign loop_state_o = loop_info_q.loop_state;

  logic loop_iteration_err;
  logic loop_branch_err;
  logic loop_at_end_err;
  assign loop_iteration_err = (loop_iterations_i == '0) && loop_start_req_i;
  // the last instruction of a loop may not be jump as we otherwise cannot return properly
  assign loop_branch_err    = ctrl_at_loop_end;
  assign loop_at_end_err    = at_loop_end_instr && loop_start_req_i;

  assign sw_err_o = loop_iteration_err ||
                    loop_branch_err    ||
                    loop_at_end_err;

endmodule
