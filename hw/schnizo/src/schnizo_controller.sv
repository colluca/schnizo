// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: The Schnizo Controller. It handles the instruction flow and PC update

`include "common_cells/registers.svh"

module schnizo_controller import schnizo_pkg::*; #(
  parameter int unsigned XLEN            = 32,
  parameter logic [31:0] BootAddr        = 32'h0000_1000,
  parameter int unsigned NrIntWritePorts = 1,
  parameter int unsigned NrFpWritePorts  = 1,
  parameter int unsigned RegAddrSize     = 5,
  parameter int unsigned MaxIterationsW  = 6,
  parameter type         instr_dec_t     = logic,
  parameter type         priv_lvl_t      = logic
) (
  input  logic clk_i,
  input  logic rst_i,

  // Frontend interface
  output logic [31:0] pc_o,
  output logic        instr_fetch_valid_o,
  input  logic        flush_i_ready_i,
  output logic        flush_i_valid_o,

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
  input  logic        wfi_i,
  input  logic        barrier_stall_i,
  input  logic        csr_exception_raw_i,
  input  logic [0:0]  lsu_empty_i,
  input  logic        lsu_addr_misaligned_i,
  input  priv_lvl_t   priv_lvl_i,
  input  logic [31:0] mtvec_i,
  input  logic [31:0] mepc_i,
  input  logic [31:0] sepc_i,

  // Branch result
  input  logic           alu_compare_res_i,
  input  logic[XLEN-1:0] alu_result_i,

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
  output logic [XLEN-1:0] consecutive_pc_o,

  // GPR & FPR Write back snooping for Scoreboard
  input  logic                                        gpr_we_i,
  input  logic [NrIntWritePorts-1:0][RegAddrSize-1:0] gpr_waddr_i,
  input  logic                                        fpr_we_i,
  input  logic [NrFpWritePorts-1:0][RegAddrSize-1:0]  fpr_waddr_i
);
  logic            instr_dispatched;
  logic            stall;
  logic            csr_exception;
  logic            exception;
  logic            mret;
  logic            sret;
  logic [XLEN-1:0] consecutive_pc;

  assign exception_o = exception;
  assign stall_o     = stall;
  assign mret_o = mret;
  assign sret_o = sret;

  logic [31:0]     pc_d, pc_q; // PC is fixed to 32 bits in RV32
  `FFAR(pc_q, pc_d, BootAddr, clk_i, rst_i);

  // ---------------------------
  // Check RAW and WAW hazards
  // ---------------------------
  logic operands_ready;
  logic destination_ready;
  logic registers_ready;
  logic fpr_busy;
  logic gpr_busy;

  schnizo_scoreboard #(
    .RegAddrSize(REG_ADDR_SIZE),
    .instr_dec_t(instr_dec_t)
  ) i_schnizo_scoreboard (
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

  // ---------------------------
  // Loop control logic
  // ---------------------------
  logic        loop_start_ready;
  logic        loop_jump;
  logic [31:0] loop_jump_addr;
  logic        loop_stall;
  logic        frep_sw_error;

  // Convert the decoded loop iterations to the actual number of iterations.
  // In Snitch we specify one less in the encoding. The same correction is applied to the
  // max_instr but in the decoder.
  logic [MaxIterationsW-1:0] loop_iterations;
  assign loop_iterations = frep_iterations_i + 1;

  // Convert the loop body size to the actual number of iterations. In Snitch there are
  // frep_bodysize+1 instructions looped. This loop controller uses the actual loop number.
  logic [FREP_BODYSIZE_WIDTH-1:0] loop_bodysize;
  assign loop_bodysize = instr_decoded_i.frep_bodysize + 1;

  schnizo_loop_controller #(
    .AddrWidth     (32),
    .MaxBodysizeW  (FREP_BODYSIZE_WIDTH),
    .MaxIterationsW(MaxIterationsW),
    .instr_dec_t   (instr_dec_t)
  ) i_loop_ctrl (
    .clk_i,
    .rst_i,
    .instr_decoded_i  (instr_decoded_i),
    .instr_valid_i    (instr_valid_i),
    .instr_addr_i     (pc_q),
    // The next instruction after an FREP can only be the immediately next instruction.
    // Hardcode this to avoid a timing loop in case we would use pc_d. Reason is that pc_d depends
    // on the loop_jump signal. TODO: check address overflow..
    .next_instr_addr_i(pc_q + 'd4),
    .stall_i          (stall),
    .exception_i      (exception),
    .rs_full_i        (rs_full_i),
    .all_rs_finish_i  (all_rs_finish_i),

    .loop_start_req_i   (instr_decoded_i.is_frep & instr_valid_i),
    .loop_start_commit_i(instr_decoded_i.is_frep & instr_exec_commit_o),
    // A ready response for the commit to adhere to the ready/valid flow.
    .loop_start_ready_o (loop_start_ready),
    .loop_bodysize_i    (loop_bodysize),
    .loop_iterations_i  (loop_iterations),

    .loop_jump_o     (loop_jump),
    .loop_jump_addr_o(loop_jump_addr),
    .loop_stall_o    (loop_stall),
    .sw_err_o        (frep_sw_error),
    .loop_state_o    (loop_state_o),
    .goto_lcp2_o     (goto_lcp2_o),
    .lep_iterations_o(lep_iterations_o),
    .rs_restart_o    (rs_restart_o)
  );

  // ---------------------------
  // Exceptions
  // ---------------------------
  assign ecall_o  = instr_decoded_i.is_ecall  & instr_valid_i;
  assign ebreak_o = instr_decoded_i.is_ebreak & instr_valid_i;
  assign csr_exception = (instr_decoded_i.fu == CSR) && csr_exception_raw_i && instr_valid_i;

  // Unaligned address check
  assign instr_addr_misaligned_o = (instr_decoded_i.is_branch |
                                    instr_decoded_i.is_jal    |
                                    instr_decoded_i.is_jalr)
                                    && (consecutive_pc[1:0] != 2'b0);

  // Check LSU addresses. This exception may only be raised if the LSU dispatch request is valid.
  // This means the operands must be valid. Otherwise we compute a wrong address and an exception
  // raised. We may NOT use the dispatch valid signal as these exception signals control this
  // signal. This would lead to loops. Therefore, we use the operands_ready signal.
  assign load_addr_misaligned_o  = lsu_addr_misaligned_i && (instr_decoded_i.fu == LOAD) &&
                                   instr_valid_i && operands_ready;
  assign store_addr_misaligned_o = lsu_addr_misaligned_i && (instr_decoded_i.fu == STORE) &&
                                   instr_valid_i && operands_ready;

  // Signal to CSR when entering WFI state.
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
  assign mret = instr_decoded_i.is_mret && instr_valid_i && !privileges_violated;
  assign sret = instr_decoded_i.is_sret && instr_valid_i && !privileges_violated;

  // A privilege violation is handled as illegal instruction
  assign instr_illegal_o = instr_decoded_illegal_i | privileges_violated;

  assign exception = instr_illegal_o
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

  // ---------------------------
  // Stalls
  // ---------------------------
  // Check if we are waiting on a FENCE. We can continue if all LSUs are empty.
  logic all_lsus_empty, fence_stall;
  assign all_lsus_empty = &lsu_empty_i; // TODO: combine all LSUs
  assign fence_stall = (instr_decoded_i.is_fence & ~all_lsus_empty) & instr_valid_i;

  // Check if we are waiting on an instruction cache flush (via FENCE_I instruction).
  // We can continue as soon as the cache responds
  logic fence_i_stall;
  assign flush_i_valid_o = instr_decoded_i.is_fence_i & instr_valid_i;
  assign fence_i_stall = flush_i_valid_o & ~ flush_i_ready_i;

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
  assign fcsr_stall = fpr_busy & gpr_busy & is_fcsr_instr & instr_valid_i;

  // Before starting a FREP loop all writebacks must be completed. Reason is that during FREP the
  // FU writeback is always taken from the RSS and thus any in flight instruction gets stuck.
  logic frep_start_stall;
  assign frep_start_stall = (instr_decoded_i.is_frep & instr_valid_i) ? (fpr_busy | gpr_busy) :
                                                                        1'b0;

  // TODO: Synchronize all LSUs with the Consistency Address Queue (CAQ)

  // ---------------------------
  // Dispatch logic
  // ---------------------------
  // We can dispatch the current instruction if:
  // - it is valid
  // - all registers are ready
  // - no stall due to a FENCE or FCSR
  // - no stall due to the loop controller
  // - no exception occurred
  // - TODO: the Consistency Address Queue (CAQ) between all LSUs are ready
  //
  // Note: the cluster HW barrier only disables fetching new instructions.
  //
  // Request the dispatch of the instruction. This ignores any exceptions. The instruction
  // dispatches if the commit signal is asserted. This commit signal includes the info about
  // any exception. So the dispatch_instr_valid_o signal requests the execution of the instruction
  // from the desired FU. The FU then can rise an exception and the commit signal will prevent
  // any stateful update / blocks the execution.
  logic stall_raw;
  assign stall_raw = fence_stall   |
                     fence_i_stall |
                     fcsr_stall    |
                     loop_stall    |
                     frep_start_stall;

  assign dispatch_instr_valid_o = instr_valid_i   &
                                  registers_ready &
                                  ~stall_raw;

  // The instruction may only execute if there are no errors/exceptions.
  // This signal controls all stateful updates like RF writes or multi-cycle issues.
  logic instr_exec_commit;
  assign instr_exec_commit = dispatch_instr_valid_o & ~exception;
  // During LEP we give up any control over any exception (and also interrupt).
  // We must set the commit signal to 1 for the whole LEP phase to enable the issues.
  // In LCP we must enable the commit when we wait for retirement.
  assign instr_exec_commit_o = (loop_state_o inside {LoopLep}) ? 1'b1 : instr_exec_commit;

  // The instruction is dispatched when the Dispatcher signals that the handshake to the FU is
  // performed successfully. The signal instr_dispatched signals that the current instruction has
  // been dispatched successfully and the scoreboard can update its state.
  assign instr_dispatched = dispatch_instr_valid_o &&
                            instr_exec_commit_o    &&
                            (dispatch_instr_ready_i || loop_start_ready);
  // During LEP the commit signal is always high but we must stall on the loop stall.
  assign stall = ~instr_dispatched;

  // ---------------------------
  // PC update
  // ---------------------------
  // We now have to handle the PC update. In particular, we have to "execute" any branch / jump
  // instruction. Any control flow instruction is performed using an ALU which is designed to be
  // combinatorial only. Thus the result is immediately available.
  //
  // To retire an instruction we must make sure:
  // ## If it is a non control flow instruction and goes to a pipelined FU:
  //   The FU has accepted the instruction. Any congestion on the register update will be
  //   handled by the write back logic as it can stall the FU.
  //   --> When instr_dispatched is asserted we are done and can step to the next instruction.
  //
  // ## If it goes to a single cycle (combinatorial) FU (control and regular instructions):
  //   In this case it is important that we handle the write back and any eventual PC manipulation
  //   in the same cycle we dispatch it. Otherwise we cannot dispatch the instruction anyway as the
  //   FU wont signal ready until the write back is ready to accept the result. This is the case
  //   because the ready signal from a combinatorial FU is directly the ready signal of the write
  //   back stage. As a consequence:
  // !!! The write back stage must be implemented that it always acknowledges a retiring ALU
  // !!! instruction which does not write to any register (branch inst).
  //   The controller now only has to listen to the instr_dispatched signal and compute the new
  //   PC value using the ALU result (value & comparison).
  //   The write back of JAL and JALR is directly handled in the write back part.
  //   To simplify the implementation, the Dispatcher may only dispatch control flow instructions
  //   to one specific ALU.
  //
  // The next PC is selected as either (in priority order, first is most important):
  // - Debug
  // - Exception: go to trap handler
  // - MRET, SRET: go to handlers
  // - Jumped PC: for JAL, JALR we take the ALU result. JALR must have last bit reset
  // - Branched & Consecutive PC: for all regular instructions & branches if taken

  // Program counter
  assign consecutive_pc_o = consecutive_pc;
  assign pc_o             = pc_q;

  // We can merge the consecutive and branched PC computation such that we only have one adder.
  // The consecutive PC is either +4B or + the branch offset.
  // If we have a JAL or JALR, we store the regular consecutive PC (PC+4) in rd.
  assign consecutive_pc = pc_q +
    ((instr_decoded_i.is_branch & alu_compare_res_i) ? instr_decoded_i.imm : 'd4);

  always_comb begin : pc_update
    pc_d = pc_q; // per default stay at current PC

    if (exception) begin
      pc_d = mtvec_i;
    end else if (!stall && !wfi_i && !barrier_stall_i) begin
      // If we don't stall, step the PC unless we are waiting for an event or are stalled by the
      // cluster hw barrier.
      if (mret) begin
        pc_d = mepc_i;
      end else if (sret) begin
        pc_d = sepc_i;
      end else if (instr_decoded_i.is_jal || instr_decoded_i.is_jalr) begin
        // Set to alu result. Clear last bit if JALR
        pc_d = alu_result_i & {{31{1'b1}}, ~instr_decoded_i.is_jalr};
      end else if (loop_jump) begin
        pc_d = loop_jump_addr; // We jump back to the start of the loop
      end else begin
        // The consecutive address covers regular and branch instructions
        pc_d = consecutive_pc;
      end
    end
  end

  // Request the next instruction if we don't stall on WFI or the cluster barrier.
  assign instr_fetch_valid_o = ~barrier_stall_i && ~wfi_i;

endmodule
