// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// The Schnova controller.
//
// The controller handles instruction dependencies, keeping track of busy registers in a
// scoreboard. It controls the program flow by updating the PC and stalling instruction fetch and
// dispatch when necessary, handling exceptions, HW barriers, control flow instructions and HW
// loops.
module schnova_controller import schnizo_pkg::*; #(
  // Enable the superscalar feature
  parameter bit          Xfrep           = 1,
  parameter int unsigned XLEN            = 32,
  parameter int unsigned NrIntWritePorts = 1,
  parameter int unsigned NrFpWritePorts  = 1,
  parameter int unsigned RegAddrSize     = 5,
  // TODO(colluca): explicitly write Width
  parameter int unsigned MaxIterationsW  = 6,
  parameter type         instr_dec_t     = logic,
  parameter type         priv_lvl_t      = logic
) (
  input  logic clk_i,
  input  logic rst_i,

  // Frontend interface
  input  logic [31:0]     pc_i,
  input  logic            flush_i_ready_i,
  output logic            flush_i_valid_o,
  input  logic [XLEN-1:0] consecutive_pc_i,
  output logic            loop_jump_o,
  output logic [31:0]     loop_jump_addr_o,

  // Decoder interface
  input  instr_dec_t instr_decoded_i,
  input  logic       instr_valid_i,
  input  logic       instr_decoded_illegal_i,

  // Special FREP data
  input  logic [MaxIterationsW-1:0] frep_iterations_i,

  // Interface to dispatcher & RS
  output logic                      dispatch_instr_valid_o,
  input  logic                      dispatch_instr_ready_i,
  output logic                      instr_exec_commit_o,
  output logic                      stall_o,
  input  logic                      rs_full_i,
  input  logic                      all_rs_finish_i,
  output logic                      goto_lcp2_o,
  // Number of iterations in LEP. Valid in the last LCP2 cycle (when the last iteration retires).
  output logic [MaxIterationsW-1:0] lep_iterations_o,
  output loop_state_e               loop_state_o,
  output logic                      rs_restart_o,

  // Exception source interface
  input  logic        interrupt_i,
  input  logic        csr_exception_raw_i,
  input  logic [0:0]  lsu_empty_i,
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

  // GPR & FPR Write back snooping for Scoreboard
  input  logic                                        gpr_we_i,
  input  logic [NrIntWritePorts-1:0][RegAddrSize-1:0] gpr_waddr_i,
  input  logic                                        fpr_we_i,
  input  logic [NrFpWritePorts-1:0][RegAddrSize-1:0]  fpr_waddr_i
);

  logic            instr_dispatched;
  logic            csr_exception;

  ////////////////
  // Scoreboard //
  ////////////////

  logic operands_ready;
  logic destination_ready;
  logic registers_ready;
  logic fpr_busy;
  logic gpr_busy;

  schnizo_scoreboard #(
    .RegAddrSize(RegAddrSize),
    .instr_dec_t(instr_dec_t)
  ) i_scoreboard (
    .clk_i,
    .rst_i,
    .instr_dec_i        (instr_decoded_i),
    .operands_ready_o   (operands_ready),
    .destination_ready_o(destination_ready),
    .fpr_busy_o         (fpr_busy),
    .gpr_busy_o         (gpr_busy),
    .dispatched_i       (instr_dispatched),
    // The write back is snooped to place the reservations and
    // enable same cycle WAW conflict detection / resolution
    .write_enable_gpr_i (gpr_we_i),
    .waddr_gpr_i        (gpr_waddr_i),
    .write_enable_fpr_i (fpr_we_i),
    .waddr_fpr_i        (fpr_waddr_i)
  );

  assign registers_ready = operands_ready & destination_ready;

  ////////////////////////
  // Loop control logic //
  ////////////////////////

  logic        loop_start_ready;
  logic        loop_jump;
  logic [31:0] loop_jump_addr;
  logic        loop_stall;
  logic        frep_sw_error;
  logic        goto_hw_loop;

  assign loop_jump_o = loop_jump;
  assign loop_jump_addr_o = loop_jump_addr;

  if (Xfrep) begin : gen_loop_ctrl
    // Convert the decoded loop iterations to the actual number of iterations.
    // In Snitch we specify one less in the encoding.
    logic [MaxIterationsW-1:0] loop_iterations;
    assign loop_iterations = frep_iterations_i + 1;

    // Convert the loop body size to the actual number of iterations.
    // In Snitch we specify one less in the encoding.
    logic [FrepBodySizeWidth-1:0] loop_bodysize;
    assign loop_bodysize = instr_decoded_i.frep_bodysize + 1;

    schnizo_loop_controller #(
      .AddrWidth     (32),
      .MaxBodysizeW  (FrepBodySizeWidth),
      .MaxIterationsW(MaxIterationsW),
      .instr_dec_t   (instr_dec_t)
    ) i_loop_ctrl (
      .clk_i,
      .rst_i,
      .instr_decoded_i  (instr_decoded_i),
      .instr_valid_i    (instr_valid_i),
      .instr_addr_i     (pc_i),
      // The next instruction after an FREP can only be the immediately next instruction.
      // Hardcode this to avoid a timing loop in case we would use pc_d. Reason is that pc_d depends
      // on the loop_jump signal. TODO: check address overflow..
      .next_instr_addr_i(pc_i + 'd4),
      .stall_i          (stall_o),
      .exception_i      (exception_o),
      .rs_full_i        (rs_full_i),
      .all_rs_finish_i  (all_rs_finish_i),

      .loop_start_req_i   (instr_decoded_i.is_frep & instr_valid_i),
      .loop_start_commit_i(instr_decoded_i.is_frep & instr_exec_commit_o),
      // A ready response for the commit to adhere to the ready/valid flow.
      .loop_start_ready_o (loop_start_ready),
      .loop_bodysize_i    (loop_bodysize),
      .loop_iterations_i  (loop_iterations),
      .frep_mode_i        (instr_decoded_i.frep_mode),

      .loop_jump_o     (loop_jump),
      .loop_jump_addr_o(loop_jump_addr),
      .loop_stall_o    (loop_stall),
      .sw_err_o        (frep_sw_error),
      .loop_state_o    (loop_state_o),
      .goto_lcp2_o     (goto_lcp2_o),
      .lep_iterations_o(lep_iterations_o),
      .rs_restart_o    (rs_restart_o),
      .goto_hw_loop_o  (goto_hw_loop)
    );
  end else begin : gen_no_loop_ctrl
    assign loop_start_ready = 1'b0;
    assign loop_jump        = 1'b0;
    assign loop_jump_addr   = '0;
    assign loop_stall       = 1'b0;
    assign frep_sw_error    = 1'b0;
    assign loop_state_o     = LoopRegular;
    assign goto_lcp2_o      = 1'b0;
    assign lep_iterations_o = '0;
    assign rs_restart_o     = 1'b1;
    assign goto_hw_loop     = 1'b0;
  end

  ////////////////
  // Exceptions //
  ////////////////

  assign ecall_o  = instr_decoded_i.is_ecall  && instr_valid_i;
  assign ebreak_o = instr_decoded_i.is_ebreak && instr_valid_i;
  assign csr_exception = (instr_decoded_i.fu == CSR) && csr_exception_raw_i && instr_valid_i;

  // Unaligned address check
  assign instr_addr_misaligned_o = (instr_decoded_i.is_branch ||
                                    instr_decoded_i.is_jal    ||
                                    instr_decoded_i.is_jalr)
                                    && (consecutive_pc_i[1:0] != 2'b0);

  // Check LSU addresses. This exception may only be raised if the LSU dispatch request is valid.
  // This means the operands must be valid. Otherwise we compute a wrong address and an exception
  // raised. We may NOT use the dispatch valid signal as these exception signals control this
  // signal. This would lead to loops. Therefore, we use the operands_ready signal.
  assign load_addr_misaligned_o  = lsu_addr_misaligned_i && (instr_decoded_i.fu == LOAD) &&
                                   instr_valid_i && operands_ready;
  assign store_addr_misaligned_o = lsu_addr_misaligned_i && (instr_decoded_i.fu == STORE) &&
                                   instr_valid_i && operands_ready;

  // Signal to CSR when entering WFI state.
  // TODO(colluca): what to do with debug signal?
  assign enter_wfi_o = instr_decoded_i.is_wfi && instr_valid_i; // && !debug_q;

  // Check privileges for certain instructions
  logic privileges_violated_raw;
  logic privileges_violated;

  always_comb begin : check_privileges
    privileges_violated_raw = 1'b0;
    if (instr_decoded_i.is_wfi) begin
      // WFI is not allowed in U-mode
      if ((priv_lvl_i == PrivLvlU)) begin
        privileges_violated_raw = 1'b1;
      end
    end
    if (instr_decoded_i.is_mret) begin
      if (priv_lvl_i != PrivLvlM) begin
        privileges_violated_raw = 1'b1;
      end
    end
    if (instr_decoded_i.is_sret) begin
      if (!(priv_lvl_i inside {PrivLvlM, PrivLvlS})) begin
        privileges_violated_raw = 1'b1;
      end
    end
  end
  assign privileges_violated = privileges_violated_raw && instr_valid_i;

  // Only update the privilege stack if there is a valid xRET instruction.
  assign mret_o = instr_decoded_i.is_mret && instr_valid_i && !privileges_violated;
  assign sret_o = instr_decoded_i.is_sret && instr_valid_i && !privileges_violated;

  // A privilege violation is handled as illegal instruction
  assign instr_illegal_o = instr_decoded_illegal_i | privileges_violated;

  // TODO(colluca): what to do with TLB signals?
  assign exception_o = instr_illegal_o
                   | ecall_o
                   | ebreak_o
                   | csr_exception
                   | instr_addr_misaligned_o
                   | load_addr_misaligned_o
                   | store_addr_misaligned_o
                   | interrupt_i
                   | frep_sw_error;
                   //  | (dtlb_page_fault & dtlb_trans_valid)
                   //  | (itlb_page_fault & itlb_trans_valid);

  ////////////
  // Stalls //
  ////////////

  // Check if we are waiting on a FENCE. We can continue if all LSUs are empty.
  logic all_lsus_empty, fence_stall;
  assign all_lsus_empty = &lsu_empty_i; // TODO: combine all LSUs
  assign fence_stall = (instr_decoded_i.is_fence & ~all_lsus_empty) & instr_valid_i;

  // Check if we are waiting on an instruction cache flush (via FENCE_I instruction).
  // We can continue as soon as the cache responds
  logic fence_i_stall;
  assign flush_i_valid_o = instr_decoded_i.is_fence_i & instr_valid_i;
  assign fence_i_stall = flush_i_valid_o & ~flush_i_ready_i;

  // Check if the current instruction wants to read or write the FCSR. If so, stall until no FPU
  // instructions are ongoing. This ensures that any FCSR access is ordered.
  logic [11:0] csr_addr;
  logic        is_fcsr_instr;
  logic        fcsr_stall;

  assign csr_addr = instr_decoded_i.imm[11:0];
  assign is_fcsr_instr = (csr_addr inside {riscv_instr::CSR_FFLAGS, riscv_instr::CSR_FRM,
                                           riscv_instr::CSR_FMODE,  riscv_instr::CSR_FCSR})
                         && (instr_decoded_i.fu == CSR);
  // We must stall on both register file scoreboards as certain FPU instructions (FEQ etc.) do also
  // write back into the integer register file.
  // TODO(colluca): we should probably use a separate register in the scoreboard to track if there
  // are any ongoing FPU instructions instead of checking both scoreboards indiscriminately.
  assign fcsr_stall = fpr_busy & gpr_busy & is_fcsr_instr & instr_valid_i;

  // Before starting an FREP loop all writebacks must be completed. Reason is that during FREP the
  // FU writeback is always taken from the RSS and thus any in flight instruction gets stuck.
  logic frep_start_stall;
  assign frep_start_stall = (instr_decoded_i.is_frep & instr_valid_i) ? (fpr_busy | gpr_busy) :
                                                                        1'b0;

  // TODO: Synchronize all LSUs with the Consistency Address Queue (CAQ)

  ////////////////////
  // Dispatch logic //
  ////////////////////

  // We can dispatch the current instruction if:
  // - it is valid
  // - all registers are ready
  // - no stall due to a FENCE or FCSR
  // - no stall due to the loop controller
  // - no exception occurred
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

  logic stall_raw;
  assign stall_raw = fence_stall   ||
                     fence_i_stall ||
                     fcsr_stall    ||
                     loop_stall    ||
                     frep_start_stall;

  assign dispatch_instr_valid_o = instr_valid_i   &&
                                  registers_ready &&
                                  !stall_raw;

  // The instruction may only execute if there are no errors/exceptions.
  // TODO(colluca): clarify "multi-cycle issues" in following comment
  // This signal controls all stateful updates like RF writes or multi-cycle issues.
  logic instr_exec_commit;
  assign instr_exec_commit = dispatch_instr_valid_o && !exception_o && !goto_hw_loop;
  assign instr_exec_commit_o = instr_exec_commit;

  // The instruction is dispatched when the Dispatcher signals that the handshake to the FU is
  // performed successfully. The signal instr_dispatched signals that the current instruction has
  // been dispatched successfully and the scoreboard can update its state.
  assign instr_dispatched = instr_exec_commit_o && (dispatch_instr_ready_i || loop_start_ready);
  // During LEP the commit signal is always high but we must stall on the loop stall.
  assign stall_o = !instr_dispatched;

endmodule
