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
  /// Instruction cache flush request (for FENCE_I instruction)
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
    logic                     is_fence_i; // set if FENCE.I
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
    fu_data_t fu_data;
    instr_tag_t tag;
  } issue_req_t;

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
  logic [XLEN-1:0] consecutive_pc;

  fpnew_pkg::roundmode_e fpu_rnd_mode;
  fpnew_pkg::fmt_mode_t  fpu_fmt_mode;
  instr_dec_t instr_decoded;

  alu_result_t alu_result;
  instr_tag_t  alu_result_tag;
  logic [0:0]  lsu_empty;
  fpnew_pkg::status_t fpu_status;
  logic               fpu_status_valid;

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
  schnizo_controller #(
    .XLEN           (XLEN),
    .BootAddr       (BootAddr),
    .NrIntWritePorts(NrIntWritePorts),
    .NrFpWritePorts(NrFpWritePorts),
    .RegAddrSize(REG_ADDR_SIZE),
    .instr_dec_t(instr_dec_t),
    .priv_lvl_t(priv_lvl_t)
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
    // Interface to dispatcher
    .dispatch_instr_valid_o (dispatch_instr_valid),
    .dispatch_instr_ready_i (dispatch_instr_ready),
    .stall_o                (stall),
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
    .alu_compare_res_i      (alu_result.compare_res),
    .alu_result_i           (alu_result.result),
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
    .consecutive_pc_o(consecutive_pc),
    // GPR & FPR Write back snooping for Scoreboard
    .gpr_we_i               (gpr_we),
    .gpr_waddr_i            (gpr_waddr),
    .fpr_we_i               (fpr_we),
    .fpr_waddr_i            (fpr_waddr)
);

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
    .pc_i       (pc),
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
    .disp_rsp_t (disp_res_t),
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
    .alu_disp_rsp_i      ('0), // RSS not yet implemented
    .lsu_disp_req_valid_o(lsu_disp_req_valid),
    .lsu_disp_req_ready_i(lsu_disp_req_ready),
    .lsu_disp_rsp_i      ('0),  // RSS not yet implemented
    .csr_disp_req_valid_o(csr_disp_req_valid),
    .csr_disp_req_ready_i(csr_disp_req_ready),
    .fpu_disp_req_valid_o(fpu_disp_req_valid),
    .fpu_disp_req_ready_i(fpu_disp_req_ready),
    .fpu_disp_rsp_i      ('0), // RSS not yet implemented
    // Shared accelerator interface
    .acc_req_o           (acc_qreq_o),
    .acc_disp_req_valid_o(acc_qvalid_o),
    .acc_disp_req_ready_i(acc_qready_i)
  );

  // Convert dispatch request to issue request
  issue_req_t issue_req;
  assign issue_req.fu_data = dispatch_req.fu_data;
  assign issue_req.tag     = dispatch_req.tag;
  // valid/ready is fed through so no extra signals

  // ---------------------------
  // Functional Units
  // ---------------------------
  logic [0:0]  alu_result_valid;
  logic [0:0]  alu_result_ready;

  schnizo_alu #(
    .XLEN       (XLEN),
    .HasBranch  (1),
    .issue_req_t(issue_req_t),
    .instr_tag_t(instr_tag_t)
  ) i_alu (
    .clk_i,
    .rst_i,
    .issue_req_i      (issue_req),
    .issue_req_valid_i(alu_disp_req_valid),
    .issue_req_ready_o(alu_disp_req_ready),
    .result_o         (alu_result.result),
    .compare_res_o    (alu_result.compare_res),
    .tag_o            (alu_result_tag),
    .result_valid_o   (alu_result_valid),
    .result_ready_i   (alu_result_ready),
    .busy_o           ()
  );

  logic       lsu_result_valid;
  logic       lsu_result_ready;
  instr_tag_t lsu_result_tag;
  data_t      lsu_result;

  schnizo_lsu #(
    .XLEN               (XLEN),
    .issue_req_t        (issue_req_t),
    .AddrWidth          (AddrWidth),
    .DataWidth          (DataWidth),
    .dreq_t             (dreq_t),
    .drsp_t             (drsp_t),
    .tag_t              (instr_tag_t),
    .NumOutstandingMem  (NumOutstandingMem),
    .NumOutstandingLoads(NumOutstandingLoads),
    .Caq                (0),
    .CaqDepth           (CaqDepth),
    .CaqTagWidth        (CaqTagWidth),
    .CaqRespSrc         (0),
    .CaqRespTrackSeq    (0)
  ) i_lsu (
    .clk_i,
    .rst_i,
    .issue_req_i      (issue_req),
    .issue_req_valid_i(lsu_disp_req_valid),
    .issue_req_ready_o(lsu_disp_req_ready),
    .result_o         (lsu_result),
    .tag_o            (lsu_result_tag),
    .result_error_o   (), // ignored for now
    .result_valid_o   (lsu_result_valid),
    .result_ready_i   (lsu_result_ready),
    .busy_o           (),
    .empty_o          (lsu_empty),
    .addr_misaligned_o(lsu_addr_misaligned),
    // Memory interface
    .data_req_o       (data_req_o),
    .data_rsp_i       (data_rsp_i),
    // CAQ
    .caq_addr_i       ('0),
    .caq_track_write_i(1'b0),
    .caq_req_valid_i  (1'b0),
    .caq_req_ready_o  (),
    .caq_rsp_valid_i  (1'b0),
    .caq_rsp_valid_o  ()
  );

  // CSR FU & register file
  // Has direct connection to control logic.
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
    .result_tag_t(instr_tag_t)
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
    .fpu_status_i           (fpu_status),
    .fpu_status_valid_i     (fpu_status_valid),
    .fpu_rnd_mode_o         (fpu_rnd_mode),
    .fpu_fmt_mode_o         (fpu_fmt_mode),

    .instr_retired_i(instr_retired)
  );

  logic [FLEN-1:0] fpu_result;
  logic            fpu_result_valid;
  logic            fpu_result_ready;
  instr_tag_t      fpu_result_tag;

  schnizo_fpu #(
    .FPUImplementation(FPUImplementation),
    .RVF              (RVF),
    .RVD              (RVD),
    .XF16             (XF16),
    .XF16ALT          (XF16ALT),
    .XF8              (XF8),
    .XF8ALT           (XF8ALT),
    .XFVEC            (XFVEC),
    .FLEN             (FLEN),
    .RegisterFPUIn    (RegisterFPUIn),
    .RegisterFPUOut   (RegisterFPUOut),
    .issue_req_t      (issue_req_t),
    .instr_tag_t      (instr_tag_t)
  ) i_fpu (
    .clk_i,
    .rst_ni           (~rst_i),
    .hart_id_i        (),
    .issue_req_i      (issue_req),
    .issue_req_valid_i(fpu_disp_req_valid),
    .issue_req_ready_o(fpu_disp_req_ready),
    .result_o         (fpu_result),
    .result_valid_o   (fpu_result_valid),
    .result_ready_i   (fpu_result_ready),
    .tag_o            (fpu_result_tag),
    .status_o         (fpu_status),
    .busy_o           ()
  );

  // We may only update the FCSR fpu status bits if the result is handshaked.
  assign fpu_status_valid = fpu_result_valid && fpu_result_ready;

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
  assign issue_fpu = fpu_disp_req_valid & fpu_disp_req_ready;
  // In Snitch this signal captures when an instruction is offloaded to the FP SS. This can include
  // also FP loads as the FP register is in the subsystem. Schnizo cannot distinguish this case as
  // we handle all instructions in the core. We thus set the same signal.
  // TODO: rework the core events
  assign issue_core_to_fpu = fpu_disp_req_valid & fpu_disp_req_ready;

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

endmodule
