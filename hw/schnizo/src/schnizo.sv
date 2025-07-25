// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: Top-Level of the Schnizo Core.
// The Schnizo core is basically a Snitch which got schizophrenia.
// As of this, it now features a superscalar loop execution.
// This core implements the following RISC-V extensions: IMAFD (A ignoring aq and lr flags)

// Limitation:
// - The scoreboard assumes that only multi cycle functional units write to the floating point
//   register file!
// - when reaching the end of a program, we somehow have to make sure that all instructions
//   have committed before the core gets stopped.

// Use automatic retiming options in the synthesis tool to optimize the fpnew design.

// TODO
// - LSU CAQ
// - Performance counters
// - Debug support -> not required
// - check all todos

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

module schnizo import schnizo_pkg::*; #(
  /// Boot address of core.
  parameter logic [31:0] BootAddr  = 32'h0000_1000,
  /// Physical Address width of the core.
  parameter int unsigned AddrWidth = 48,
  /// Data width of memory interface.
  parameter int unsigned DataWidth = 64,
  /// Enable Snitch DMA as accelerator.
  parameter bit          Xdma      = 0,
  /// Enable FP in general
  parameter bit          FP_EN     = 0,
  /// Enable F Extension.
  parameter bit          RVF       = 0,
  /// Enable D Extension.
  parameter bit          RVD       = 0,
  parameter bit          XF16      = 0,
  parameter bit          XF16ALT   = 0,
  parameter bit          XF8       = 0,
  parameter bit          XF8ALT    = 0,
  parameter bit          XFVEC     = 0,
  int unsigned           FLEN      = DataWidth,
  /// Data port request type.
  parameter type         dreq_t = logic,
  /// Data port response type.
  parameter type         drsp_t = logic,
  /// Accelerator interface types
  parameter type         acc_req_t  = logic,
  parameter type         acc_resp_t = logic,
  /// How many issued loads the LSU and thus the CAQ (consistency address queue) can hold.
  // This applies to all LSUs (each LSU can handle NumOutstandingLoads loads).
  parameter int unsigned NumOutstandingLoads = 0,
  /// How many total transactions (load and store) the LSU can handle at once
  // This applies to all LSUs (each LSU can handle NumOutstandingMem transactions).
  parameter int unsigned NumOutstandingMem = 0,
  // Physical memory attributes
  parameter snitch_pma_pkg::snitch_pma_t SnitchPMACfg = '{default: 0},
  /// Consistency Address Queue (CAQ) parameters
  parameter int unsigned CaqDepth    = 0,
  parameter int unsigned CaqTagWidth = 0,
  /// Enable debug support.
  parameter bit DebugSupport = 0,
  /// FPU definitions
  parameter fpnew_pkg::fpu_implementation_t FPUImplementation = '0,
  /// Register the signals directly before the FPnew instance
  parameter bit RegisterFPUIn  = 0,
  /// Register the signals directly after the FPnew instance
  parameter bit RegisterFPUOut = 0,
  /// Derived parameter *Do not override*
  parameter type addr_t = logic [AddrWidth-1:0],
  parameter type data_t = logic [DataWidth-1:0]
) (
  input  logic          clk_i,
  input  logic          rst_i,
  input  logic [31:0]   hart_id_i,
  /// Interrupts
  input  interrupts_t   irq_i,
  /// Instruction cache flush request
  output logic          flush_i_valid_o,
  /// Flush has completed when the signal goes to `1`.
  /// Tie to `1` if unused
  input  logic          flush_i_ready_i,
  // Instruction Refill Port
  output addr_t         inst_addr_o,
  output logic          inst_cacheable_o,
  input  logic [31:0]   inst_data_i,
  output logic          inst_valid_o,
  input  logic          inst_ready_i,
  /// Accelerator Interface - Master Port
  /// Independent channels for transaction request and read completion.
  /// AXI-like handshaking.
  /// Same IDs need to be handled in-order.
  output acc_req_t      acc_qreq_o,
  output logic          acc_qvalid_o,
  input  logic          acc_qready_i,
  input  acc_resp_t     acc_prsp_i,
  input  logic          acc_pvalid_i,
  output logic          acc_pready_o,
  /// TCDM Data Interface
  /// Write transactions do not return data on the `P Channel`
  /// Transactions need to be handled strictly in-order.
  output dreq_t         data_req_o,
  input  drsp_t         data_rsp_i,
  // Core events for performance counters
  output snitch_pkg::core_events_t core_events_o,
  // Cluster HW barrier
  output logic          barrier_o,
  input  logic          barrier_i
);
  // Clarify signal names of the instruction fetch interface without changing the interface.
  // This way we can simply replace the snitch core with the schnizo core.
  addr_t         instr_fetch_addr_o;
  logic          instr_fetch_cacheable_o;
  logic [31:0]   instr_fetch_data_i;
  logic          instr_fetch_valid_o;
  logic          instr_fetch_ready_i;
  assign inst_addr_o = instr_fetch_addr_o;
  assign inst_cacheable_o = instr_fetch_cacheable_o;
  assign instr_fetch_data_i = inst_data_i;
  assign inst_valid_o = instr_fetch_valid_o;
  assign instr_fetch_ready_i = inst_ready_i;

  localparam int unsigned XLEN = 32;
  // localparam int unsigned FLEN = DataWidth;
  localparam int unsigned NrIntReadPorts = 2;
  localparam int unsigned NrIntWritePorts = 1;
  localparam int unsigned NrFpReadPorts = 3;
  localparam int unsigned NrFpWritePorts = 1;
  localparam int unsigned ProdAddrSize = 5;

  // The bit width of an operand. This is simply the maximal bit width such that we can have a
  // common data type for all FUs.
  localparam int OpLen = (FLEN > XLEN) ? FLEN : XLEN;

  // Decoded instruction for dispatcher
  typedef struct packed {
    fu_t                      fu;
    alu_op_e                  alu_op;
    lsu_op_e                  lsu_op;
    csr_op_e                  csr_op;
    fpu_op_e                  fpu_op;
    // rd and rs_is_fp must be set to all zero to encoded that there is
    // no write back for this instruction.
    logic [REG_ADDR_SIZE-1:0] rd;
    logic                     rd_is_fp; // set if rd is a FP register
    logic [REG_ADDR_SIZE-1:0] rs1;
    logic                     rs1_is_fp; // set if rs1 is a FP register
    logic [REG_ADDR_SIZE-1:0] rs2;
    logic                     rs2_is_fp; // set if rs2 is a FP register
    // Imm field: for unfinished floating-point fused operations (FMADD, FMSUB, FNMADD, FNMSUB)
    // this field holds the address of the third operand (rs3) from the floating-point regfile
    logic [XLEN-1:0]          imm;
    logic                     use_imm_as_rs3; // set if rs3 is a FP register
    lsu_size_e                lsu_size; // The bit width the LSU operates on
    fpnew_pkg::fp_format_e    fpu_fmt_src; // The FPU format field.
    fpnew_pkg::fp_format_e    fpu_fmt_dst; // The FPU format field.
    // The round mode for the FPU. If DYN was specified, it contains the value from the CSR.
    fpnew_pkg::roundmode_e    fpu_rnd_mode;
    logic                     use_imm_as_op_b; // set if we need to use the immediate as ALU op b
    logic                     use_pc_as_op_a; // set if we need to use the PC as ALU operand a
    logic                     use_rs1addr_as_op_a; // set if CSR instruction uses rs1 address
    logic                     is_branch; // set if instruction is a branch
    logic                     is_jal; // set if JAL
    logic                     is_jalr; // set if JALR
    logic                     is_fence; // set if FENCE
    logic                     is_ecall;
    logic                     is_ebreak;
    logic                     is_mret;
    logic                     is_sret;
    logic                     is_wfi;
  } instr_dec_t;

  // !! The OpLen parameters are not always sign extended by the read_operands module !!
  // Only consume the expected bits.
  typedef struct packed {
    fu_t                   fu;
    alu_op_e               alu_op;
    lsu_op_e               lsu_op;
    csr_op_e               csr_op;
    fpu_op_e               fpu_op;
    logic [OpLen-1:0]      operand_a;
    logic [OpLen-1:0]      operand_b;
    // Imm field: for floating-point fused operations (FMADD, FMSUB, FNMADD, FNMSUB)
    // this field holds the value of the third operand
    logic [OpLen-1:0]      imm;
    lsu_size_e             lsu_size;
    fpnew_pkg::fp_format_e fpu_fmt_src;
    fpnew_pkg::fp_format_e fpu_fmt_dst;
    fpnew_pkg::roundmode_e fpu_rnd_mode;
  } fu_data_t;

  typedef struct packed {
    logic [REG_ADDR_SIZE-1:0] dest_reg;
    logic                     dest_reg_is_fp;
    logic                     is_branch;
    logic                     is_jump;
  } instr_tag_t;

  typedef struct packed {
    logic [ProdAddrSize-1:0] prod_id;
    logic                    is_produced; // set if prod_id is a valid mapping
  } rmt_entry_t;

  typedef struct packed {
    fu_data_t   fu_data;
    rmt_entry_t producer_op_a;
    rmt_entry_t producer_op_b;
    rmt_entry_t producer_op_c;
    rmt_entry_t current_producer_dest;
    instr_tag_t tag;
  } disp_req_t;

  typedef struct packed {
    logic [ProdAddrSize-1:0] prod_id;
  } disp_res_t;

  typedef struct packed {
    logic [XLEN-1:0] result;
    logic            compare_res;
  } alu_result_t;

  logic [NrIntReadPorts-1:0][REG_ADDR_SIZE-1:0]  gpr_raddr;
  logic [NrIntReadPorts-1:0][XLEN-1:0]           gpr_rdata;
  logic [NrIntWritePorts-1:0][REG_ADDR_SIZE-1:0] gpr_waddr;
  logic [NrIntWritePorts-1:0][XLEN-1:0]          gpr_wdata;
  logic [NrIntWritePorts-1:0]                    gpr_we;

  logic [NrFpReadPorts-1:0][REG_ADDR_SIZE-1:0]  fpr_raddr;
  logic [NrFpReadPorts-1:0][FLEN-1:0]           fpr_rdata;
  logic [NrFpWritePorts-1:0][REG_ADDR_SIZE-1:0] fpr_waddr;
  logic [NrFpWritePorts-1:0][FLEN-1:0]          fpr_wdata;
  logic [NrFpWritePorts-1:0]                    fpr_we;

  logic            instr_valid;
  logic            instr_decoded_illegal;
  logic            instr_illegal;
  logic            stall;
  logic            ecall;
  logic            ebreak;
  logic            mret;
  logic            sret;
  logic            csr_exception_raw;
  logic            csr_exception;
  logic            barrier_stall;
  logic            instr_addr_misaligned;
  logic            lsu_addr_misaligned;
  logic [0:0]      load_addr_misaligned;
  logic [0:0]      store_addr_misaligned;
  priv_lvl_t       priv_lvl;
  logic            privileges_violated_raw;
  logic            privileges_violated;
  logic            interrupt;
  logic            exception;
  logic            wfi; // asserted if we are waiting for an interrupt
  logic            dispatch_instr_valid;
  logic            dispatch_instr_ready;
  logic            instr_dispatched;
  logic [XLEN-1:0] consecutive_pc;
  logic[31:0]      mtvec;
  logic[31:0]      mepc;
  logic[31:0]      sepc;

  fpnew_pkg::roundmode_e fpu_rnd_mode;
  fpnew_pkg::fmt_mode_t  fpu_fmt_mode;
  instr_dec_t instr_decoded;

  alu_result_t alu_result;
  instr_tag_t  alu_result_tag;
  logic        lsu_empty;
  fpnew_pkg::status_t fpu_status;
  logic               fpu_status_valid;

  // ---------------------------
  // Snitch related unused signals
  // ---------------------------
  // tie down unused signals
  assign acc_qreq_o = '0; // we don't use the accelerator interface
  assign acc_qvalid_o = '0;
  assign acc_pready_o = '0;
  assign core_events_o = '0;
  assign flush_i_valid_o = 1'b0;

  // ---------------------------
  // Instruction fetch
  // ---------------------------
  // Program counter
  logic [31:0] pc_d, pc_q; // PC is fixed to 32 bits in RV32
  `FFAR(pc_q, pc_d, BootAddr, clk_i, rst_i)

  // request the instruction at the current PC
  assign instr_fetch_addr_o = {{{AddrWidth-32}{1'b0}}, pc_q};
  assign instr_fetch_cacheable_o =
    snitch_pma_pkg::is_inside_cacheable_regions(SnitchPMACfg, instr_fetch_addr_o);
  // Request the next instruction if we dont stall on WFI or the cluster barrier.
  assign instr_fetch_valid_o = ~barrier_stall && ~wfi;

  logic instr_fetch_data_valid;
  assign instr_fetch_data_valid = instr_fetch_valid_o & instr_fetch_ready_i;

  // ---------------------------
  // Decoder
  // ---------------------------
  schnizo_decoder #(
    .XLEN   (XLEN),
    .Xdma   (Xdma),
    .RVF    (RVF),
    .RVD    (RVD),
    .XF16   (XF16),
    .XF16ALT(XF16ALT),
    .XF8    (XF8),
    .XF8ALT (XF8ALT),
    .instr_dec_t(instr_dec_t)
  ) i_schnizo_decoder (
    .clk_i,
    .rst_i,
    .instr_fetch_data_i      (instr_fetch_data_i),
    .instr_fetch_data_valid_i(instr_fetch_data_valid),
    .fpu_round_mode_i        (fpu_rnd_mode),
    .fpu_fmt_mode_i          (fpu_fmt_mode),
    .instr_valid_o           (instr_valid),
    .instr_illegal_o         (instr_decoded_illegal),
    .instr_dec_o             (instr_decoded)
  );

  // ---------------------------
  // Controller
  // ---------------------------
  // Check RAW and WAW hazards
  logic operands_ready;
  logic destination_ready;
  logic registers_ready;

  schnizo_scoreboard #(
    .RegAddrSize(REG_ADDR_SIZE),
    .instr_dec_t(instr_dec_t)
  ) i_schnizo_scoreboard (
    .clk_i,
    .rst_i,
    .instr_dec_i        (instr_decoded),
    .operands_ready_o   (operands_ready),
    .destination_ready_o(destination_ready),
    .dispatched_i       (instr_dispatched),
    // The write back is snooped to place the reservations and
    // enable same cycle WAW conflict detection / resolution
    .write_enable_gpr_i (gpr_we),
    .waddr_gpr_i        (gpr_waddr),
    .write_enable_fpr_i (fpr_we),
    .waddr_fpr_i        (fpr_waddr)
  );
  assign registers_ready = operands_ready & destination_ready;

  // Check if any exception occurred
  assign ecall = instr_decoded.is_ecall & instr_valid;
  assign ebreak = instr_decoded.is_ebreak & instr_valid;
  assign csr_exception = (instr_decoded.fu == CSR) && csr_exception_raw && instr_valid;

  // Unaligned address check
  assign instr_addr_misaligned = (instr_decoded.is_branch |
                                 instr_decoded.is_jal    |
                                 instr_decoded.is_jalr)
                                && (consecutive_pc[1:0] != 2'b0);

  // Check LSU addresses. This exception may only be raised if the LSU dispatch request is valid.
  // This means the operands must be valid. Otherwise we compute a wrong address and an exception
  // raised. We may NOT use the dispatch valid signal as these exception signals control this
  // signal. This would lead to loops. Therefore, we use the operands_ready signal.
  assign load_addr_misaligned  = lsu_addr_misaligned && (instr_decoded.fu == LOAD) &&
                                 instr_valid && operands_ready;
  assign store_addr_misaligned = lsu_addr_misaligned && (instr_decoded.fu == STORE) &&
                                 instr_valid && operands_ready;

  logic enter_wfi;
  assign enter_wfi = instr_decoded.is_wfi && instr_valid; // && !debug_q;

  // Check privileges for certain instructions
  always_comb begin : check_privileges
    privileges_violated_raw = 1'b0;
    if (instr_decoded.is_wfi) begin
      // WFI is not allowed in U-mode
      if ((priv_lvl == PrivLvlU)) begin
        privileges_violated_raw = 1'b1;
      end
    end
    if (instr_decoded.is_mret) begin
      if (priv_lvl != PrivLvlM) begin
        privileges_violated_raw = 1'b1;
      end
    end
    if (instr_decoded.is_sret) begin
      if (!(priv_lvl inside {PrivLvlM, PrivLvlS})) begin
        privileges_violated_raw = 1'b1;
      end
    end
  end
  assign privileges_violated = privileges_violated_raw && instr_valid;

  // Only update the privilege stack if there is a valid xRET instruction.
  assign mret = instr_decoded.is_mret && instr_valid && !privileges_violated;
  assign sret = instr_decoded.is_sret && instr_valid && !privileges_violated;

  // A privilege violation is handled as illegal instruction
  assign instr_illegal = instr_decoded_illegal | privileges_violated;

  assign exception = instr_illegal
                   | ecall
                   | ebreak
                   | csr_exception
                   | instr_addr_misaligned
                   | load_addr_misaligned
                   | store_addr_misaligned
                   | interrupt;
                  //  | (dtlb_page_fault & dtlb_trans_valid)
                  //  | (itlb_page_fault & itlb_trans_valid);

  // Check if we are waiting on a FENCE. We can continue if all LSUs are empty.
  logic all_lsus_empty, fence_stall;
  assign all_lsus_empty = lsu_empty; // TODO: combine all LSUs
  assign fence_stall = (instr_decoded.is_fence & ~all_lsus_empty) & instr_valid;

  // TODO: synchronize all LSUs with the Consistency Address Queue (CAQ)

  // We can dispatch the current instruction if:
  // - it is valid
  // - all registers are ready
  // - no stall due to a FENCE
  // - no exception occured
  // - TODO: the Consistency Address Queue (CAQ) between all LSUs are ready
  //
  // Note: the cluster HW barrier only disables fetching new instructions.
  //
  // If there is an exception, we may not record the dispatch and start the exception handling.
  // Also, the instruction must be killed. We can achieve this by resetting the dispatch valid
  // signal. However, this is only possible for FUs which don't generate an exception. Resetting
  // the valid signal to a FU which generates an exception would lead to a combinatorial loop.
  // For FUs which generate exceptions (in this case only CSRs), we generate a separate dispatch
  // valid signal which does not include the exception. If now an exception occurs, the FU kills
  // itself and asserts the exception flag. The controller then can handle the exception and keep
  // the "no exception" valid flag set.
  assign dispatch_instr_valid = instr_valid & registers_ready & ~fence_stall & ~exception;
  // The instruction is dispatched when the Dispatcher signals that the handshake to the FU is
  // performed successfully. The signal instr_dispatched signals that the current instruction has
  // been dispatched successfully and the scoreboard can update its state.
  assign instr_dispatched = dispatch_instr_valid & dispatch_instr_ready;
  assign stall = ~instr_dispatched;

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

  // We can merge the consecutive and branched PC computation such that we only have one adder.
  // The consecutive PC is either +4B or + the branch offset.
  // If we have a JAL or JALR, we store the regular consecutive PC (PC+4) in rd.
  assign consecutive_pc = pc_q +
    ((instr_decoded.is_branch & alu_result.compare_res) ? instr_decoded.imm : 'd4);

  always_comb begin : pc_update
    pc_d = pc_q; // per default stay at current PC

    if (exception) begin
      pc_d = mtvec;
    end else if (!stall && !wfi && !barrier_stall) begin
      // If we don't stall, step the PC unless we are waiting for an event or are stalled by the
      // cluster hw barrier.
      if (mret) begin
        pc_d = mepc;
      end else if (sret) begin
        pc_d = sepc;
      end else if (instr_decoded.is_jal || instr_decoded.is_jalr) begin
        // set to alu result. clear last bit if JALR
        pc_d = alu_result.result & {{31{1'b1}}, ~instr_decoded.is_jalr};
      end else begin
        pc_d = consecutive_pc; // covers regular or branch instruction
      end
    end
  end

  // ---------------------------
  // Dispatch
  // ---------------------------
  // Read the operands
  fu_data_t fu_data;
  schnizo_read_operands #(
    .XLEN          (XLEN),
    .FLEN          (FLEN),
    .RegAddrSize   (REG_ADDR_SIZE),
    .NrIntReadPorts(NrIntReadPorts),
    .NrFpReadPorts (NrFpReadPorts),
    .instr_dec_t    (instr_dec_t),
    .fu_data_t     (fu_data_t)
  ) i_schnizo_read_operands (
    .pc_i       (pc_q),
    .instr_dec_i(instr_decoded),
    .gpr_raddr_o(gpr_raddr),
    .gpr_rdata_i(gpr_rdata),
    .fpr_raddr_o(fpr_raddr),
    .fpr_rdata_i(fpr_rdata),
    .fu_data_o  (fu_data)
  );

  // Create the dispatch request
  disp_req_t dispatch_req;
  logic [0:0] alu_disp_req_valid;
  logic [0:0] alu_disp_req_ready;
  logic [0:0] lsu_disp_req_valid;
  logic [0:0] lsu_disp_req_ready;
  logic       csr_disp_req_valid;
  logic       csr_disp_req_ready;
  logic       fpu_disp_req_valid;
  logic       fpu_disp_req_ready;
  schnizo_dispatcher #(
    .RegAddrSize(REG_ADDR_SIZE),
    .instr_dec_t(instr_dec_t),
    .rmt_entry_t(rmt_entry_t),
    .disp_req_t (disp_req_t),
    .disp_res_t (disp_res_t),
    .fu_data_t  (fu_data_t),
    .acc_req_t  (acc_req_t)
  ) i_schnizo_dispatcher (
    .clk_i,
    .rst_i,
    .instr_dec_i         (instr_decoded),
    .instr_fu_data_i     (fu_data),
    .instr_fetch_data_i  (instr_fetch_data_i),
    .instr_dec_valid_i   (dispatch_instr_valid), // main control signal / stall signal
    .instr_dec_ready_o   (dispatch_instr_ready),

    .disp_req_o          (dispatch_req),
    .alu_disp_req_valid_o(alu_disp_req_valid),
    .alu_disp_req_ready_i(alu_disp_req_ready),
    .alu_disp_res_i      ('0), // RSS not yet implemented
    .lsu_disp_req_valid_o(lsu_disp_req_valid),
    .lsu_disp_req_ready_i(lsu_disp_req_ready),
    .lsu_disp_res_i      ('0),  // RSS not yet implemented
    .csr_disp_req_valid_o(csr_disp_req_valid),
    .csr_disp_req_ready_i(csr_disp_req_ready),
    .fpu_disp_req_valid_o(fpu_disp_req_valid),
    .fpu_disp_req_ready_i(fpu_disp_req_ready),
    .fpu_disp_res_i      ('0), // RSS not yet implemented
    // Shared accelerator interface
    .acc_req_o           (acc_qreq_o),
    .acc_disp_req_valid_o(acc_qvalid_o),
    .acc_disp_req_ready_i(acc_qready_i)
  );

  // ---------------------------
  // Functional Units
  // ---------------------------
  logic [0:0]  alu_result_valid;
  logic [0:0]  alu_result_ready;
  schnizo_reservation_station #(
    .ProdAddrSize(ProdAddrSize),
    .XLEN        (XLEN),
    .FLEN        (FLEN),
    .disp_req_t  (disp_req_t),
    .disp_res_t  (disp_res_t),
    .result_t    (alu_result_t),
    .result_tag_t(instr_tag_t),
    .fu_t        (fu_t),
    .Fu          (schnizo_pkg::ALU),
    // ALU specific
    .HasBranch   (1'b1)
    // LSU specific are default
    // FPU specific are default
  ) i_schnizo_res_stat_alu (
    .clk_i,
    .rst_i,
    .disp_req_i      (dispatch_req),
    .disp_req_valid_i(alu_disp_req_valid),
    .disp_req_ready_o(alu_disp_req_ready),
    .disp_res_o      (), // not yet implemented
    .rss_full_o      (), // asserted if all RSS are in use

    // LSU specific - not connected
    .lsu_data_req_o       (),
    .lsu_data_rsp_i       ('0),
    .lsu_empty_o          (),
    .lsu_addr_misaligned_o(),
    .caq_addr_i           ('0),
    .caq_is_fp_store_i    ('0),
    .caq_req_valid_i      ('0),
    .caq_req_ready_o      (),
    .caq_rsp_valid_i      ('0),
    .caq_rsp_valid_o      (),

    // FPU specific
    .hart_id_i('0),
    .fpu_status_o(),

    // Write back port
    .result_o      (alu_result),
    .result_tag_o  (alu_result_tag),
    .result_valid_o(alu_result_valid),
    .result_ready_i(alu_result_ready)
    // TODO: Xbar interface to other RS
  );

  logic       lsu_result_valid;
  logic       lsu_result_ready;
  instr_tag_t lsu_result_tag;
  data_t      lsu_result;

  schnizo_reservation_station #(
    .ProdAddrSize(ProdAddrSize),
    .XLEN        (XLEN),
    .FLEN        (FLEN),
    .disp_req_t  (disp_req_t),
    .disp_res_t  (disp_res_t),
    .result_t    (data_t),
    .result_tag_t(instr_tag_t),
    .fu_t        (fu_t),
    .Fu          (schnizo_pkg::STORE), // can be store or load for LSU
    // ALU specific are default
    // LSU specific
    .AddrWidth             (AddrWidth),
    .DataWidth             (DataWidth),
    .dreq_t                (dreq_t),
    .drsp_t                (drsp_t),
    .NumIntOutstandingMem  (NumOutstandingMem),
    .NumIntOutstandingLoads(NumOutstandingLoads),
    .CaqEn                 (0), // TODO: Disabled for the first implementation
    .CaqDepth              (CaqDepth),
    .CaqTagWidth           (CaqTagWidth)
    // FPU specific are default
  ) i_schnizo_res_stat_lsu (
    .clk_i,
    .rst_i,
    .disp_req_i      (dispatch_req),
    .disp_req_valid_i(lsu_disp_req_valid),
    .disp_req_ready_o(lsu_disp_req_ready),
    .disp_res_o      (), // not yet implemented
    .rss_full_o      (), // asserted if all RSS are in use

    /// LSU specific
    // LSU memory interface
    .lsu_data_req_o       (data_req_o),
    .lsu_data_rsp_i       (data_rsp_i),
    .lsu_empty_o          (lsu_empty),
    .lsu_addr_misaligned_o(lsu_addr_misaligned),
    // Consistency address queue interface
    .caq_addr_i           ('0),
    .caq_is_fp_store_i    (1'b0),
    .caq_req_valid_i      (1'b0),
    .caq_req_ready_o      (),
    .caq_rsp_valid_i      (1'b0),
    .caq_rsp_valid_o      (),

    // FPU specific
    .hart_id_i('0),
    .fpu_status_o(),

    // Write back port
    .result_o      (lsu_result),
    .result_tag_o  (lsu_result_tag),
    .result_valid_o(lsu_result_valid),
    .result_ready_i(lsu_result_ready)
    // TODO: Xbar interface to other RS
  );

  // CSR FU & register file
  // Has direct connection to control logic.
  logic csr_result_valid;
  logic csr_result_ready;
  instr_tag_t csr_result_tag;
  logic [XLEN-1:0] csr_result;

  schnizo_csr #(
    .XLEN(XLEN),
    .DebugSupport(0),
    .RVF(RVF),
    .RVD(RVD),
    .Xdma(Xdma),
    .VMSupport(0),
    .disp_req_t(disp_req_t),
    .result_tag_t(instr_tag_t)
  ) i_schnizo_csr (
    .clk_i(clk_i),
    .rst_i(rst_i),

    .disp_req_i         (dispatch_req),
    .disp_req_valid_i   (csr_disp_req_valid),
    .disp_req_ready_o   (csr_disp_req_ready),
    .illegal_csr_instr_o(csr_exception_raw),

    .result_o      (csr_result),
    .result_tag_o  (csr_result_tag),
    .result_valid_o(csr_result_valid),
    .result_ready_i(csr_result_ready),

    .irq_i                  (irq_i),
    .enter_wfi_i            (enter_wfi),
    .pc_i                   (pc_q),
    .illegal_instr_i        (instr_illegal),
    .ecall_i                (ecall),
    .ebreak_i               (ebreak),
    .instr_addr_misaligned_i(instr_addr_misaligned),
    .load_addr_misaligned_i (load_addr_misaligned),
    .store_addr_misaligned_i(store_addr_misaligned),
    .exception_i            (exception),
    .mret_i                 (mret),
    .sret_i                 (sret),
    .interrupt_o            (interrupt),
    .mtvec_o                (mtvec),
    .mepc_o                 (mepc),
    .sepc_o                 (sepc),
    .wfi_o                  (wfi),
    .priv_lvl_o             (priv_lvl),
    .hart_id_i              (hart_id_i),
    .barrier_i              (barrier_i),
    .barrier_o              (barrier_o),
    .barrier_stall_o        (barrier_stall),
    .fpu_status_i           (fpu_status),
    .fpu_status_valid_i     (fpu_status_valid),
    .fpu_rnd_mode_o         (fpu_rnd_mode),
    .fpu_fmt_mode_o         (fpu_fmt_mode)
  );

  logic            fpu_result_valid;
  logic            fpu_result_ready;
  instr_tag_t      fpu_result_tag;
  // Create a typedef such that we can safely pass it to the RS
  typedef logic [FLEN-1:0] fpu_result_t;
  fpu_result_t     fpu_result;

  schnizo_reservation_station #(
    .ProdAddrSize(ProdAddrSize),
    .XLEN        (XLEN),
    .FLEN        (FLEN),
    .disp_req_t  (disp_req_t),
    .disp_res_t  (disp_res_t),
    .result_t    (fpu_result_t),
    .result_tag_t(instr_tag_t),
    .fu_t        (fu_t),
    .Fu          (schnizo_pkg::FPU),
    // ALU specific are default
    // LSU specific are default
    // FPU specific
    .FPUImplementation(FPUImplementation),
    .RVF(RVF),
    .RVD(RVD),
    .XF16(XF16),
    .XF16ALT(XF16ALT),
    .XF8(XF8),
    .XF8ALT(XF8ALT),
    .XFVEC(XFVEC),
    .RegisterFPUIn(RegisterFPUIn),
    .RegisterFPUOut(RegisterFPUOut)
  ) i_schnizo_res_stat_fpu (
    .clk_i,
    .rst_i,
    .disp_req_i      (dispatch_req),
    .disp_req_valid_i(fpu_disp_req_valid),
    .disp_req_ready_o(fpu_disp_req_ready),
    .disp_res_o      (), // not yet implemented
    .rss_full_o      (), // asserted if all RSS are in use

    // LSU specific - not connected
    .lsu_data_req_o       (),
    .lsu_data_rsp_i       ('0),
    .lsu_empty_o          (),
    .lsu_addr_misaligned_o(),
    .caq_addr_i           ('0),
    .caq_is_fp_store_i    ('0),
    .caq_req_valid_i      ('0),
    .caq_req_ready_o      (),
    .caq_rsp_valid_i      ('0),
    .caq_rsp_valid_o      (),

    // FPU specific
    .hart_id_i(hart_id_i),
    .fpu_status_o(fpu_status),

    // Write back port
    .result_o      (fpu_result),
    .result_tag_o  (fpu_result_tag),
    .result_valid_o(fpu_result_valid),
    .result_ready_i(fpu_result_ready)
    // TODO: Xbar interface to other RS
  );

  // We may only update the FCSR fpu status bits if the result is handshaked.
  assign fpu_status_valid = fpu_result_valid && fpu_result_ready;

  // ---------------------------
  // Write back
  // ---------------------------
  // Handle the write back of all FUs.
  // Branch results are directly returned to the controller.
  //
  // Prio for GPR
  // - ALU
  //   - if ALU result is a branch -> process branch and handle next write back
  //   - if ALU result is a CSR bypass -> write back ALU result
  // - CSR
  // - LSU
  // - FPU
  // - Accelerator interface
  // Prio for FPR
  // - FPU
  // - LSU
  // - Accelerator interface (not implemented / there is no tag to select FP register)

  // !!! WARNING !!!
  // The accelerator request only contains an ID to specify the destination register.
  // Due to this we cannot distinguish between floating point and integer registers!
  // As of now, all accelerator responses target the integer register file.
  // This should not be a problem, as the Snitch FPR is only in the FP_SS present.

  // Convert the accelerator response to a proper result and result tag such that the
  // write back and scoreboard functions properly.
  logic [XLEN-1:0] acc_result;
  instr_tag_t      acc_result_tag;
  always_comb begin : acc_response_conversion
    acc_result = acc_prsp_i.data;
    acc_result_tag = '0;
    acc_result_tag.dest_reg = acc_prsp_i.id;
    acc_result_tag.dest_reg_is_fp = 1'b0;
  end

  logic alu_valid_gpr; // The ALU only writes to the GPR
  logic alu_ready_gpr;
  logic csr_valid_gpr; // The CSR only writes to the GPR
  logic csr_ready_gpr;
  logic lsu_valid_gpr, lsu_valid_fpr;
  logic lsu_ready_gpr, lsu_ready_fpr;
  logic fpu_valid_gpr, fpu_valid_fpr;
  logic fpu_ready_gpr, fpu_ready_fpr;
  logic acc_valid_gpr; // The accelerator only writes to the GPR
  logic acc_ready_gpr;

  // MUX the valid/ready signals to the correct register file.
  // TODO: This is probably unnecessary and stalls the core. However, the ALU should never
  //        write to the FPR. How should we handle this case? -> Assertion?
  assign alu_valid_gpr = alu_result_tag.dest_reg_is_fp ? 1'b0 : alu_result_valid;
  // The ALU cannot write to the FPR -> no alu_valid_fpr
  assign alu_result_ready = alu_result_tag.dest_reg_is_fp ? 1'b0 : alu_ready_gpr;

  // TODO: Same case as ALU. The CSR should never write to the FPR. -> Assertion?
  assign csr_valid_gpr = csr_result_tag.dest_reg_is_fp ? 1'b0 : csr_result_valid;
  assign csr_result_ready = csr_result_tag.dest_reg_is_fp ? 1'b0 : csr_ready_gpr;

  assign lsu_valid_gpr = lsu_result_tag.dest_reg_is_fp ? 1'b0             : lsu_result_valid;
  assign lsu_valid_fpr = lsu_result_tag.dest_reg_is_fp ? lsu_result_valid : 1'b0;
  assign lsu_result_ready = lsu_result_tag.dest_reg_is_fp ? lsu_ready_fpr : lsu_ready_gpr;

  assign fpu_valid_gpr = fpu_result_tag.dest_reg_is_fp ? 1'b0             : fpu_result_valid;
  assign fpu_valid_fpr = fpu_result_tag.dest_reg_is_fp ? fpu_result_valid : 1'b0;
  assign fpu_result_ready = fpu_result_tag.dest_reg_is_fp ? fpu_ready_fpr : fpu_ready_gpr;

  // TODO: The Accelerator should never write to the FPR. -> Assertion?
  assign acc_valid_gpr = acc_result_tag.dest_reg_is_fp ? 1'b0 : acc_pvalid_i;
  assign acc_pready_o = acc_result_tag.dest_reg_is_fp ? 1'b0 : acc_ready_gpr;

  // Note: The register file must always be ready.
  // Otherwise the valid/ready handshaking is not AXI conform anymore.
  always_comb begin : int_regfile_writeback
    gpr_we = 1'b0;
    gpr_waddr = '0;
    gpr_wdata = '0;

    // interfaces to FU writing back to the integer RF
    alu_ready_gpr = '0;
    csr_ready_gpr = '0;
    lsu_ready_gpr = '0;
    fpu_ready_gpr = '0;
    acc_ready_gpr = '0;

    // If we have a valid request from the ALU, we have to check whether we actually want to write
    // to a register. Any instruction which is retiring without a register write has the
    // destination register set to rd = x0 (rd = 0, rd_is_fp = 0) as this register is not
    // writeable.
    // However, these requests still have to be acknowledged (assert the ready signal) as any
    // combinatorial FU direclty feeds through the ready signal from the write back to the
    // dispatcher. If these were not acknowledged the whole pipeline would stall forever.
    if (alu_valid_gpr && alu_result_tag.dest_reg != '0) begin
      gpr_we = 1'b1;
      gpr_waddr = alu_result_tag.dest_reg;
      // Select the data to write into rd.
      // This can either be the ALU result or the consecutive PC (for JAL / JALR)
      if (alu_result_tag.is_jump) begin
        gpr_wdata = consecutive_pc;
      end else begin
        gpr_wdata = alu_result.result;
      end

      alu_ready_gpr = 1'b1;
    end else begin
      // We have no actual write request from the ALU but we still have to handle any ALU request
      // without a write back (i.e. rd = 0 or branch instr).
      if (alu_valid_gpr && alu_result_tag.dest_reg == '0) begin
        alu_ready_gpr = 1'b1;
      end
      // The CSR writeback is similar to the ALU write back. Handle actual write requests and
      // always acknowledge all other requests.
      if (csr_valid_gpr && csr_result_tag.dest_reg != '0) begin
        gpr_we = 1'b1;
        gpr_waddr = csr_result_tag.dest_reg;
        gpr_wdata = csr_result[XLEN-1:0];
        csr_ready_gpr = 1'b1;
      end else begin
      // If there is no actual write request, we can serve a LSU or FPU request.
        if (csr_valid_gpr && csr_result_tag.dest_reg == '0) begin
          csr_ready_gpr = 1'b1;
        end
      if (lsu_valid_gpr) begin
        gpr_we = 1'b1;
        gpr_waddr = lsu_result_tag.dest_reg;
        gpr_wdata = lsu_result[XLEN-1:0];
        lsu_ready_gpr = 1'b1;
      end else if (fpu_valid_gpr) begin
        gpr_we = 1'b1;
        gpr_waddr = fpu_result_tag.dest_reg;
        gpr_wdata = fpu_result[XLEN-1:0];
        fpu_ready_gpr = 1'b1;
        end else if (acc_valid_gpr) begin
          gpr_we = 1'b1;
          gpr_waddr = acc_result_tag.dest_reg;
          gpr_wdata = acc_result[XLEN-1:0];
          acc_ready_gpr = 1'b1;
        end
      end
    end
  end

  always_comb begin : fp_regfile_writeback
    fpr_we = 1'b0;
    fpr_waddr = '0;
    fpr_wdata = '0;

    // interfaces to FU writing back to the integer RF
    lsu_ready_fpr = '0;
    fpu_ready_fpr = '0;

    if (lsu_valid_fpr) begin
      fpr_we = 1'b1;
      fpr_waddr = lsu_result_tag.dest_reg;
      fpr_wdata = lsu_result[FLEN-1:0];
      lsu_ready_fpr = 1'b1;
    end else if (fpu_valid_fpr) begin
      fpr_we = 1'b1;
      fpr_waddr = fpu_result_tag.dest_reg;
      fpr_wdata = fpu_result[FLEN-1:0];
      fpu_ready_fpr = 1'b1;
    end
  end

  // ---------------------------
  // Register Files
  // ---------------------------
  snitch_regfile #(
    .DataWidth   (XLEN),
    .NrReadPorts (NrIntReadPorts),
    .NrWritePorts(NrIntWritePorts),
    .ZeroRegZero (1),
    .AddrWidth   (REG_ADDR_SIZE)
  ) i_int_regfile (
    .clk_i,
    .rst_ni (~rst_i),
    .raddr_i(gpr_raddr),
    .rdata_o(gpr_rdata),
    .waddr_i(gpr_waddr),
    .wdata_i(gpr_wdata),
    .we_i   (gpr_we)
  );

  snitch_regfile #(
    .DataWidth    (FLEN),
    .NrReadPorts  (NrFpReadPorts),
    .NrWritePorts (NrFpWritePorts),
    .ZeroRegZero  (0),
    .AddrWidth    (REG_ADDR_SIZE)
  ) i_fp_regfile (
    .clk_i,
    .rst_ni (~rst_i),
    .raddr_i(fpr_raddr),
    .rdata_o(fpr_rdata),
    .waddr_i(fpr_waddr),
    .wdata_i(fpr_wdata),
    .we_i   (fpr_we)
  );

endmodule
