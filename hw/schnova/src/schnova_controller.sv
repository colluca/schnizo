// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// The Schnova controller.
//
// The controller handles instruction dependencies, keeping track of busy registers in a
// scoreboard. It controls the program flow by updating the PC and stalling instruction fetch and
// dispatch when necessary, handling exceptions, HW barriers, control flow instructions.
module schnova_controller import schnizo_pkg::*; #(
  parameter int unsigned PipeWidth       = 1,
  parameter int unsigned XLEN            = 32,
  parameter int unsigned NrIntWritePorts = 1,
  parameter int unsigned NrFpWritePorts  = 1,
  parameter int unsigned RegAddrSize     = 5,
  parameter type         instr_dec_t     = logic,
  parameter type         block_ctrl_info_t = logic,
  parameter type         priv_lvl_t      = logic
) (
  input  logic clk_i,
  input  logic rst_i,

  // Frontend interface
  input  logic            flush_i_ready_i,
  output logic            flush_i_valid_o,
  input  logic [XLEN-1:0] consecutive_pc_i,

  // Decoder interface
  input  instr_dec_t [PipeWidth-1:0] instr_decoded_i,
  input  logic       [PipeWidth-1:0] instr_valid_i,
  input  logic       [PipeWidth-1:0] instr_decoded_illegal_i,
  input  block_ctrl_info_t           blk_ctrl_info_i,
  // To backend
  output logic                      flush_backend_o,
  output logic                      all_instr_dispatched_o,
  // Writeback interface
  input logic ctrl_instr_retired_i,
  // Interface to dispatcher & RS
  output logic [PipeWidth-1:0]      dispatch_instr_valid_o,
  input  logic [PipeWidth-1:0]      dispatch_instr_ready_i,
  output logic [PipeWidth-1:0]      instr_exec_commit_o,
  output logic                      stall_o,
  output logic                      ctrl_stall_o,
   // Asserted if all reservation stations have no instructions in flight.
  input  logic all_rs_finish_i,
  output logic rs_restart_o,

  // Exception source interface
  input  logic        interrupt_i,
  input  logic        csr_exception_raw_i,
  input  logic        lsu_empty_i,
  input  logic        load_inflight_i,
  input  logic        store_inflight_i,
  input  logic        lsu_addr_misaligned_i,
  input  priv_lvl_t   priv_lvl_i,

  // Interface to CSR & write back for handling an exception
  output logic            exception_o,
  output logic            instr_illegal_o,
  output logic            instr_addr_misaligned_o,
  output logic [0:0]      load_addr_misaligned_o,
  output logic [0:0]      store_addr_misaligned_o,
  output logic            enter_wfi_o,
  output logic            ecall_o,
  output logic            ebreak_o,
  output logic            mret_o,
  output logic            sret_o,

  // Superscalar features enabled
  output logic en_superscalar_o,

  // From scoreboard
  input logic             registers_ready_i,
  input logic             sb_busy_i
);

  logic [PipeWidth-1:0] instr_dispatched;
  logic            csr_exception;

  logic en_superscalar_d, en_superscalar_q;
  // Per default the core starts in scalar mode
  `FFAR(en_superscalar_q, en_superscalar_d, 1'b0, clk_i, rst_i);

  ////////////////
  // Exceptions //
  ////////////////
  // Per instruction exception
  logic [PipeWidth-1:0] ecall_ex;
  logic [PipeWidth-1:0] ebreak_ex;
  logic [PipeWidth-1:0] csr_ex;
  logic [PipeWidth-1:0] instr_addr_misaligned_ex;
  logic [PipeWidth-1:0] enter_wfi;
  logic [PipeWidth-1:0] privileges_violated_raw;
  logic [PipeWidth-1:0] privileges_violated;
  logic [PipeWidth-1:0] mret;
  logic [PipeWidth-1:0] sret;

  for (genvar instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin: gen_per_instr_exception
    assign ecall_ex[instr_idx]  = instr_decoded_i[instr_idx].is_ecall  && instr_valid_i[instr_idx];
    assign ebreak_ex[instr_idx] = instr_decoded_i[instr_idx].is_ebreak && instr_valid_i[instr_idx];
    // TODO(soderma): Assumes csr instruction will be done in 1 cycle
    assign csr_ex[instr_idx] =  (instr_decoded_i[instr_idx].fu == CSR) &&
                                csr_exception_raw_i                    &&
                                instr_valid_i[instr_idx];
    // Unaligned address check
    assign instr_addr_misaligned_ex[instr_idx] = (instr_decoded_i[instr_idx].is_branch ||
                                    instr_decoded_i[instr_idx].is_jal            ||
                                    instr_decoded_i[instr_idx].is_jalr)          &&
                                    (consecutive_pc_i[1:0] != 2'b0);
    // Signal to CSR when entering WFI state.
    // TODO(colluca): what to do with debug signal?
    // TODO(soderma): WFI not allowed in superscalar mode at this point. Because to be correct,
    // we would have to disable all other instructions.
    assign enter_wfi[instr_idx] = instr_decoded_i[instr_idx].is_wfi && instr_valid_i[instr_idx];
    // && !debug_q;
    // Check privileges for certain instructions
    always_comb begin : check_privileges
      privileges_violated_raw[instr_idx] = 1'b0;
      if (instr_decoded_i[instr_idx].is_wfi) begin
        // WFI is not allowed in U-mode
        if ((priv_lvl_i == PrivLvlU)) begin
          privileges_violated_raw[instr_idx] = 1'b1;
        end
      end
      if (instr_decoded_i[instr_idx].is_mret) begin
        if (priv_lvl_i != PrivLvlM) begin
          privileges_violated_raw[instr_idx] = 1'b1;
        end
      end
      if (instr_decoded_i[instr_idx].is_sret) begin
        if (!(priv_lvl_i inside {PrivLvlM, PrivLvlS})) begin
          privileges_violated_raw[instr_idx] = 1'b1;
        end
      end
    end
    assign privileges_violated[instr_idx] = privileges_violated_raw[instr_idx] &&
                                            instr_valid_i[instr_idx];
    // Only update the privilege stack if there is a valid xRET instruction.
    assign mret[instr_idx] =  instr_decoded_i[instr_idx].is_mret &&
                              instr_valid_i[instr_idx]           &&
                              !privileges_violated[instr_idx];
    assign sret[instr_idx] =  instr_decoded_i[instr_idx].is_sret &&
                              instr_valid_i[instr_idx]           &&
                              !privileges_violated[instr_idx];
  end
  // We have an exception if one of the instructions in the block had an exception
  assign ecall_o  = |ecall_ex;
  assign ebreak_o = |ebreak_ex;
  assign csr_exception = |csr_ex;
  assign instr_addr_misaligned_o = |instr_addr_misaligned_ex;
  // Load and store address are missaligned if LSU assert address misaligned
  // and a load/store operation is currently being processed.
  // TODO: Act correctly on an exception, maybe we can do this similar to schnizo now with our scalar mode.
  assign load_addr_misaligned_o  = lsu_addr_misaligned_i & load_inflight_i;
  assign store_addr_misaligned_o = lsu_addr_misaligned_i & store_inflight_i;
  assign enter_wfi_o = |enter_wfi;
  // xRET instructions are control instructions, there can only be one valid control intstruction per fetch packet.
  // Therefore we can tell the frontend there is a valid xRET instruction of one of the instructions was a valid xRET
  // instruction
  assign mret_o = |mret;
  assign sret_o = |sret;

  // A privilege violation is handled as illegal instruction
  // This is done at a instruction block granularity, we throw an exception
  // if one of the instructions of the block was illegal
  assign instr_illegal_o = (|instr_decoded_illegal_i) | (|privileges_violated);

  // TODO(colluca): what to do with TLB signals?
  assign exception_o = instr_illegal_o
                   | ecall_o
                   | ebreak_o
                   | csr_exception
                   | instr_addr_misaligned_o
                   | load_addr_misaligned_o
                   | store_addr_misaligned_o
                   | interrupt_i;
                   //  | (dtlb_page_fault & dtlb_trans_valid)
                   //  | (itlb_page_fault & itlb_trans_valid);
  // In case of an exception we flush the entire backend
  // TODO(sorderma): When to restart controllably
  assign flush_backend_o = exception_o;
  assign rs_restart_o = exception_o || !en_superscalar_q;

  ////////////
  // Stalls //
  ////////////

  // Check if we are waiting on a FENCE. We can continue if all LSUs are empty.
  logic all_lsus_empty;
  logic [PipeWidth-1:0] fence_stall;
  // The lsu_empty_i signal already declares whether all LSUs are empty
  assign all_lsus_empty = lsu_empty_i;
  for (genvar instr_idx =0; instr_idx < PipeWidth; instr_idx++) begin: gen_fence_stall
    if (instr_idx == 0) begin: gen_fence_stall
      // We stall if the instruction is a fence, and not all LSU are empty and it was not
      // yet dispatched. If it was dispatched, it can be that there still is some fence instruction
      // in the same fetch block.
      assign fence_stall[instr_idx] = (instr_decoded_i[instr_idx].is_fence &
                                      ~all_lsus_empty                      &
                                      ~instr_dispatched[instr_idx])        &
                                      instr_valid_i[instr_idx];
    end else begin: gen_propagate_fence_stall
      // If a previous instruction is a fence, we also have to stall the current instruction
      // if it is valid
      assign fence_stall[instr_idx] = ((instr_decoded_i[instr_idx].is_fence &
                                      ~all_lsus_empty                       &
                                      ~instr_dispatched[instr_idx])         |
                                      fence_stall[instr_idx-1])             &
                                      instr_valid_i[instr_idx];
    end
  end

  // If we observe a CSR instruction, all younger instructions
  // can only start executing once the CSR instruction was commited.
  logic [PipeWidth-1:0] csr_stall;
  for (genvar instr_idx =0; instr_idx < PipeWidth; instr_idx++) begin: gen_csr_stall
    if (instr_idx == 0) begin: gen_no_csr_stall
      // We have to stall the first instruction
      // if it is a CSR instruction and was not yet dispatched
      // and all older instruction have not yet finished their execution.
      assign csr_stall[instr_idx] = (instr_decoded_i[instr_idx].fu == CSR) &
                                    ~instr_dispatched[instr_idx]           &
                                    sb_busy_i                              &
                                    instr_valid_i[instr_idx];
    end else begin: gen_propagate_csr_stall
      // We have to stall all other instructions on the same conditions, in addition
      // if in this cycle a previous instruction was stalled because of a CSR stall
      // all younger instructions also have to be stalled
      assign csr_stall[instr_idx] = (((instr_decoded_i[instr_idx].fu == CSR) &
                                    ~instr_dispatched[instr_idx]             &
                                    sb_busy_i                              ) |
                                    csr_stall[instr_idx-1])                  &
                                    instr_valid_i[instr_idx];
    end
  end

  // Check if we are waiting on an instruction cache flush (via FENCE_I instruction).
  // Discard all the instructions after the fence_i instruction and update the PC to point
  // to the next instruction after the FENCE_I. Then only fetch that once all the instructions
  // before the FENCE_I are retired.
  // This is already done by invalidating all the instructions after the fence_i instruction.
  logic fence_i_stall;
  // We flush once we have one valid fence_i instruction in the block
  assign flush_i_valid_o = blk_ctrl_info_i.is_fence_i;
  // We stall fetching until the flush was performed
  assign fence_i_stall = flush_i_valid_o & ~flush_i_ready_i;

  // Check if we are waiting on a control instruction (branch/jal/mret/sret/jalr)
  logic ctrl_stall;
  typedef enum logic {
    IDLE,
    WAIT_CTRL
  } ctrl_state_t;

  ctrl_state_t ctrl_state_q, ctrl_state_d;
  logic stall_disp_ctrl;

  `FFAR(ctrl_state_q, ctrl_state_d, IDLE, clk_i, rst_i);

  always_comb begin : ctrl_next_state_logic
    ctrl_state_d = ctrl_state_q;
    unique case (ctrl_state_q)
      IDLE: begin
        // If we have a ctrl instruction which is not retired this same cycle
        // we have to wait for it to retire and stall the pipeline.
        if (blk_ctrl_info_i.is_ctrl && !ctrl_instr_retired_i) begin
          ctrl_state_d = WAIT_CTRL;
        end
      end
      WAIT_CTRL: begin
        // As soon as we retire the control instruction we go back to idle
        if(ctrl_instr_retired_i) begin
          ctrl_state_d = IDLE;
        end
      end
    endcase
  end

  // We stall depending on a mealy fsm
  always_comb begin : ctrl_stall_handler
    ctrl_stall = 1'b0;
    if(ctrl_state_q == IDLE) begin
      if (blk_ctrl_info_i.is_ctrl && !ctrl_instr_retired_i) begin
        ctrl_stall = 1'b1;
      end
    end else if(ctrl_state_q == WAIT_CTRL) begin
      ctrl_stall = 1'b1;
      if (ctrl_instr_retired_i) begin
        ctrl_stall = 1'b0;
      end
    end
  end

  assign ctrl_stall_o = ctrl_stall;

  assign stall_disp_ctrl = (ctrl_state_q == WAIT_CTRL) ? 1'b1 : 1'b0;

  // Check if there is any valid instruction in the block in the first place, otherwise we are still waiting
  // on the fetch to return valid instructions for the current PC
  logic all_instr_invalid;
  assign all_instr_invalid = ~(|instr_valid_i);

  // TODO: Synchronize all LSUs with the Consistency Address Queue (CAQ)

  ////////////////////
  // Dispatch logic //
  ////////////////////

  // We can dispatch the current instruction if:
  // - it is valid
  // - no stall due to a FENCE or CSR
  // - TODO: the Consistency Address Queue (CAQ) between all LSUs are ready
  //
  // TODO(colluca): is this the case also in Snitch?
  // Note: the cluster HW barrier only disables fetching new instructions.
  //
  // Request the dispatch of the instruction. This ignores any exceptions. The instruction
  // dispatches if the commit signal is asserted. This commit signal includes the info about
  // any exception. So the dispatch_instr_valid_o signal requests the execution of the instruction
  // from the desired FU. The FU then can raise an exception and the commit signal will prevent
  // any stateful update / blocks the execution.

  logic [PipeWidth-1:0] stall_raw;
  logic [PipeWidth-1:0] instr_dispatched_mask;

  for (genvar instr_idx =0; instr_idx < PipeWidth; instr_idx++) begin: gen_dispatch_sig
    assign stall_raw[instr_idx] =   fence_stall[instr_idx]   |
                                    csr_stall[instr_idx];
    assign dispatch_instr_valid_o[instr_idx] =  instr_valid_i[instr_idx]                &
    // If we are in scalar mode, we can't dispatch instructions when not all registers are ready
                                                registers_ready_i &
    // If we are in superscalar mode, we have to invalidate the dispatch request when we are waiting
    // on the control instruction to  finish, otherwise it would generate another dispatch request
    // for the same instruction since the RS is build in a fire and forget manner.
                                                (!en_superscalar_q || !stall_disp_ctrl) &
                                                !stall_raw[instr_idx];
    // The instruction may only execute if there are no errors/exceptions.
    // TODO(colluca): clarify "multi-cycle issues" in following comment
    // This signal controls all stateful updates like RF writes or multi-cycle issues.
    assign instr_exec_commit_o[instr_idx] = dispatch_instr_valid_o[instr_idx] & !exception_o;
    // The instruction is dispatched when the Dispatcher signals that the handshake to the FU is
    // performed successfully. The signal instr_dispatched signals that the current instruction has
    // been dispatched successfully and the scoreboard can update its state.
    assign instr_dispatched[instr_idx] =  instr_exec_commit_o[instr_idx] &
                                          dispatch_instr_ready_i[instr_idx];
  end

  // Stall fetching new instructions when we have
  // to stall because of a FENCE_I instruction
  // have to wait until a branch/jump is resolved
  // not all the instructions that were valid
  // were yet dispatched

  for (genvar instr_idx =0; instr_idx < PipeWidth; instr_idx++) begin: gen_instr_disp_mask
    // If the instruction was not valid, we don't have to dispatch it in the first place
    // in that case we treat it as if it successfully dispatched
    assign instr_dispatched_mask[instr_idx] = (instr_valid_i[instr_idx])  ?
                                              instr_dispatched[instr_idx] :
                                              1'b1;
  end
  // We have to tell the renaming stage when all instructions are successfully dispatched
  // that way it can restart the renaming process
  assign all_instr_dispatched_o = &instr_dispatched_mask;

  assign stall_o =  fence_i_stall |
                    all_instr_invalid |
                    ~all_instr_dispatched_o;

//////////////////////////////
// Superscalar enable logic //
//////////////////////////////

logic [PipeWidth-1:0] is_valid_frep_instr;

always_comb begin
  en_superscalar_d = en_superscalar_q;

  for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
    is_valid_frep_instr[instr_idx] = instr_decoded_i[instr_idx].is_frep & instr_valid_i[instr_idx];
  end

  // We toggle the mode whenever a valid frep instruction was decoded
  if (|is_valid_frep_instr) begin
    en_superscalar_d = ~en_superscalar_q;
  end
end

assign en_superscalar_o = en_superscalar_q;
endmodule
