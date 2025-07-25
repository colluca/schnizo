// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: Top-Level of the Schnizo Core.
// The Schnizo core is basically a Snitch which got schizophrenia.
// As of this, it now features a superscalar loop execution.
// This core implements the following RISC-V extensions:
// - IMAFD (A ignoring aq and lr flags)
// - Zicsr, Zicntr (Cycle & Instret only, always enabled)

// Limitation:
// - The scoreboard assumes that only multi cycle functional units write to the floating point
//   register file!
// - when reaching the end of a program, we somehow have to make sure that all instructions
//   have committed before the core gets stopped.

// Use automatic retiming options in the synthesis tool to optimize the fpnew design.

// TODO
// - LSU CAQ
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
  /// Enable the Superscalar FREP mode
  parameter bit          Xfrep     = 1,
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
  /// FU configuration
  parameter int unsigned NofLsus    = 1,
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
  input  interrupts_t   irq_i,
  // Instruction cache flush request (for FENCE_I instruction)
  output logic          flush_i_valid_o,
  // Flush has completed when the signal goes to `1`.
  // Tie to `1` if unused
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
  output acc_req_t  acc_qreq_o,
  output logic      acc_qvalid_o,
  input  logic      acc_qready_i,
  input  acc_resp_t acc_prsp_i,
  input  logic      acc_pvalid_i,
  output logic      acc_pready_o,
  /// TCDM Data Interface
  /// Write transactions do not return data on the `P Channel`
  /// Transactions need to be handled strictly in-order.
  output dreq_t [NofLsus-1:0] data_req_o,
  input  drsp_t [NofLsus-1:0] data_rsp_i,
  /// Core events for performance counters
  output snitch_pkg::core_events_t core_events_o,
  /// Cluster HW barrier
  output logic barrier_o,
  input  logic barrier_i
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
    logic                     is_fence_i; // set if FENCE.I
    logic                     is_ecall;
    logic                     is_ebreak;
    logic                     is_mret;
    logic                     is_sret;
    logic                     is_wfi;
    // FREP extension
    logic                           is_frep;
    logic [FREP_BODYSIZE_WIDTH-1:0] frep_bodysize;
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

  // ---------------------------
  // RSS definitions / parameters
  // ---------------------------
  localparam int unsigned NofAlus = 3;
  // localparam int unsigned NofLsus = 1; // defined via cluster config / SSR config
  localparam int unsigned NofFpus = 1;

  localparam integer unsigned AluNofOperands = 2;
  localparam integer unsigned LsuNofOperands = 3; // the 3rd operand is the address offset
  localparam integer unsigned FpuNofOperands = 3;

  localparam integer unsigned AluNofRss      = 3;
  localparam integer unsigned LsuNofRss      = 2;
  localparam integer unsigned FpuNofRss      = 4;

  // ---------------------------
  // Operand distribution network definitions
  // ---------------------------
  // Operand Interface: This is a Xbar master placing operand requests. It also has a corresponding
  //                    operand response interface / slave.
  // Result Interface:  This is a Xbar slave receiving result requests and has a corresponding
  //                    result response master.
  //
  // A full blown crossbar is infeasible for more than 14 total slots.
  // Therefore we reduce the number of operand interfaces to one per operand per reservation station.
  // We thus have:
  // - each operand of each Reservation station has an operand master (1 port)
  // - each RSS has an own result request interface but only each RS has one result response interface.

  // Define how many operand request / response ports each RS has.
  // A port includes a set of xbar in/outputs for each operand.
  // I.e. if the ALU has 2 operands, 1 port generates 2 operand interfaces
  localparam integer unsigned AluNofOpPorts = 1;
  localparam integer unsigned LsuNofOpPorts = 1;
  localparam integer unsigned FpuNofOpPorts = 1;

  localparam integer unsigned AluNofOperandIfs = AluNofOperands * AluNofOpPorts;
  localparam integer unsigned LsuNofOperandIfs = LsuNofOperands * LsuNofOpPorts;
  localparam integer unsigned FpuNofOperandIfs = FpuNofOperands * FpuNofOpPorts;

  localparam integer unsigned NofOperandIfs = NofAlus * AluNofOperandIfs +
                                              NofLsus * LsuNofOperandIfs +
                                              NofFpus * FpuNofOperandIfs;

  // We differentiate between result requests and result responses.
  // Each reservation station has a result request crossbar output which is shared among the slots.
  // We allow multi request handling by coalescing requests.
  localparam integer unsigned AluNofResReqIfs = 1;
  localparam integer unsigned LsuNofResReqIfs = 1;
  localparam integer unsigned FpuNofResReqIfs = 1;

  localparam integer unsigned NofResReqIfs = NofAlus * AluNofResReqIfs +
                                             NofLsus * LsuNofResReqIfs +
                                             NofFpus * FpuNofResReqIfs;

  // Each slot has its dedicated response crossbar input.
  localparam integer unsigned AluNofResRspIfs = AluNofRss;
  localparam integer unsigned LsuNofResRspIfs = LsuNofRss;
  localparam integer unsigned FpuNofResRspIfs = FpuNofRss;

  localparam integer unsigned NofResRspIfs = NofAlus * AluNofResRspIfs +
                                             NofLsus * LsuNofResRspIfs +
                                             NofFpus * FpuNofResRspIfs;

  // The operands of multiple RSS share their operand ID per RS.
  localparam integer unsigned NofOperandIfsW = cf_math_pkg::idx_width(NofOperandIfs);
  localparam integer unsigned NofResReqIfsW  = cf_math_pkg::idx_width(NofResReqIfs);

  typedef logic [NofOperandIfsW-1:0] operand_id_t;

  // Each RS has an unique number. The slots have unique numbers within the RS.
  localparam integer unsigned MaxNofRss = (AluNofRss > LsuNofRss) ?
                                          // AluNofRss > LsuNofRss
                                          ((AluNofRss > FpuNofRss) ? AluNofRss : FpuNofRss)
                                          : // AluNofRss < LsuNofRss
                                          ((LsuNofRss > FpuNofRss) ? LsuNofRss : FpuNofRss);

  localparam integer unsigned SlotIdWidth = cf_math_pkg::idx_width(MaxNofRss);

  typedef logic [SlotIdWidth-1:0]   slot_id_t;
  typedef logic [NofResReqIfsW-1:0] rs_id_t;

  typedef struct packed {
    slot_id_t slot_id; // used to select the slot of the request within the RS
    rs_id_t   rs_id; // used to control the request crossbar
  } producer_id_t;

  // ---------------------------
  // Dispatch/issue/result data types
  // ---------------------------
  typedef struct packed {
    producer_id_t producer;
  } disp_rsp_t;

  typedef struct packed {
    producer_id_t producer;
    logic         is_produced; // set if prod_id is a valid mapping
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
    fu_data_t fu_data;
    instr_tag_t tag;
  } issue_req_t;

  // The ALU result without the branch decision
  typedef logic [XLEN-1:0] alu_res_val_t;

  typedef struct packed {
    alu_res_val_t result;
    logic         compare_res;
  } alu_result_t;

  // ---------------------------
  // Local signals
  // ---------------------------
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

  fu_data_t fu_data;

  logic            instr_fetch_valid;
  logic            flush_i_valid;
  logic [31:0]     pc;
  logic            instr_valid;
  logic            instr_decoded_illegal;
  logic            instr_illegal;
  logic            stall;
  logic            enter_wfi;
  logic            ebreak;
  logic            ecall;
  logic            mret;
  logic            sret;
  logic[31:0]      mtvec;
  logic[31:0]      mepc;
  logic[31:0]      sepc;
  logic            csr_exception_raw;
  logic            barrier_stall;
  logic            instr_addr_misaligned;
  logic            lsu_addr_misaligned;
  logic [0:0]      load_addr_misaligned;
  logic [0:0]      store_addr_misaligned;
  priv_lvl_t       priv_lvl;
  logic            interrupt;
  logic            exception;
  logic            wfi; // asserted if we are waiting for an interrupt
  logic            dispatch_instr_valid;
  logic            dispatch_instr_ready;
  logic            instr_exec_commit;
  logic [XLEN-1:0] consecutive_pc;

  fpnew_pkg::roundmode_e fpu_rnd_mode;
  fpnew_pkg::fmt_mode_t  fpu_fmt_mode;
  instr_dec_t instr_decoded;

  alu_result_t alu_result;
  instr_tag_t  alu_result_tag;
  alu_result_t branch_result;
  logic [0:0]  lsu_empty;
  fpnew_pkg::status_t fpu_status;
  logic               fpu_status_valid;
  frep_mem_cons_mode_e frep_mem_cons_mode;

  // ---------------------------
  // Core Events
  // ---------------------------
  // Store if an instruction has retired last cycle and store the type of instruction retired
  logic instr_retired,              instr_retired_q;
  logic instr_retired_single_cycle, instr_retired_single_cycle_q;
  logic instr_retired_load,         instr_retired_load_q;
  logic instr_retired_acc,          instr_retired_acc_q;

  // 1to1 from Snitch FP SS
  logic issue_fpu,         issue_fpu_q;
  logic issue_core_to_fpu, issue_core_to_fpu_q;
  // we do not have a sequencer.

  `FFAR(instr_retired_q,              instr_retired,              '0, clk_i, rst_i)
  `FFAR(instr_retired_single_cycle_q, instr_retired_single_cycle, '0, clk_i, rst_i)
  `FFAR(instr_retired_load_q,         instr_retired_load,         '0, clk_i, rst_i)
  `FFAR(instr_retired_acc_q,          instr_retired_acc,          '0, clk_i, rst_i)
  `FFAR(issue_fpu_q,                  issue_fpu,                  '0, clk_i, rst_i)
  `FFAR(issue_core_to_fpu_q,          issue_core_to_fpu,          '0, clk_i, rst_i)

  // ---------------------------
  // Instruction fetch
  // ---------------------------
  // request the instruction at the current PC
  assign instr_fetch_addr_o = {{{AddrWidth-32}{1'b0}}, pc};
  assign instr_fetch_cacheable_o =
    snitch_pma_pkg::is_inside_cacheable_regions(SnitchPMACfg, instr_fetch_addr_o);
  assign instr_fetch_valid_o = instr_fetch_valid;

  logic instr_fetch_data_valid;
  assign instr_fetch_data_valid = instr_fetch_valid_o & instr_fetch_ready_i;

  // Instruction Cache flush request interface
  assign flush_i_valid_o = flush_i_valid;

  // ---------------------------
  // Decoder
  // ---------------------------
  schnizo_decoder #(
    .XLEN   (XLEN),
    .Xdma   (Xdma),
    .Xfrep  (Xfrep),
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

  // Read the operands - do always read (even if invalid instr) because controller depends on
  // values from registers. See for example the FREP instruction and its number of iterations.
  schnizo_read_operands #(
    .XLEN          (XLEN),
    .FLEN          (FLEN),
    .RegAddrSize   (REG_ADDR_SIZE),
    .NrIntReadPorts(NrIntReadPorts),
    .NrFpReadPorts (NrFpReadPorts),
    .instr_dec_t    (instr_dec_t),
    .fu_data_t     (fu_data_t)
  ) i_schnizo_read_operands (
    .pc_i       (pc),
    .instr_dec_i(instr_decoded),
    .gpr_raddr_o(gpr_raddr),
    .gpr_rdata_i(gpr_rdata),
    .fpr_raddr_o(fpr_raddr),
    .fpr_rdata_i(fpr_rdata),
    .fu_data_o  (fu_data)
  );

  // ---------------------------
  // Controller
  // ---------------------------
  logic                           rs_full;
  logic                           lxp_restart;
  logic                           goto_lcp2;
  loop_state_e                    loop_state;
  logic [FREP_MAXITERS_WIDTH-1:0] lep_iterations;
  logic                           all_rs_finish;

  schnizo_controller #(
    .Xfrep          (Xfrep),
    .XLEN           (XLEN),
    .BootAddr       (BootAddr),
    .NrIntWritePorts(NrIntWritePorts),
    .NrFpWritePorts (NrFpWritePorts),
    .RegAddrSize    (REG_ADDR_SIZE),
    .MaxIterationsW (FREP_MAXITERS_WIDTH),
    .instr_dec_t    (instr_dec_t),
    .priv_lvl_t     (priv_lvl_t)
  ) i_schnizo_controller (
    .clk_i,
    .rst_i,
    // Frontend interface
    .pc_o                   (pc),
    .instr_fetch_valid_o    (instr_fetch_valid),
    .flush_i_ready_i        (flush_i_ready_i),
    .flush_i_valid_o        (flush_i_valid),
    // Decoder interface
    .instr_decoded_i        (instr_decoded),
    .instr_valid_i          (instr_valid),
    .instr_decoded_illegal_i(instr_decoded_illegal),
    // FREP data from registers
    .frep_iterations_i      (fu_data.operand_a[FREP_MAXITERS_WIDTH-1:0]),
    // Interface to dispatcher
    .dispatch_instr_valid_o (dispatch_instr_valid),
    .dispatch_instr_ready_i (dispatch_instr_ready),
    .instr_exec_commit_o    (instr_exec_commit),
    .stall_o                (stall),
    .rs_full_i              (rs_full),
    .all_rs_finish_i        (all_rs_finish),
    .goto_lcp2_o            (goto_lcp2),
    .lep_iterations_o       (lep_iterations),
    .loop_state_o           (loop_state),
    .rs_restart_o           (lxp_restart),
    // Exception source interface
    .interrupt_i            (interrupt),
    .wfi_i                  (wfi),
    .barrier_stall_i        (barrier_stall),
    .csr_exception_raw_i    (csr_exception_raw),
    .lsu_empty_i            (lsu_empty),
    .lsu_addr_misaligned_i  (lsu_addr_misaligned),
    .priv_lvl_i             (priv_lvl),
    .mtvec_i                (mtvec),
    .mepc_i                 (mepc),
    .sepc_i                 (sepc),
    // Branch result
    .alu_compare_res_i      (branch_result.compare_res),
    .alu_result_i           (branch_result.result),
    // Interface to CSR & write back for handling an exception
    .exception_o            (exception),
    .instr_illegal_o        (instr_illegal),
    .instr_addr_misaligned_o(instr_addr_misaligned),
    .load_addr_misaligned_o (load_addr_misaligned),
    .store_addr_misaligned_o(store_addr_misaligned),
    .enter_wfi_o            (enter_wfi),
    .ecall_o                (ecall),
    .ebreak_o               (ebreak),
    .mret_o                 (mret),
    .sret_o                 (sret),
    .consecutive_pc_o       (consecutive_pc),
    // GPR & FPR Write back snooping for Scoreboard
    .gpr_we_i               (gpr_we),
    .gpr_waddr_i            (gpr_waddr),
    .fpr_we_i               (fpr_we),
    .fpr_waddr_i            (fpr_waddr)
);

  // ---------------------------
  // Dispatch
  // ---------------------------
  // Create the dispatch request
  disp_req_t dispatch_req;
  logic      [NofAlus-1:0] alu_disp_req_valid;
  logic      [NofAlus-1:0] alu_disp_req_ready;
  disp_rsp_t [NofAlus-1:0] alu_disp_rsp;
  logic      [NofAlus-1:0] alu_rs_full;
  logic      [NofLsus-1:0] lsu_disp_req_valid;
  logic      [NofLsus-1:0] lsu_disp_req_ready;
  disp_rsp_t [NofLsus-1:0] lsu_disp_rsp;
  logic      [NofLsus-1:0] lsu_rs_full;
  logic                    csr_disp_req_valid;
  logic                    csr_disp_req_ready;
  logic      [NofFpus-1:0] fpu_disp_req_valid;
  logic      [NofFpus-1:0] fpu_disp_req_ready;
  disp_rsp_t [NofFpus-1:0] fpu_disp_rsp;
  logic      [NofFpus-1:0] fpu_rs_full;

  schnizo_dispatcher #(
    .RegAddrSize(REG_ADDR_SIZE),
    .NofAlus    (NofAlus),
    .NofLsus    (NofLsus),
    .NofFpus    (NofFpus),
    .instr_dec_t(instr_dec_t),
    .rmt_entry_t(rmt_entry_t),
    .disp_req_t (disp_req_t),
    .disp_rsp_t (disp_rsp_t),
    .fu_data_t  (fu_data_t),
    .acc_req_t  (acc_req_t)
  ) i_schnizo_dispatcher (
    .clk_i,
    .rst_i,
    .instr_dec_i         (instr_decoded),
    .instr_fu_data_i     (fu_data),
    .instr_fetch_data_i  (instr_fetch_data_i),
    .dispatch_valid_i    (dispatch_instr_valid), // main control signal / stall signal
    .instr_exec_commit_i (instr_exec_commit),
    .dispatch_ready_o    (dispatch_instr_ready),
    // Instruction stream
    .disp_req_o          (dispatch_req),
    // ALU
    .alu_disp_req_valid_o(alu_disp_req_valid),
    .alu_disp_req_ready_i(alu_disp_req_ready),
    .alu_disp_rsp_i      (alu_disp_rsp),
    .alu_rs_full_i       (alu_rs_full),
    // LSU
    .lsu_disp_req_valid_o(lsu_disp_req_valid),
    .lsu_disp_req_ready_i(lsu_disp_req_ready),
    .lsu_disp_rsp_i      (lsu_disp_rsp),
    .lsu_rs_full_i       (lsu_rs_full),
    // CSR
    .csr_disp_req_valid_o(csr_disp_req_valid),
    .csr_disp_req_ready_i(csr_disp_req_ready),
    // FPU
    .fpu_disp_req_valid_o(fpu_disp_req_valid),
    .fpu_disp_req_ready_i(fpu_disp_req_ready),
    .fpu_disp_rsp_i      (fpu_disp_rsp),
    .fpu_rs_full_i       (fpu_rs_full),
    // Shared accelerator interface
    .acc_req_o           (acc_qreq_o),
    .acc_disp_req_valid_o(acc_qvalid_o),
    .acc_disp_req_ready_i(acc_qready_i),
    // RS control signals
    .restart_i           (lxp_restart),
    .loop_state_i        (loop_state),
    .goto_lcp2_i         (goto_lcp2),
    .frep_mem_cons_mode_i(frep_mem_cons_mode),
    .rs_full_o           (rs_full)
  );

  // Convert dispatch request to issue request for CSR.
  // The valid/ready is fed through so no extra signals.
  issue_req_t issue_req;
  assign issue_req.fu_data = dispatch_req.fu_data;
  assign issue_req.tag     = dispatch_req.tag;

  // ---------------------------
  // Functional Units
  // ---------------------------
  logic            alu_result_valid;
  logic            alu_result_ready;
  logic            lsu_result_valid;
  logic            lsu_result_ready;
  instr_tag_t      lsu_result_tag;
  data_t           lsu_result;
  logic [FLEN-1:0] fpu_result;
  logic            fpu_result_valid;
  logic            fpu_result_ready;
  instr_tag_t      fpu_result_tag;

  schnizo_fu_stage #(
    .Xfrep              (Xfrep),
    .NofAlus            (NofAlus),
    .AluNofRss          (AluNofRss),
    .AluNofOperands     (AluNofOperands),
    .AluNofOpPorts      (AluNofOpPorts),
    .AluNofResReqIfs    (AluNofResReqIfs),
    .AluNofResRspIfs    (AluNofResRspIfs),
    .NofLsus            (NofLsus),
    .LsuNofRss          (LsuNofRss),
    .LsuNofOperands     (LsuNofOperands),
    .LsuNofOpPorts      (LsuNofOpPorts),
    .LsuNofResReqIfs    (LsuNofResReqIfs),
    .LsuNofResRspIfs    (LsuNofResRspIfs),
    .NofFpus            (NofFpus),
    .FpuNofRss          (FpuNofRss),
    .FpuNofOperands     (FpuNofOperands),
    .FpuNofOpPorts      (FpuNofOpPorts),
    .FpuNofResReqIfs    (FpuNofResReqIfs),
    .FpuNofResRspIfs    (FpuNofResRspIfs),
    .NofOperandIfs      (NofOperandIfs),
    .NofResReqIfs       (NofResReqIfs),
    .NofResRspIfs       (NofResRspIfs),
    .XLEN               (XLEN),
    .FLEN               (FLEN),
    .OpLen              (OpLen),
    .AddrWidth          (AddrWidth),
    .DataWidth          (DataWidth),
    .RegAddrWidth       (REG_ADDR_SIZE),
    .MaxIterationsW     (FREP_MAXITERS_WIDTH),
    .CaqDepth           (CaqDepth),
    .CaqTagWidth        (CaqTagWidth),
    .NumOutstandingLoads(NumOutstandingLoads),
    .NumOutstandingMem  (NumOutstandingMem),
    .FPUImplementation  (FPUImplementation),
    .RVF                (RVF),
    .RVD                (RVD),
    .XF16               (XF16),
    .XF16ALT            (XF16ALT),
    .XF8                (XF8),
    .XF8ALT             (XF8ALT),
    .XFVEC              (XFVEC),
    .RegisterFPUIn      (RegisterFPUIn),
    .RegisterFPUOut     (RegisterFPUOut),
    .producer_id_t      (producer_id_t),
    .slot_id_t          (slot_id_t),
    .rs_id_t            (rs_id_t),
    .operand_id_t       (operand_id_t),
    .disp_req_t         (disp_req_t),
    .disp_rsp_t         (disp_rsp_t),
    .issue_req_t        (issue_req_t),
    .instr_tag_t        (instr_tag_t),
    .alu_result_t       (alu_result_t),
    .alu_res_val_t      (alu_res_val_t),
    .dreq_t             (dreq_t),
    .drsp_t             (drsp_t)
  ) i_fu_stage (
    .clk_i,
    .rst_i,
    .hard_id_i            (hart_id_i),
    .restart_i            (lxp_restart),
    .loop_state_i         (loop_state),
    .lep_iterations_i     (lep_iterations),
    .goto_lcp2_i          (goto_lcp2),
    .disp_req_i           (dispatch_req),
    .all_rs_finish_o      (all_rs_finish),
    // Global commit signal
    .instr_exec_commit_i  (instr_exec_commit),
    // ALU
    .alu_disp_reqs_valid_i(alu_disp_req_valid),
    .alu_disp_reqs_ready_o(alu_disp_req_ready),
    .alu_disp_rsp_o       (alu_disp_rsp),
    .alu_loop_finish_o    (), // unused because of all_rs_finish_i
    .alu_rs_full_o        (alu_rs_full),
    // LSU
    .lsu_disp_reqs_valid_i(lsu_disp_req_valid),
    .lsu_disp_reqs_ready_o(lsu_disp_req_ready),
    .lsu_disp_rsp_o       (lsu_disp_rsp),
    .lsu_empty_o          (lsu_empty),
    .lsu_addr_misaligned_o(lsu_addr_misaligned),
    .lsu_dreq_o           (data_req_o), // Each LSU has its own reqrsp port
    .lsu_drsp_i           (data_rsp_i), // Each LSU has its own reqrsp port
    .lsu_loop_finish_o    (), // unused because of all_rs_finish_i
    .lsu_rs_full_o        (lsu_rs_full),
    .caq_addr_i           ('0),
    .caq_track_write_i    ('0),
    .caq_req_valid_i      ('0),
    .caq_req_ready_o      (),
    .caq_rsp_valid_i      ('0),
    .caq_rsp_valid_o      (),
    //FPU
    .fpu_disp_reqs_valid_i(fpu_disp_req_valid),
    .fpu_disp_reqs_ready_o(fpu_disp_req_ready),
    .fpu_disp_rsp_o       (fpu_disp_rsp),
    .fpu_loop_finish_o    (), // unused because of all_rs_finish_i
    .fpu_rs_full_o        (fpu_rs_full),
    .fpu_status_o         (fpu_status),
    .fpu_status_valid_o   (fpu_status_valid),
    // ALU WB
    .alu_wb_result_o      (alu_result),
    .alu_wb_result_tag_o  (alu_result_tag),
    .alu_wb_result_valid_o(alu_result_valid),
    .alu_wb_result_ready_i(alu_result_ready),
    .branch_result_o      (branch_result),
    // LSU WB
    .lsu_wb_result_o      (lsu_result),
    .lsu_wb_result_tag_o  (lsu_result_tag),
    .lsu_wb_result_valid_o(lsu_result_valid),
    .lsu_wb_result_ready_i(lsu_result_ready),
    // FPU WB
    .fpu_wb_result_o      (fpu_result),
    .fpu_wb_result_tag_o  (fpu_result_tag),
    .fpu_wb_result_valid_o(fpu_result_valid),
    .fpu_wb_result_ready_i(fpu_result_ready)
  );

  // CSR FU & register file
  // Has direct connection to control logic, exceptions are handled directly without the commit guard.
  // I.e., the CSR always checks for exception but the controller masks it out if the current
  //instruction isn't a CSR instruction.
  // TODO: Maybe we should unify the behaviour?
  logic csr_result_valid;
  logic csr_result_ready;
  instr_tag_t csr_result_tag;
  logic [XLEN-1:0] csr_result;

  schnizo_csr #(
    .XLEN        (XLEN),
    .DebugSupport(0),
    .RVF         (RVF),
    .RVD         (RVD),
    .Xdma        (Xdma),
    .VMSupport   (0),
    .issue_req_t (issue_req_t),
    .result_tag_t(instr_tag_t),
    .NofAlus     (NofAlus),
    .AluNofRss   (AluNofRss),
    .NofLsus     (NofLsus),
    .LsuNofRss   (LsuNofRss),
    .NofFpus     (NofFpus),
    .FpuNofRss   (FpuNofRss)
  ) i_csr (
    .clk_i(clk_i),
    .rst_i(rst_i),

    .issue_req_i        (issue_req),
    .issue_req_valid_i  (csr_disp_req_valid),
    .issue_req_ready_o  (csr_disp_req_ready),
    .illegal_csr_instr_o(csr_exception_raw),

    .result_o      (csr_result),
    .result_tag_o  (csr_result_tag),
    .result_valid_o(csr_result_valid),
    .result_ready_i(csr_result_ready),

    .irq_i                  (irq_i),
    .enter_wfi_i            (enter_wfi),
    .pc_i                   (pc),
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
    .frep_mem_cons_mode_o   (frep_mem_cons_mode),
    .fpu_status_i           (fpu_status),
    .fpu_status_valid_i     (fpu_status_valid),
    .fpu_rnd_mode_o         (fpu_rnd_mode),
    .fpu_fmt_mode_o         (fpu_fmt_mode),

    .instr_retired_i(instr_retired)
  );

  // ---------------------------
  // Write back
  // ---------------------------
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

  // See module for details and specialities!
  schnizo_writeback #(
    .XLEN           (XLEN),
    .FLEN           (FLEN),
    .NrIntWritePorts(NrIntWritePorts),
    .NrFpWritePorts (NrFpWritePorts),
    .RegAddrSize    (REG_ADDR_SIZE),
    .instr_tag_t    (instr_tag_t),
    .alu_result_t   (alu_result_t),
    .data_t         (data_t)
  ) i_schnizo_writeback (
    // ALU interface
    .alu_result_i      (alu_result),
    .alu_result_tag_i  (alu_result_tag),
    .alu_result_valid_i(alu_result_valid),
    .alu_result_ready_o(alu_result_ready),
    .consecutive_pc_i  (consecutive_pc),
    // CSR interface
    .csr_result_i      (csr_result),
    .csr_result_tag_i  (csr_result_tag),
    .csr_result_valid_i(csr_result_valid),
    .csr_result_ready_o(csr_result_ready),
    // LSU interface
    .lsu_result_i      (lsu_result),
    .lsu_result_tag_i  (lsu_result_tag),
    .lsu_result_valid_i(lsu_result_valid),
    .lsu_result_ready_o(lsu_result_ready),
    // FPU interface
    .fpu_result_i      (fpu_result),
    .fpu_result_tag_i  (fpu_result_tag),
    .fpu_result_valid_i(fpu_result_valid),
    .fpu_result_ready_o(fpu_result_ready),
    // Accelerator interface
    .acc_result_i      (acc_result),
    .acc_result_tag_i  (acc_result_tag),
    .acc_result_valid_i(acc_pvalid_i),
    .acc_result_ready_o(acc_pready_o),
    // Register file interface
    .gpr_waddr_o       (gpr_waddr),
    .gpr_wdata_o       (gpr_wdata),
    .gpr_we_o          (gpr_we),
    .fpr_waddr_o       (fpr_waddr),
    .fpr_wdata_o       (fpr_wdata),
    .fpr_we_o          (fpr_we),
    // Core events signals
    .retired_single_cycle_o(instr_retired_single_cycle),
    .retired_load_o        (instr_retired_load),
    .retired_acc_o         (instr_retired_acc)
  );

  // ---------------------------
  // Core Events
  // ---------------------------
  // This is 1to1 from Snitch and it is misnamed. The stall signal tells us that we did not
  // dispatch an instruction. However, it is used to signal if we retired an instruction right now.
  // We keep this inconsistency to match the Snitch behaviour. And in terms of performance, it
  // has no direct effect as each instruction eventually will retire. The reason for this approach
  // is that it can handle the retirement of multiple instructions at once in a simpler fashion.
  // For example, if we have a retiring load and an ALU instruction without writeback, we would
  // have to count both retirements. As we only have single issue capabilities, we can count the
  // instructions simpler during issuing them (one bit only).
  assign instr_retired = !stall;
  // Other retired X signals are generated in the write back.

  // Asserted when the FPU accepts an instruction. This kind of also counts the retired
  // instructions by the FPU.
  logic [NofFpus-1:0] all_issue_fpu_handshakes;
  for (genvar i = 0; i < NofFpus; i++) begin : gen_issue_fpu
    assign all_issue_fpu_handshakes[i] = fpu_disp_req_valid[i] & fpu_disp_req_ready[i];
  end
  assign issue_fpu = (|all_issue_fpu_handshakes) & instr_exec_commit;
  // In Snitch this signal captures when an instruction is offloaded to the FP SS. This can include
  // also FP loads as the FP register is in the subsystem. Schnizo cannot distinguish this case as
  // we handle all instructions in the core. We thus set the same signal.
  // TODO: rework the core events
  assign issue_core_to_fpu = (|all_issue_fpu_handshakes) & instr_exec_commit;

  assign core_events_o.retired_instr = instr_retired_q;
  assign core_events_o.retired_i     = instr_retired_single_cycle_q;
  assign core_events_o.retired_load  = instr_retired_load_q;
  assign core_events_o.retired_acc   = instr_retired_acc_q;

  assign core_events_o.issue_fpu         = issue_fpu_q;
  assign core_events_o.issue_core_to_fpu = issue_core_to_fpu_q;
  assign core_events_o.issue_fpu_seq     = '0;

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

  // --------------------------
  // Schnizo Tracer
  // --------------------------
  // The tracer first extracts all signals of interest and groups them by functional unit.
  // It also distinguishs between signal groups for regular and FREP exection.
  // The second part then emits a trace entry if the current signal group is valid (active).
  // The signal group validity depends on the handshake as well as the core state.

  // pragma translate_off

  typedef struct packed {
    priv_lvl_t   priv_level;
    loop_state_e state;
    logic        stall;
    logic        exception;
  } schnizo_core_trace_t;

  // Returns the header of a trace event. This includes common trace data as well as the first
  // basic extras. The ending } of the extras is missing.
  function automatic string format_trace_header(time t, logic[63:0] cycle, priv_lvl_t priv_lvl,
                                                loop_state_e loop_state, logic stall,
                                                logic exception);
    return $sformatf("%t %d %s %s #; {'stall': 0x%0x, 'exception': 0x%0x, ",
                     t, cycle, schnizo_pkg::priv_lvl_tostring(priv_lvl),
                     schnizo_pkg::loop_state_tostring(loop_state), stall, exception);
  endfunction

  typedef struct {
    logic   valid; // high if handshake happens
    longint pc_q;
    longint pc_d;
    longint instr_data;
    longint rs1;
    longint rs2;
    longint rs3; // for fused FPU instructions
    longint rd;
    longint rd_is_fp;
    longint is_branch; // jal & jalr are handled via pc_d (add goto if pc_d != pc_q + 4)
    longint branch_taken;
    // FU selection - with known number of FUs and RSS we can reconstruct which FU it was.
    // However, not all FUs (CSR, ACC) have a producer id. We provide both informations and the tracer
    // can select depending on the CPU state.
    string fu_type;
    string disp_resp;
  } schnizo_dispatch_trace_t;

  // Format all dispatch extras as a key value pair list.
  function automatic string format_dispatch_extras(schnizo_dispatch_trace_t trace);
    string extras = "";
    if (!trace.valid) begin
      return "";
    end
    extras = $sformatf("%s'%s':\"%s\", ", extras, "fu_type", trace.fu_type);
    extras = $sformatf("%s'%s':\"%s\", ", extras, "disp_resp", trace.disp_resp);
    extras = $sformatf("%s'%s':0x%08x, ", extras, "pc_q", trace.pc_q);
    extras = $sformatf("%s'%s':0x%08x, ", extras, "pc_d", trace.pc_d);
    extras = $sformatf("%s'%s':0x%08x, ", extras, "instr_data", trace.instr_data);
    extras = $sformatf("%s'%s':0x%02x, ", extras, "rs1", trace.rs1);
    extras = $sformatf("%s'%s':0x%02x, ", extras, "rs2", trace.rs2);
    extras = $sformatf("%s'%s':0x%02x, ", extras, "rs3", trace.rs3);
    extras = $sformatf("%s'%s':0x%02x, ", extras, "rd", trace.rd);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "rd_is_fp", trace.rd_is_fp);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "is_branch", trace.is_branch);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "branch_taken", trace.branch_taken);
    return extras;
  endfunction

  // Issues - used to track issues from RSS
  typedef struct {
    logic   valid; // high if handshake happens
    longint instr_iter;
    string  producer;
    longint alu_opa;
    longint alu_opb;
  } issue_alu_trace_t;
  function automatic string format_alu_trace(issue_alu_trace_t trace);
    string extras = "";
    if (!trace.valid) begin
      return "";
    end
    extras = $sformatf("%s'%s':0x%0x, ", extras, "instr_iter", trace.instr_iter);
    extras = $sformatf("%s'%s':\"%s\", ", extras, "producer", trace.producer);
    extras = $sformatf("%s'%s':0x%08x, ", extras, "alu_opa", trace.alu_opa);
    extras = $sformatf("%s'%s':0x%08x, ", extras, "alu_opb", trace.alu_opb);
    return extras;
  endfunction

  typedef struct {
    logic   valid; // high if handshake happens
    longint instr_iter;
    string  producer;
    longint lsu_store_data;
    longint lsu_is_float;
    longint lsu_is_load;
    longint lsu_is_store;
    longint lsu_addr; // the computed memory address
    longint lsu_size;
    longint lsu_amo;
    // we don't track the stored data
  } issue_lsu_trace_t;
  function automatic string format_lsu_trace(issue_lsu_trace_t trace);
    string extras = "";
    if (!trace.valid) begin
      return "";
    end
    extras = $sformatf("%s'%s':0x%0x, ", extras, "instr_iter", trace.instr_iter);
    extras = $sformatf("%s'%s':\"%s\", ", extras, "producer", trace.producer);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "lsu_store_data", trace.lsu_store_data);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "lsu_is_float", trace.lsu_is_float);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "lsu_is_load", trace.lsu_is_load);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "lsu_is_store", trace.lsu_is_store);
    extras = $sformatf("%s'%s':0x%08x, ", extras, "lsu_addr", trace.lsu_addr);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "lsu_size", trace.lsu_size);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "lsu_amo", trace.lsu_amo);
    return extras;
  endfunction

  typedef struct {
    logic   valid; // high if handshake happens
    longint instr_iter;
    string  producer;
    longint fpu_opa;
    longint fpu_opb;
    longint fpu_opc;
    longint fpu_src_fmt;
    longint fpu_dst_fmt;
    longint fpu_int_fmt;
  } issue_fpu_trace_t;
  function automatic string format_fpu_trace(issue_fpu_trace_t trace);
    string extras = "";
    if (!trace.valid) begin
      return "";
    end
    extras = $sformatf("%s'%s':0x%0x, ", extras, "instr_iter", trace.instr_iter);
    extras = $sformatf("%s'%s':\"%s\", ", extras, "producer", trace.producer);
    extras = $sformatf("%s'%s':0x%016x, ", extras, "fpu_opa", trace.fpu_opa);
    extras = $sformatf("%s'%s':0x%016x, ", extras, "fpu_opb", trace.fpu_opb);
    extras = $sformatf("%s'%s':0x%016x, ", extras, "fpu_opc", trace.fpu_opc);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "fpu_src_fmt", trace.fpu_src_fmt);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "fpu_dst_fmt", trace.fpu_dst_fmt);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "fpu_int_fmt", trace.fpu_int_fmt);
    return extras;
  endfunction

  typedef struct {
    logic   valid; // high if handshake happens
    string  producer;
    longint csr_addr;
    longint csr_read_data;
    longint csr_write_data;
  } issue_csr_trace_t;
  function automatic string format_csr_trace(issue_csr_trace_t trace);
    string extras = "";
    if (!trace.valid) begin
      return "";
    end
    extras = $sformatf("%s'%s':\"%s\", ", extras, "producer", trace.producer);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "csr_addr", trace.csr_addr);
    extras = $sformatf("%s'%s':0x%08x, ", extras, "csr_read_data", trace.csr_read_data);
    extras = $sformatf("%s'%s':0x%08x, ", extras, "csr_write_data", trace.csr_write_data);
    return extras;
  endfunction

  typedef struct {
    logic   valid; // high if handshake happens
    string  producer;
    longint acc_addr;
    longint acc_arga;
    longint acc_argb;
    longint acc_argc;
  } issue_acc_trace_t;
  function automatic string format_acc_trace(issue_acc_trace_t trace);
    string extras = "";
    if (!trace.valid) begin
      return "";
    end
    extras = $sformatf("%s'%s':\"%s\", ", extras, "producer", trace.producer);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "acc_addr", trace.acc_addr);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "acc_arga", trace.acc_arga);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "acc_argb", trace.acc_argb);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "acc_argc", trace.acc_argc);
    return extras;
  endfunction

  // retirements - only for LSU to measure the latency
  typedef struct {
    logic   valid; // high if handshake happens
    string  producer;
  } retire_fu_trace_t;
  function automatic string format_fu_retire_trace(retire_fu_trace_t trace);
    string extras = "";
    if (!trace.valid) begin
      return "";
    end
    extras = $sformatf("%s'%s':\"%s\", ", extras, "producer", trace.producer);
    return extras;
  endfunction

  // writebacks
  typedef struct {
    logic   valid; // high if handshake happens
    longint fu_result;
    longint fu_rd;
    longint fu_rd_is_fp;
  } wb_fu_trace_t;
  function automatic string format_wb_fu_trace(wb_fu_trace_t trace, string fu);
    string extras = "";
    if (!trace.valid) begin
      return "";
    end
    extras = $sformatf("%s'%s':\"%s\", ", extras, "origin", fu);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "result", trace.fu_result);
    extras = $sformatf("%s'%s':0x%02x, ", extras, "rd", trace.fu_rd);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "rd_is_fp", trace.fu_rd_is_fp);
    return extras;
  endfunction

  // Result requests
  typedef struct {
    logic   valid; // high if handshake happens
    string  producer; // to here this request comes
    string  consumer; // from here this requests originated
    longint requested_iter;
  } resreq_trace_t;
  function automatic string format_resreq_trace(resreq_trace_t trace);
    string extras = "";
    if (!trace.valid) begin
      return "";
    end
    extras = $sformatf("%s'%s':\"%s\", ", extras, "producer", trace.producer);
    extras = $sformatf("%s'%s':\"%s\", ", extras, "consumer", trace.consumer);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "requested_iter", trace.requested_iter);
    return extras;
  endfunction

  // Result captures
  typedef struct {
    logic   valid; // high if handshake happens
    string  producer;
    longint result_iter;
    longint enable_rf_wb;
    longint rd;
    longint rd_is_fp;
    longint result;
  } rescap_trace_t;
  function automatic string format_rescap_trace(rescap_trace_t trace);
    string extras = "";
    if (!trace.valid) begin
      return "";
    end
    extras = $sformatf("%s'%s':\"%s\", ", extras, "producer", trace.producer);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "result_iter", trace.result_iter);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "enable_rf_wb", trace.enable_rf_wb);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "rd", trace.rd);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "rd_is_fp", trace.rd_is_fp);
    extras = $sformatf("%s'%s':0x%0x, ", extras, "result", trace.result);
    return extras;
  endfunction

  // General traces and for regular execution
  schnizo_core_trace_t     core_trace;
  schnizo_dispatch_trace_t dispatch_trace;
  // Traces for regular execution
  issue_alu_trace_t alu_trace [NofAlus];
  issue_lsu_trace_t lsu_trace [NofLsus];
  issue_fpu_trace_t fpu_trace [NofFpus];
  issue_csr_trace_t csr_trace;
  issue_acc_trace_t acc_trace;
  // Traces for RSS issues
  issue_alu_trace_t rss_alu_traces [NofAlus][AluNofRss];
  issue_alu_trace_t rss_alu_traces_empty;
  issue_lsu_trace_t rss_lsu_traces [NofLsus][LsuNofRss];
  issue_lsu_trace_t rss_lsu_traces_empty;
  issue_fpu_trace_t rss_fpu_traces [NofFpus][FpuNofRss];
  issue_fpu_trace_t rss_fpu_traces_empty;

  assign rss_alu_traces_empty = '{
    valid: '0,
    instr_iter: '0,
    producer: "",
    alu_opa: '0,
    alu_opb: '0
  };

  assign rss_lsu_traces_empty = '{
    valid:          1'b0,
    instr_iter:     '0,
    producer:       "",
    lsu_store_data: '0,
    lsu_is_float:   '0,
    lsu_is_load:    '0,
    lsu_is_store:   '0,
    lsu_addr:       '0,
    lsu_size:       '0,
    lsu_amo:        '0
  };

  assign rss_fpu_traces_empty = '{
    valid:       1'b0,
    instr_iter:  '0,
    producer:    "",
    fpu_opa:     '0,
    fpu_opb:     '0,
    fpu_opc:     '0,
    fpu_src_fmt: '0,
    fpu_dst_fmt: '0,
    fpu_int_fmt: '0
  };

  // Traces for retirements
  retire_fu_trace_t alu_retirements [NofAlus];
  retire_fu_trace_t lsu_retirements [NofLsus];
  retire_fu_trace_t fpu_retirements [NofFpus];
  retire_fu_trace_t csr_retirement;
  retire_fu_trace_t acc_retirement;
  // Traces for writeback (regular and RSS)
  wb_fu_trace_t alu_wb_trace;
  wb_fu_trace_t lsu_wb_trace;
  wb_fu_trace_t fpu_wb_trace;
  wb_fu_trace_t csr_wb_trace;
  wb_fu_trace_t acc_wb_trace;
  // Traces for result requests (each RSS has one signal per request crossbar output)
  resreq_trace_t alu_resreq_traces [NofAlus][AluNofRss][NofOperandIfs];
  resreq_trace_t lsu_resreq_traces [NofLsus][LsuNofRss][NofOperandIfs];
  resreq_trace_t fpu_resreq_traces [NofFpus][FpuNofRss][NofOperandIfs];
  resreq_trace_t reqreq_trace_empty;

  assign reqreq_trace_empty = '{
    valid:          '0,
    producer:       "",
    consumer:       "",
    requested_iter: '0
  };

  // Traces for result captures (each RSS has one signal)
  rescap_trace_t alu_rescap_traces [NofAlus][AluNofRss];
  rescap_trace_t lsu_rescap_traces [NofLsus][LsuNofRss];
  rescap_trace_t fpu_rescap_traces [NofFpus][FpuNofRss];
  rescap_trace_t rescap_trace_empty;

  assign rescap_trace_empty = '{
    valid:        '0,
    producer:     "",
    result_iter:  '0,
    enable_rf_wb: '0,
    rd:           '0,
    rd_is_fp:     '0,
    result:       '0
  };

  assign core_trace = '{
    priv_level: priv_lvl,
    state:      loop_state,
    stall:      stall,
    exception:  exception
  };

  assign dispatch_trace = '{
    valid:        i_schnizo_controller.instr_dispatched,
    pc_q:         i_schnizo_controller.pc_q,
    pc_d:         i_schnizo_controller.pc_d,
    instr_data:   instr_fetch_data_i,
    rs1:          instr_decoded.rs1,
    rs2:          instr_decoded.rs2,
    rs3:          instr_decoded.imm, // fused FPU instructions use imm as operand
    rd:           instr_decoded.rd,
    rd_is_fp:     instr_decoded.rd_is_fp,
    is_branch:    instr_decoded.is_branch,
    branch_taken: alu_result.compare_res,
    fu_type:      schnizo_pkg::fu_to_string(instr_decoded.fu),
    disp_resp:    i_fu_stage.producer_to_string(i_schnizo_dispatcher.fu_response.producer)
  };

  for (genvar alu = 0; alu < NofAlus; alu++) begin : gen_alu_traces
    assign alu_trace[alu] = '{
      valid:          i_fu_stage.gen_alus[alu].alu_issue_req_valid &&
                      i_fu_stage.gen_alus[alu].alu_issue_req_ready,
      instr_iter:     '0, // does not apply in regular execution
      producer:       $sformatf("ALU%0d", alu), // does not apply in regular execution
      alu_opa:        i_fu_stage.gen_alus[alu].alu_issue_req.fu_data.operand_a[XLEN-1:0],
      alu_opb:        i_fu_stage.gen_alus[alu].alu_issue_req.fu_data.operand_b[XLEN-1:0]
    };

    assign alu_retirements[alu] = '{
      valid:    i_fu_stage.gen_alus[alu].alu_result_valid &&
                i_fu_stage.gen_alus[alu].alu_result_ready,
      producer: i_fu_stage.rs_to_string(i_fu_stage.gen_alus[alu].producer_start_id.rs_id)
    };

    for (genvar rss = 0; rss < AluNofRss; rss++) begin : gen_alu_traces_rss
      // verilog_lint: waive-start line-length
      if (Xfrep) begin : gen_alu_traces_rss_trace_resreq
        assign rss_alu_traces[alu][rss] = '{
          valid:          i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.issue_reqs_valid[rss] &&
                          i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.issue_reqs_ready[rss],
          instr_iter:     i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_q.instruction_iter,
          producer:       i_fu_stage.producer_to_string(
                            i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.own_producer_id_i),
          alu_opa:        i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.issue_reqs[rss].fu_data.operand_a[XLEN-1:0],
          alu_opb:        i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.issue_reqs[rss].fu_data.operand_b[XLEN-1:0]
        };
        assign alu_rescap_traces[alu][rss] = '{
          valid:          (i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.rss_wb_valid &&
                          i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.rss_wb_ready) &&
                          !i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.is_store,
          producer:       i_fu_stage.producer_to_string(
                            i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.own_producer_id_i),
          result_iter:    i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.result.iteration,
          enable_rf_wb:   i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.enable_rf_writeback,
          rd:             i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.dest_id,
          rd_is_fp:       i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.dest_is_fp,
          result:         i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.result.value
        };
      end else begin : gen_alu_traces_rss_no_trace_resreq
        assign rss_alu_traces[alu][rss]      = rss_alu_traces_empty;
        assign alu_rescap_traces[alu][rss] = rescap_trace_empty;
      end
      // each consumer can place a result request simultaneously
      for (genvar con = 0; con < NofOperandIfs; con++) begin : gen_alu_traces_rss_resreq
        if (Xfrep) begin : gen_alu_traces_rss_resreq_frep
          assign alu_resreq_traces[alu][rss][con] = '{
            valid:          i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.dest_masks_valid[rss] &&
                            i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.dest_masks_ready[rss] &&
                            i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.dest_masks[rss][con],
            producer:       i_fu_stage.producer_to_string(
                              i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.own_producer_id_i),
            consumer:       i_fu_stage.consumer_to_string(con),
            // we only forward requests which we can serve. Thus we can take the current result iteration.
            requested_iter: i_fu_stage.gen_alus[alu].i_alu_block.gen_superscalar.i_res_stat.res_iters[rss]
          };
        end else begin : gen_alu_traces_rss_no_resreq
          assign alu_resreq_traces[alu][rss][con] = reqreq_trace_empty;
        end
      end
      // verilog_lint: waive-stop line-length
    end
  end

  for (genvar lsu = 0; lsu < NofLsus; lsu++) begin : gen_lsu_traces
    assign lsu_trace[lsu] = '{
      valid:          i_fu_stage.gen_lsus[lsu].lsu_issue_req_valid &&
                      i_fu_stage.gen_lsus[lsu].lsu_issue_req_ready,
      instr_iter:     '0, // does not apply in regular execution
      producer:       $sformatf("LSU%0d", lsu), // does not apply in regular execution
      lsu_store_data: i_fu_stage.gen_lsus[lsu].i_lsu.store_data,
      lsu_is_float:   i_fu_stage.gen_lsus[lsu].i_lsu.do_nan_boxing, // misuse this signal
      lsu_is_load:    !i_fu_stage.gen_lsus[lsu].i_lsu.is_store,
      lsu_is_store:   i_fu_stage.gen_lsus[lsu].i_lsu.is_store,
      lsu_addr:       i_fu_stage.gen_lsus[lsu].i_lsu.address_sys,
      lsu_size:       i_fu_stage.gen_lsus[lsu].i_lsu.ls_size,
      lsu_amo:        i_fu_stage.gen_lsus[lsu].i_lsu.ls_amo
    };

    assign lsu_retirements[lsu] = '{
      valid:    i_fu_stage.gen_lsus[lsu].lsu_result_valid &&
                i_fu_stage.gen_lsus[lsu].lsu_result_ready,
      producer: i_fu_stage.rs_to_string(i_fu_stage.gen_lsus[lsu].producer_start_id.rs_id)
    };

    for (genvar rss = 0; rss < LsuNofRss; rss++) begin : gen_lsu_traces_rss
      // verilog_lint: waive-start line-length
      if (Xfrep) begin : gen_lsu_traces_rss_trace_resreq
        assign rss_lsu_traces[lsu][rss] = '{
          valid:          i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.issue_reqs_valid[rss] &&
                          i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.issue_reqs_ready[rss],
          instr_iter:     i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_q.instruction_iter,
          producer:       i_fu_stage.producer_to_string(
                            i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.own_producer_id_i),
          // Directly access the LSU because theses signals are decoded in the LSU. This requires
          // that there is no cut between the RSS and the LSU.
          lsu_store_data: i_fu_stage.gen_lsus[lsu].i_lsu.store_data,
          lsu_is_float:   i_fu_stage.gen_lsus[lsu].i_lsu.do_nan_boxing, // misuse this signal
          lsu_is_load:    !i_fu_stage.gen_lsus[lsu].i_lsu.is_store,
          lsu_is_store:   i_fu_stage.gen_lsus[lsu].i_lsu.is_store,
          lsu_addr:       i_fu_stage.gen_lsus[lsu].i_lsu.address_sys,
          lsu_size:       i_fu_stage.gen_lsus[lsu].i_lsu.ls_size,
          lsu_amo:        i_fu_stage.gen_lsus[lsu].i_lsu.ls_amo
        };
        assign lsu_rescap_traces[lsu][rss] = '{
          valid:          (i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.rss_wb_valid &&
                          i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.rss_wb_ready) &&
                          !i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.is_store,
          producer:       i_fu_stage.producer_to_string(
                            i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.own_producer_id_i),
          result_iter:    i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.result.iteration,
          enable_rf_wb:   i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.enable_rf_writeback,
          rd:             i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.dest_id,
          rd_is_fp:       i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.dest_is_fp,
          result:         i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.result.value
        };
      end else begin : gen_lsu_traces_rss_no_trace_resreq
        assign rss_lsu_traces[lsu][rss]    = rss_lsu_traces_empty;
        assign lsu_rescap_traces[lsu][rss] = rescap_trace_empty;
      end
      // each consumer can place a result request simultaneously
      for (genvar con = 0; con < NofOperandIfs; con++) begin : gen_lsu_traces_rss_reqreq
        if (Xfrep) begin : gen_lsu_traces_rss_resreq_frep
          assign lsu_resreq_traces[lsu][rss][con] = '{
            valid:          i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.dest_masks_valid[rss] &&
                            i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.dest_masks_ready[rss] &&
                            i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.dest_masks[rss][con],
            producer:       i_fu_stage.producer_to_string(
                              i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.own_producer_id_i),
            consumer:       i_fu_stage.consumer_to_string(con),
            // we only forward requests which we can serve. Thus we can take the current result iteration.
            requested_iter: i_fu_stage.gen_lsus[lsu].i_lsu_block.gen_superscalar.i_res_stat.res_iters[rss]
          };
        end else begin : gen_lsu_traces_rss_no_resreq
          assign lsu_resreq_traces[lsu][rss][con] = reqreq_trace_empty;
        end
      end
      // verilog_lint: waive-stop line-length
    end
  end

  for (genvar fpu = 0; fpu < NofFpus; fpu++) begin : gen_fpu_traces
    assign fpu_trace[fpu] = '{
      valid:       i_fu_stage.gen_fpus[fpu].fpu_issue_req_valid &&
                   i_fu_stage.gen_fpus[fpu].fpu_issue_req_ready,
      instr_iter:  '0, // does not apply in regular execution
      producer:    $sformatf("FPU%0d", fpu), // does not apply in regular execution
      fpu_opa:     i_fu_stage.gen_fpus[fpu].fpu_issue_req.fu_data.operand_a,
      fpu_opb:     i_fu_stage.gen_fpus[fpu].fpu_issue_req.fu_data.operand_b,
      fpu_opc:     i_fu_stage.gen_fpus[fpu].fpu_issue_req.fu_data.imm,
      fpu_src_fmt: i_fu_stage.gen_fpus[fpu].fpu_issue_req.fu_data.fpu_fmt_src,
      fpu_dst_fmt: i_fu_stage.gen_fpus[fpu].fpu_issue_req.fu_data.fpu_fmt_dst,
      fpu_int_fmt: i_fu_stage.gen_fpus[fpu].i_fpu.int_fmt
    };

    assign fpu_retirements[fpu] = '{
      valid:    i_fu_stage.fpu_result_valid[fpu] &&
                i_fu_stage.fpu_result_ready[fpu],
      producer: i_fu_stage.rs_to_string(i_fu_stage.gen_fpus[fpu].producer_start_id.rs_id)
    };

    for (genvar rss = 0; rss < FpuNofRss; rss++) begin : gen_fpu_traces_rss
      // verilog_lint: waive-start line-length
      if (Xfrep) begin : gen_fpu_traces_rss_trace
        assign rss_fpu_traces[fpu][rss] = '{
          valid:       i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.issue_reqs_valid[rss] &&
                      i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.issue_reqs_ready[rss],
          instr_iter:  i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_q.instruction_iter,
          producer:    i_fu_stage.producer_to_string(
                        i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.own_producer_id_i),
          fpu_opa:     i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.issue_reqs[rss].fu_data.operand_a,
          fpu_opb:     i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.issue_reqs[rss].fu_data.operand_b,
          fpu_opc:     i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.issue_reqs[rss].fu_data.imm,
          fpu_src_fmt: i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.issue_reqs[rss].fu_data.fpu_fmt_src,
          fpu_dst_fmt: i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.issue_reqs[rss].fu_data.fpu_fmt_dst,
          // Directly access the FPU because theses signals are decoded in the FPU. This requires
          // that there is no cut between the RSS and the FPU.
          fpu_int_fmt:    i_fu_stage.gen_fpus[fpu].i_fpu.int_fmt
        };
        assign fpu_rescap_traces[fpu][rss] = '{
          valid:          (i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.rss_wb_valid &&
                           i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.rss_wb_ready) &&
                          !i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.is_store,
          producer:       i_fu_stage.producer_to_string(
                            i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.own_producer_id_i),
          result_iter:    i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.result.iteration,
          enable_rf_wb:   i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.enable_rf_writeback,
          rd:             i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.dest_id,
          rd_is_fp:       i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.dest_is_fp,
          result:         i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.slot_wb.result.value
        };
      end else begin : gen_fpu_traces_no_rss
        assign rss_fpu_traces[fpu][rss]    = rss_fpu_traces_empty;
        assign fpu_rescap_traces[fpu][rss] = rescap_trace_empty;
      end
      // each consumer can place a result request simultaneously
      for (genvar con = 0; con < NofOperandIfs; con++) begin : gen_fpu_traces_rss_resreq
        if (Xfrep) begin : gen_fpu_traces_rss_resreq_frep
          assign fpu_resreq_traces[fpu][rss][con] = '{
            valid:          i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.dest_masks_valid[rss] &&
                            i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.dest_masks_ready[rss] &&
                            i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.dest_masks[rss][con],
            producer:       i_fu_stage.producer_to_string(
                              i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.gen_rss[rss].i_rss.own_producer_id_i),
            consumer:       i_fu_stage.consumer_to_string(con),
            // we only forward requests which we can serve. Thus we can take the current result iteration.
            requested_iter: i_fu_stage.gen_fpus[fpu].i_fpu_block.gen_superscalar.i_res_stat.res_iters[rss]
          };
        end else begin : gen_fpu_traces_no_resreq
          assign fpu_resreq_traces[fpu][rss][con] = reqreq_trace_empty;
        end
      end
      // verilog_lint: waive-stop line-length
    end
  end

  assign csr_trace = '{
    valid:          csr_disp_req_valid && csr_disp_req_ready,
    producer:       "CSR",
    csr_addr:       i_csr.csr_addr.address,
    csr_read_data:  i_csr.csr_rdata,
    csr_write_data: i_csr.csr_wdata
  };

  // The CSR is fixed to the ALU0
  assign csr_retirement = '{
    // The CSR does not always write back to the register file. But all instructions are single
    // cycle. Thus we can use the CSR dispatch request to determine the retirement.
    valid: csr_disp_req_valid && csr_disp_req_ready,
    producer: "CSR"
  };

  assign acc_trace = '{
    valid:    acc_qvalid_o && acc_qready_i,
    producer: "ACC", // There is no address on the response.
    acc_addr: acc_qreq_o.addr,
    acc_arga: acc_qreq_o.data_arga,
    acc_argb: acc_qreq_o.data_argb,
    acc_argc: acc_qreq_o.data_argc
  };

  assign acc_retirement = '{
    valid:    acc_pvalid_i && acc_pready_o,
    producer: "ACC" // There is no address on the response.
  };

  // Writebacks
  assign alu_wb_trace = '{
    valid:       alu_result_valid && alu_result_ready,
    fu_result:   alu_result.result,
    fu_rd:       alu_result_tag.dest_reg,
    fu_rd_is_fp: alu_result_tag.dest_reg_is_fp
  };

  assign lsu_wb_trace = '{
    valid:       lsu_result_valid && lsu_result_ready,
    fu_result:   lsu_result,
    fu_rd:       lsu_result_tag.dest_reg,
    fu_rd_is_fp: lsu_result_tag.dest_reg_is_fp
  };

  assign fpu_wb_trace = '{
    valid:       fpu_result_valid && fpu_result_ready,
    fu_result:   fpu_result,
    fu_rd:       fpu_result_tag.dest_reg,
    fu_rd_is_fp: fpu_result_tag.dest_reg_is_fp
  };

  assign csr_wb_trace = '{
    valid:       csr_result_valid && csr_result_ready,
    fu_result:   csr_result,
    fu_rd:       csr_result_tag.dest_reg,
    fu_rd_is_fp: csr_result_tag.dest_reg_is_fp
  };

  assign acc_wb_trace  = '{
    valid:       acc_pvalid_i && acc_pready_o,
    fu_result:   acc_result,
    fu_rd:       acc_result_tag.dest_reg,
    fu_rd_is_fp: acc_result_tag.dest_reg_is_fp
  };

  // 2nd part: Emitting events when they are ready. We start with result requests then issuing
  // events and end with the writeback events. This helps to order the events for postprocessing.
  function automatic void write_trace_event(int file_id, string trace_header, string event_type,
                                            string trace_extras, logic trace_valid);
    string trace_event;
    trace_event = $sformatf("%s'event':\"%s\", %s", trace_header, event_type, trace_extras);
    if (trace_valid) begin
      // close the extra key value list
      $fwrite(file_id,  $sformatf("%s}\n", trace_event));
    end
  endfunction

  int file_id;
  string file_name;
  logic [63:0] cycle;
  initial begin
    // We need to schedule the assignment into a safe region, otherwise
    // `hart_id_i` won't have a value assigned at the beginning of the first
    // delta cycle.
`ifndef VERILATOR
    #0;
`endif
    $system("mkdir logs -p");
    $sformat(file_name, "logs/sz_trace_hart_%05x.dasm", hart_id_i);
    file_id = $fopen(file_name, "w");
    $display("[Tracer] Logging Hart %d to %s", hart_id_i, file_name);
  end

  // Keep the current trace header and dispatch event to reuse it when the actual dispatch happens
  // during LCP.
  schnizo_dispatch_trace_t dispatch_trace_q;
  logic lcp_disp_happened_q;

  typedef struct packed {
    schnizo_core_trace_t core_trace;
  } header_info_t;

  header_info_t prev_header_q, prev_header_d;

  assign prev_header_d = '{
    core_trace: core_trace
  };

  `FFAR(prev_header_q, prev_header_d, '0, clk_i, rst_i);

  always_ff @(posedge clk_i) begin
    if (~rst_i) begin
      dispatch_trace_q    <= dispatch_trace;
      lcp_disp_happened_q <= dispatch_trace.valid && (loop_state inside {LoopLcp1, LoopLcp2});
    end else begin
      dispatch_trace_q    <= dispatch_trace;
      lcp_disp_happened_q <= '0;
    end
  end

  // verilog_lint: waive-start always-ff-non-blocking
  always_ff @(posedge clk_i) begin
    string trace_header;
    string prev_trace_header;
    string dispatch_event;
    if (~rst_i) begin
      cycle++;

      // Always generate the core trace. This trace serves as the basis of the trace event.
      // This trace is extended with the details of the active FU.
      trace_header = format_trace_header($time, cycle, core_trace.priv_level, core_trace.state,
                                         core_trace.stall, core_trace.exception);

      // TODO: HACK!! How can the time of the previous cycle be captured? Assinging $time to a FF
      //       does not work... For now hard code the clock period to 1ns. If the clock is changed,
      //       during LCP all dispatche events in the trace will have a wrong simulation time.
      prev_trace_header = format_trace_header($time-1ns, cycle - 1,
                                              prev_header_q.core_trace.priv_level,
                                              prev_header_q.core_trace.state,
                                              prev_header_q.core_trace.stall,
                                              prev_header_q.core_trace.exception);

      // TODO: We should create a class to capture all the common functions...

      // Result request events - these should only be active during LCP and LEP.
      // We can capture them "always".
      for (int alu = 0; alu < NofAlus; alu++) begin
        for (int rss = 0; rss < AluNofRss; rss++) begin
          for (int con = 0; con < NofOperandIfs; con++) begin
            write_trace_event(file_id, trace_header, "resreq",
                              format_resreq_trace(alu_resreq_traces[alu][rss][con]),
                              alu_resreq_traces[alu][rss][con].valid);
          end
        end
      end
      for (int lsu = 0; lsu < NofLsus; lsu++) begin
        for (int rss = 0; rss < FpuNofRss; rss++) begin
          for (int con = 0; con < NofOperandIfs; con++) begin
            write_trace_event(file_id, trace_header, "resreq",
                              format_resreq_trace(lsu_resreq_traces[lsu][rss][con]),
                              lsu_resreq_traces[lsu][rss][con].valid);
          end
        end
      end
      for (int fpu = 0; fpu < NofFpus; fpu++) begin
        for (int rss = 0; rss < FpuNofRss; rss++) begin
          for (int con = 0; con < NofOperandIfs; con++) begin
            write_trace_event(file_id, trace_header, "resreq",
                              format_resreq_trace(fpu_resreq_traces[fpu][rss][con]),
                              fpu_resreq_traces[fpu][rss][con].valid);
          end
        end
      end

      // Trace events are active depending on CPU states.
      if (loop_state inside {LoopRegular, LoopHwLoop}) begin
        // Format the single dispatch event and append all single issue requests. There should
        // only be one active single issue request. The format functions return "" if the trace is
        // not valid. Therefore, we can combine the formatting functions into one chain.
        // The naked dispatch_event contains the None FU dispatches (currently only for FREP).
        dispatch_event = format_dispatch_extras(dispatch_trace);

        for (int alu = 0; alu < NofAlus; alu++) begin
          dispatch_event = $sformatf("%s%s", dispatch_event, format_alu_trace(alu_trace[alu]));
        end
        for (int lsu = 0; lsu < NofLsus; lsu++) begin
          dispatch_event = $sformatf("%s%s", dispatch_event, format_lsu_trace(lsu_trace[lsu]));
        end
        for (int fpu = 0; fpu < NofFpus; fpu++) begin
          dispatch_event = $sformatf("%s%s", dispatch_event, format_fpu_trace(fpu_trace[fpu]));
        end
        dispatch_event = $sformatf("%s%s", dispatch_event, format_csr_trace(csr_trace));
        dispatch_event = $sformatf("%s%s", dispatch_event, format_acc_trace(acc_trace));

        write_trace_event(file_id, trace_header, "dispatch", dispatch_event, dispatch_trace.valid);
      end else if (loop_state inside {LoopLcp1, LoopLcp2}) begin
        // Format the single dispatch event but capture the producer by taking RSS issue trace.
        // There should also be one FU issue request active. Invalid traces are formated as "".

        if (lcp_disp_happened_q) begin
          // In the previous cycle we dispatched an instruction and it is now issued
          // Take the trace from the previous cycle.
          dispatch_event = format_dispatch_extras(dispatch_trace_q);

          for (int alu = 0; alu < NofAlus; alu++) begin
            for (int rss = 0; rss < AluNofRss; rss++) begin
              dispatch_event = $sformatf("%s%s", dispatch_event,
                                        format_alu_trace(rss_alu_traces[alu][rss]));
            end
          end
          for (int lsu = 0; lsu < NofLsus; lsu++) begin
            for (int rss = 0; rss < LsuNofRss; rss++) begin
              dispatch_event = $sformatf("%s%s", dispatch_event,
                                        format_lsu_trace(rss_lsu_traces[lsu][rss]));
            end
          end
          for (int fpu = 0; fpu < NofFpus; fpu++) begin
            for (int rss = 0; rss < FpuNofRss; rss++) begin
              dispatch_event = $sformatf("%s%s", dispatch_event,
                                        format_fpu_trace(rss_fpu_traces[fpu][rss]));
            end
          end
          // CSR and ACC instructions are not supported in FREP. These should never be valid.
          dispatch_event = $sformatf("%s%s", dispatch_event, format_csr_trace(csr_trace));
          dispatch_event = $sformatf("%s%s", dispatch_event, format_acc_trace(acc_trace));

          write_trace_event(file_id, prev_trace_header, "dispatch",
                            dispatch_event, dispatch_trace_q.valid);
        end
      end else if (loop_state inside {LoopLep}) begin
        // There is no dispatch request and we can have multiple events per cycle.
        // We must check each RSS issue request on its own.
        for (int alu = 0; alu < NofAlus; alu++) begin
          for (int rss = 0; rss < AluNofRss; rss++) begin
            write_trace_event(file_id, trace_header, "dispatch",
                             format_alu_trace(rss_alu_traces[alu][rss]),
                             rss_alu_traces[alu][rss].valid);
          end
        end
        for (int lsu = 0; lsu < NofLsus; lsu++) begin
          for (int rss = 0; rss < FpuNofRss; rss++) begin
            write_trace_event(file_id, trace_header, "dispatch",
                             format_lsu_trace(rss_lsu_traces[lsu][rss]),
                             rss_lsu_traces[lsu][rss].valid);
          end
        end
        for (int fpu = 0; fpu < NofFpus; fpu++) begin
          for (int rss = 0; rss < FpuNofRss; rss++) begin
            write_trace_event(file_id, trace_header, "dispatch",
                             format_fpu_trace(rss_fpu_traces[fpu][rss]),
                             rss_fpu_traces[fpu][rss].valid);
          end
        end
        // No CSR and ACC events possible
      end else begin
        $warning("Current CPU state (%s) not supported by tracer!",
                 schnizo_pkg::loop_state_tostring(loop_state));
      end

      // Writeback events - We must consider all writebacks at all times.
      write_trace_event(file_id, trace_header, "writeback",
                        format_wb_fu_trace(alu_wb_trace, "ALU"),
                        alu_wb_trace.valid);
      write_trace_event(file_id, trace_header, "writeback",
                        format_wb_fu_trace(lsu_wb_trace, "LSU"),
                        lsu_wb_trace.valid);
      write_trace_event(file_id, trace_header, "writeback",
                        format_wb_fu_trace(fpu_wb_trace, "FPU"),
                        fpu_wb_trace.valid);
      write_trace_event(file_id, trace_header, "writeback",
                        format_wb_fu_trace(csr_wb_trace, "CSR"),
                        csr_wb_trace.valid);
      write_trace_event(file_id, trace_header, "writeback",
                        format_wb_fu_trace(acc_wb_trace, "ACC"),
                        acc_wb_trace.valid);

      // Result capture events - We can always capture them
      // Retirement events - Always active to complete any issue.
      for (int alu = 0; alu < NofAlus; alu++) begin
        write_trace_event(file_id, trace_header, "retirement",
                          format_fu_retire_trace(alu_retirements[alu]),
                          alu_retirements[alu].valid);
        for (int rss = 0; rss < AluNofRss; rss++) begin
          write_trace_event(file_id, trace_header, "rescap",
                            format_rescap_trace(alu_rescap_traces[alu][rss]),
                            alu_rescap_traces[alu][rss].valid);
        end
      end
      for (int lsu = 0; lsu < NofLsus; lsu++) begin
        write_trace_event(file_id, trace_header, "retirement",
                          format_fu_retire_trace(lsu_retirements[lsu]),
                          lsu_retirements[lsu].valid);
        for (int rss = 0; rss < FpuNofRss; rss++) begin
          write_trace_event(file_id, trace_header, "rescap",
                            format_rescap_trace(lsu_rescap_traces[lsu][rss]),
                            lsu_rescap_traces[lsu][rss].valid);
        end
      end
      for (int fpu = 0; fpu < NofFpus; fpu++) begin
        write_trace_event(file_id, trace_header, "retirement",
                          format_fu_retire_trace(fpu_retirements[fpu]),
                          fpu_retirements[fpu].valid);
        for (int rss = 0; rss < FpuNofRss; rss++) begin
          write_trace_event(file_id, trace_header, "rescap",
                            format_rescap_trace(fpu_rescap_traces[fpu][rss]),
                            fpu_rescap_traces[fpu][rss].valid);
        end
      end
      write_trace_event(file_id, trace_header, "retirement",
                        format_fu_retire_trace(csr_retirement),
                        csr_retirement.valid);
      write_trace_event(file_id, trace_header, "retirement",
                        format_fu_retire_trace(acc_retirement),
                        acc_retirement.valid);
    end else begin
      cycle = '0;
    end
  end

  final begin
    $fclose(file_id);
  end

  // use "decrement_loop_iterations" to detect a jump during looping -> or check pc_q and pc_d

  // pragma translate_on

endmodule
