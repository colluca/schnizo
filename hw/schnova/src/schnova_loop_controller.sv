// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// The Schnizo loop controller.
//
// Manages control flow for sequential HW loop execution, i.e. LCP and naive HW loop modes.
// Superscalar (LEP) mode is handled directly in the reservation stations.
module schnova_loop_controller import schnizo_pkg::*; schnova_pkg::* #(
  parameter int unsigned AddrWidth      = 32,
  parameter int unsigned MaxBodysizeW   = 12,
  parameter int unsigned MaxIterationsW = 6,
  parameter type         instr_dec_t    = logic
) (
  input logic clk_i,
  input logic rst_i,

  // The current instruction state and address. This is snooped to check if we reached the last
  // instruction of the current loop.
  input  instr_dec_t instr_decoded_i,
  input  logic instr_valid_i,
  input  logic [AddrWidth-1:0] instr_addr_i,
  // The instruction address following the current instruction (i.e., the first loop instruction)
  input  logic [AddrWidth-1:0] next_instr_addr_i,
  // If we stall, do not update state / step in loop body.
  input  logic stall_i,
  // If there is an exception abort the loop
  input  logic exception_i,
  // Asserted if all reservation stations have no instructions in flight.
  input  logic all_rs_finish_i,

  // Request a loop start at the current instruction address. Any errors will be checked by the
  // controller which then asserts the commit signal if no errors arose.
  input  logic                      loop_start_req_i,
  input  logic                      loop_start_commit_i,
  output logic                      loop_start_ready_o,
  input  logic [MaxBodysizeW-1:0]   loop_bodysize_i,
  input  logic [MaxIterationsW-1:0] loop_iterations_i,
  input  frep_mode_e                frep_mode_i,
  input  logic                      exit_frep_i,

  // Request to jump to the loop start address
  output logic                      loop_jump_o,
  output logic [AddrWidth-1:0]      loop_jump_addr_o,
  // Asserted when the core should wait for the LCP or LEP to end.
  output logic                      loop_stall_o,
  // Asserted when a wrong config is supplied at loop start or end.
  output logic                      sw_err_o,
  // The current state of the loop
  output schnova_pkg::loop_state_e  loop_state_o,
  output logic                      en_superscalar_o,
  output logic [MaxIterationsW-1:0] loop_iteration_o,
  // Asserted when the last instruction of LCP1 is retiring.
  output logic                      goto_lcp2_o,
  // Number of iterations in LEP. Valid in the last LCP2 cycle (when the last iteration retires).
  output logic [MaxIterationsW-1:0] lep_iterations_o,
  // Asserted when the RS and RSS should reset synchronously.
  output logic                      rs_restart_o,
  // Asserted when slots are full and we need to enter HW mode. This will "kill/delay" the
  // current instruction for the first cycle. The stall signal will stall until all in-flight
  // instructions have finished.
  output logic                      goto_hw_loop_o
);

  typedef struct packed {
    logic [AddrWidth-1:0] loop_start;
    logic [AddrWidth-1:0] loop_end;
  } loop_addr_info_t;

  typedef struct packed {
    loop_addr_info_t           loop_addr_info;
    logic [MaxIterationsW-1:0] loop_iterations;
    schnova_pkg::loop_state_e  loop_state;
  } loop_info_t;

  loop_info_t                 new_loop;
  logic       [AddrWidth-1:0] new_loop_end_addr;

  assign new_loop_end_addr = AddrWidth'(instr_addr_i) + AddrWidth'({loop_bodysize_i, 2'b00});

  // TODO(colluca): adapt the hardcoded 3 here when changing LCP phases
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

  // TODO(colluca): needed only to calculate loop_iteration_o for trace.
  logic [MaxIterationsW-1:0] total_iterations_q, total_iterations_d;
  `FFAR(total_iterations_q, total_iterations_d, '0, clk_i, rst_i);

  logic wait_for_retirement_d, wait_for_retirement_q;
  `FFAR(wait_for_retirement_q, wait_for_retirement_d, '0, clk_i, rst_i);

  logic wait_for_hw_loop_d, wait_for_hw_loop_q;
  `FFAR(wait_for_hw_loop_q, wait_for_hw_loop_d, '0, clk_i, rst_i);

  logic at_loop_end_instr;
  assign at_loop_end_instr =
    loop_valid_q && (loop_info_q.loop_addr_info.loop_end == instr_addr_i) &&
    instr_valid_i;

  logic dispatch_loop_end_instr;
  assign dispatch_loop_end_instr = at_loop_end_instr && !stall_i;

  logic current_loop_finish;
  assign current_loop_finish = dispatch_loop_end_instr && (loop_info_q.loop_iterations == 1);

  assign loop_jump_addr_o = loop_info_q.loop_addr_info.loop_start;

  logic decrement_loop_iterations;

  logic lep_ends;

  assign loop_iteration_o = total_iterations_q - loop_info_q.loop_iterations;

  always_comb begin
    loop_info_d  = loop_info_q;
    loop_valid_d = loop_valid_q;
    total_iterations_d = total_iterations_q;

    loop_start_ready_o        = 1'b0;
    en_superscalar_o          = 1'b0;
    loop_jump_o               = 1'b0;
    decrement_loop_iterations = 1'b0;
    wait_for_retirement_d     = 1'b0;
    loop_stall_o              = 1'b0;
    lep_ends                  = 1'b0;
    wait_for_hw_loop_d        = 1'b0;
    goto_hw_loop_o            = 1'b0;
    // When asserting restart, we must ensure that no instruction is in flight.
    // Otherwise the FU cannot retire the instruction and we create a blockage or write back the
    // wrong value into the RFs. As we only abort when dispatching an instruction in LCP
    // (and we stall) we are safe because there is never an instruction in flight when asserting
    // the restart flag.
    rs_restart_o              = 1'b0;
    goto_lcp2_o               = 1'b0;

    // TODO(colluca): are goto_lcp2 and goto_hw_loop supposed to be mutually exclusive?
    //                If so, add an assertion.
    unique case (loop_info_q.loop_state)
      LoopRegular: begin
        rs_restart_o = 1'b1;
        if (loop_start_commit_i) begin
          loop_info_d  = new_loop; // jumps to HwLoop or DEP
          loop_valid_d = 1'b1;
          total_iterations_d = loop_iterations_i;
          loop_start_ready_o = 1'b1;
        end
      end
      LoopHwLoop: begin
        rs_restart_o = 1'b1; // reset the RS(s) in this cycle
        // TODO(colluca): I believe here in place of current_loop_finish we should only check that
        //                we are not in the last iteration
        loop_jump_o  = at_loop_end_instr && !current_loop_finish;
        if (dispatch_loop_end_instr) begin
          decrement_loop_iterations = 1'b1;
        end
      end
      LoopDep: begin
        // We enter superscalar execution
        en_superscalar_o = 1'b1;
        loop_jump_o = at_loop_end_instr && !current_loop_finish;
        if (exit_frep_i) begin
          goto_hw_loop_o = 1'b1;
          // Change back to hardware loop in the next cycle
          loop_info_d.loop_state = LoopHwLoop;
        end

        if (dispatch_loop_end_instr) begin
          decrement_loop_iterations = 1'b1;
        end
      end
      default: ; // TODO: crash
    endcase

    if (decrement_loop_iterations) begin
      loop_info_d.loop_iterations = loop_info_d.loop_iterations - 1;
    end

    if (current_loop_finish || lep_ends || exception_i) begin
      loop_valid_d           = 1'b0;
      loop_info_d            = loop_info_reset;
      loop_info_d.loop_state = LoopRegular;
      total_iterations_d     = '0;
      // we still must stall for this cycle
    end
  end

  assign loop_state_o = loop_info_q.loop_state;
  // Hack: The RS loads the LEP iter counters during LCP2. However, the correct number
  // is only available in the first LEP cycle. Thus we prematurely decrement it by 1 to account
  // for the LCP2 decrement.
  // This would be the the same as taking the _d value in the last LCP2 cycle. However, this adds
  // timing overhead as the _d value depends on the actual execution of the instruction. Directly
  // computing it is faster.
  assign lep_iterations_o = loop_info_q.loop_iterations - 1;

  logic loop_iteration_err;
  logic loop_branch_err;
  logic loop_at_end_err;
  assign loop_iteration_err = (loop_iterations_i == '0) && loop_start_req_i;
  // the last instruction of a loop may not be jump as we otherwise cannot return properly
  assign loop_branch_err    = at_loop_end_instr && jump_or_branch;
  assign loop_at_end_err    = at_loop_end_instr && loop_start_req_i;

  assign sw_err_o = loop_iteration_err ||
                    loop_branch_err    ||
                    loop_at_end_err;

endmodule
