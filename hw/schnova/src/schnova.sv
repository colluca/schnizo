// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// TODO
// - LSU CAQ
// - Debug support -> not required
// - check all todos

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

// Top-level of the Schnova core.
//
// As of this, it now features a superscalar loop execution.
// This core implements the following RISC-V extensions:
// - IMAFD (A ignoring aq and lr flags)
// - Zicsr, Zicntr (Cycle & Instret only, always enabled)
//
// Limitation:
// - The scoreboard assumes that only multi cycle functional units write to the floating point
//   register file!
// - when reaching the end of a program, we somehow have to make sure that all instructions
//   have committed before the core gets stopped.
//
// Use automatic retiming options in the synthesis tool to optimize the fpnew design.
module schnova import schnizo_pkg::*, schnova_pkg::*, schnizo_tracer_pkg::*; #(
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
  parameter int unsigned NofAlus    = 3,
  parameter int unsigned NofLsus    = 1,
  parameter int unsigned NofFpus    = 1,
  parameter int unsigned AluNofRss  = 3,
  parameter int unsigned LsuNofRss  = 2,
  parameter int unsigned FpuNofRss  = 4,
  parameter bit          MulInAlu0  = 1'b1,
  /// Response XBAR configuration
  parameter integer unsigned AluNofResRspPorts = 1,
  parameter integer unsigned LsuNofResRspPorts = 1,
  parameter integer unsigned FpuNofResRspPorts = 1,
  /// How many issued loads the LSU and thus the CAQ (consistency address queue) can hold.
  // This applies to all LSUs (each LSU can handle NumOutstandingLoads loads).
  parameter int unsigned NumOutstandingLoads = 0,
  /// How many total transactions (load and store) the LSU can handle at once
  // This applies to all LSUs (each LSU can handle NumOutstandingMem transactions).
  parameter int unsigned NumOutstandingMem = 0,
  /// Number of bits that get fetched per fetch request
  parameter int unsigned ICacheFetchDataWidth      = 0,
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
  localparam type addr_t = logic [AddrWidth-1:0],
  localparam type data_t = logic [DataWidth-1:0]
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
  input  logic [ICacheFetchDataWidth-1:0]   inst_data_i,
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

  //////////////////////////
  // Parameters and types //
  //////////////////////////

  localparam int unsigned XLEN = 32;
  // localparam int unsigned FLEN = DataWidth;
  // The pipeline width of the PipeWidth-wide superscalar schnova processor
  localparam int unsigned PipeWidth = ICacheFetchDataWidth/32;
  localparam int unsigned NrIntReadPorts = 2*PipeWidth;
  localparam int unsigned NrIntWritePorts = 1;
  localparam int unsigned NrFpReadPorts = 3*PipeWidth;
  localparam int unsigned NrFpWritePorts = 1;

  // We have to read out a mapping for every source operand and potentially
  // the destination operand if it takes multiple cycles except for the last destination operand
  // since we only have to track/forward dependencies in this current instruction block
  // If PipeWidth = 1, we still have to read the destination register for the scoreboard
  // functionality
  // Integer instructons have 2 source + 1 destination register
  localparam int unsigned RmtNrIntReadPorts = (PipeWidth > 1 ? 2*PipeWidth + 1*PipeWidth - 1 :
                                              2*PipeWidth + 1*PipeWidth);
  // Float instructions have 3 source + 1 destination register
  localparam int unsigned RmtNrFpReadPorts = (PipeWidth > 1 ? 3*PipeWidth + 1*PipeWidth - 1 :
                                              3*PipeWidth + 1*PipeWidth);
  // We have to write the new mapping for every destination register
  localparam int unsigned RmtNrWritePorts = 1*PipeWidth;

  // The bit width of an operand. This is simply the maximal bit width such that we can have a
  // common data type for all FUs.
  localparam int OpLen = (FLEN > XLEN) ? FLEN : XLEN;

  // TODO(colluca): should we define this in a package? The problem is it depends on parameters
  // of the module so it would have to be a macro.
  // Decoded instruction for dispatcher
  typedef struct packed {
    fu_t                          fu; // 4 bit
    alu_op_e                      alu_op; // 5 bit
    lsu_op_e                      lsu_op; // 4 bit
    csr_op_e                      csr_op; // 3 bit
    fpu_op_e                      fpu_op; // 5 bit
    // rd and rs_is_fp must be set to all zero to encoded that there is
    // no write back for this instruction.
    logic [RegAddrSize-1:0]       rd;
    logic                         rd_is_fp; // set if rd is a FP register
    logic [RegAddrSize-1:0]       rs1;
    logic                         rs1_is_fp; // set if rs1 is a FP register
    logic [RegAddrSize-1:0]       rs2;
    logic                         rs2_is_fp; // set if rs2 is a FP register
    // Imm field: for unfinished floating-point fused operations (FMADD, FMSUB, FNMADD, FNMSUB)
    // this field holds the address of the third operand (rs3) from the floating-point regfile
    logic [XLEN-1:0]              imm;
    logic                         use_imm_as_rs3; // set if rs3 is a FP register
    lsu_size_e                    lsu_size; // The bit width the LSU operates on, 2 bit
    fpnew_pkg::fp_format_e        fpu_fmt_src; // The FPU format field. 3 bit
    fpnew_pkg::fp_format_e        fpu_fmt_dst; // The FPU format field. 3 but
    // The round mode for the FPU. If DYN was specified, it contains the value from the CSR.
    fpnew_pkg::roundmode_e        fpu_rnd_mode; // 3 bit
    logic                         use_imm_as_op_b; // set if we need to use the immediate as ALU op b
    logic                         use_pc_as_op_a; // set if we need to use the PC as ALU operand a
    logic                         use_rs1addr_as_op_a; // set if CSR instruction uses rs1 address
    logic                         is_branch; // set if instruction is a branch
    logic                         is_jal; // set if JAL
    logic                         is_jalr; // set if JALR
    logic                         is_fence; // set if FENCE
    logic                         is_fence_i; // set if FENCE.I
    logic                         is_ecall;
    logic                         is_ebreak;
    logic                         is_mret;
    logic                         is_sret;
    logic                         is_wfi;
    // FREP extension
    logic                         is_frep;
    logic [FrepBodySizeWidth-1:0] frep_bodysize;
    frep_mode_e                   frep_mode;
  } instr_dec_t;

  typedef logic [PhysRegAddrSize-1:0] phy_id_t;

  // The micro operation that is forwarded by the dispatcher
  typedef struct packed {
    fu_t                          fu; // 4 bit
    alu_op_e                      alu_op; // 5 bit
    lsu_op_e                      lsu_op; // 4 bit
    csr_op_e                      csr_op; // 3 bit
    fpu_op_e                      fpu_op; // 5 bit
  } uop_t;

  // Fetch block level info needed by the controller and frontend
  typedef struct packed {
    logic [XLEN-1:0]              imm;
    logic                         is_branch; // set if instruction is a branch
    logic                         is_jal; // set if JAL
    logic                         is_jalr; // set if JALR
    logic                         is_ctrl;
    logic [$clog2(PipeWidth)-1:0] instr_idx;
  } block_ctrl_info_t;

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

  // ---------------------------
  // RSS definitions / parameters
  // ---------------------------
  localparam integer unsigned AluNofOperands = 2;
  localparam integer unsigned LsuNofOperands = 3; // the 3rd operand is the address offset
  localparam integer unsigned FpuNofOperands = 3;

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

  localparam integer unsigned NofOperandIfs = NofAlus * AluNofOperands +
                                              NofLsus * LsuNofOperands +
                                              NofFpus * FpuNofOperands;

  // We differentiate between result requests and result responses.
  // Each reservation station has a result request crossbar output which is shared among the slots.
  // We allow multi request handling by coalescing requests.
  // TODO(colluca): would probably make sense to also call these "ports" instead of "interfaces"
  //                for consistency
  localparam integer unsigned AluNofResReqIfs = 1;
  localparam integer unsigned LsuNofResReqIfs = 1;
  localparam integer unsigned FpuNofResReqIfs = 1;

  localparam integer unsigned NofResReqIfs = NofAlus * AluNofResReqIfs +
                                             NofLsus * LsuNofResReqIfs +
                                             NofFpus * FpuNofResReqIfs;
  // Since we use the RMT as a scoreboard, CSR, MULDIV, DMA also have to have a virtual
  // reservation station entry. We just rename them to the same slot.
  localparam integer unsigned NofVirtRs = 3;

  // The operands of multiple RSS share their operand ID per RS.
  localparam integer unsigned NofOperandIfsW = cf_math_pkg::idx_width(NofOperandIfs);
  localparam integer unsigned NofResReqIfsW  = cf_math_pkg::idx_width(NofResReqIfs+NofVirtRs);

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
  

  // TODO(colluca): review these comments
  typedef struct packed {
    slot_id_t slot_id; // used to select the slot of the request within the RS
    rs_id_t   rs_id; // used to control the request crossbar
  } producer_id_t;

  // ---------------------------
  // Dispatch/issue/result data types
  // ---------------------------

  typedef struct packed {
    producer_id_t           producer_id;
    logic [PhysRegAddrSize-1:0] dest_reg;
    logic                   dest_reg_is_fp;
    logic                   is_branch;
    logic                   is_jump;
  } schnova_instr_tag_t;

  typedef struct packed {
    producer_id_t producer;
  } disp_rsp_t;

  typedef struct packed {
    phy_id_t         rd;
    logic            rd_is_fp;
    phy_id_t         rs1;
    logic            rs1_is_fp;
    phy_id_t         rs2;
    logic            rs2_is_fp;
    phy_id_t         rs3;
    logic            use_imm_as_rs3;
  } sb_disp_data_t;

  typedef struct packed {
    producer_id_t producer;
    logic         valid; // set if producer is a valid mapping
  } rmt_entry_t;

  typedef struct packed {
    phy_id_t phy_reg_op_a;
    phy_id_t phy_reg_op_b;
    phy_id_t phy_reg_op_c;
    phy_id_t phy_reg_dest_new;
    phy_id_t phy_reg_dest_old;
    logic       valid; // set if this instruction renaming is valid
  } rename_data_t;

  typedef struct packed {
    fu_data_t   fu_data;
    rmt_entry_t producer_op_a;
    rmt_entry_t producer_op_b;
    rmt_entry_t producer_op_c;
    rmt_entry_t current_producer_dest;
    schnova_instr_tag_t tag;
  } disp_req_t;

  typedef struct packed {
    fu_data_t fu_data;
    schnova_instr_tag_t tag;
  } issue_req_t;

  // The ALU result without the branch decision
  typedef logic [XLEN-1:0] alu_res_val_t;

  typedef struct packed {
    alu_res_val_t result;
    logic         compare_res;
  } alu_result_t;

  /////////////////
  // Connections //
  /////////////////

  logic [PipeWidth-1:0][31:0] instr_fetch_data;
  logic [PipeWidth-1:0]       instr_fetch_data_valid;
  logic [XLEN-1:0]                 consecutive_pc;
  logic                            loop_jump;
  logic [31:0]                     loop_jump_addr;


  logic [NrIntReadPorts-1:0][PhysRegAddrSize-1:0]  gpr_raddr;
  logic [NrIntReadPorts-1:0][XLEN-1:0]         gpr_rdata;
  logic [NrIntWritePorts-1:0][PhysRegAddrSize-1:0] gpr_waddr;
  logic [NrIntWritePorts-1:0][XLEN-1:0]        gpr_wdata;
  logic [NrIntWritePorts-1:0]                  gpr_we;

  logic [NrFpReadPorts-1:0][PhysRegAddrSize-1:0]  fpr_raddr;
  logic [NrFpReadPorts-1:0][FLEN-1:0]         fpr_rdata;
  logic [NrFpWritePorts-1:0][PhysRegAddrSize-1:0] fpr_waddr;
  logic [NrFpWritePorts-1:0][FLEN-1:0]        fpr_wdata;
  logic [NrFpWritePorts-1:0]                  fpr_we;

  fu_data_t [PipeWidth-1:0] fu_data;

  logic            flush_i_valid;
  logic [31:0]     pc;
  logic [31:0]     jump_pc;
  logic [PipeWidth-1:0] instr_valid;
  logic [PipeWidth-1:0] instr_decoded_illegal;
  logic            instr_illegal;
  logic            stall;
  logic            ctrl_stall;
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
  logic dispatch_instr_valid;
  logic dispatch_instr_ready;
  logic instr_exec_commit;

  fpnew_pkg::roundmode_e fpu_rnd_mode;
  fpnew_pkg::fmt_mode_t  fpu_fmt_mode;
  instr_dec_t [PipeWidth-1:0] instr_decoded;
  block_ctrl_info_t blk_ctrl_info;

  alu_result_t alu_result;
  schnova_instr_tag_t  alu_result_tag;
  alu_result_t branch_result;
  logic [0:0]  lsu_empty;
  fpnew_pkg::status_t fpu_status;
  logic               fpu_status_valid;
  frep_mem_cons_mode_e frep_mem_cons_mode;

  logic flush_backend;
  logic dispatched;
  sb_disp_data_t [PipeWidth-1:0] sb_disp_data;
  rename_data_t [PipeWidth-1:0]  rename_info;

  logic ctrl_instr_retired;

  logic en_superscalar;
  logic exit_superscalar;
  logic registers_ready;
  logic sb_busy;

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

  ///////////
  // State //
  ///////////

  `FFAR(instr_retired_q,              instr_retired,              '0, clk_i, rst_i)
  `FFAR(instr_retired_single_cycle_q, instr_retired_single_cycle, '0, clk_i, rst_i)
  `FFAR(instr_retired_load_q,         instr_retired_load,         '0, clk_i, rst_i)
  `FFAR(instr_retired_acc_q,          instr_retired_acc,          '0, clk_i, rst_i)
  `FFAR(issue_fpu_q,                  issue_fpu,                  '0, clk_i, rst_i)
  `FFAR(issue_core_to_fpu_q,          issue_core_to_fpu,          '0, clk_i, rst_i)

  ///////////////////////
  // Instruction fetch //
  ///////////////////////

  schnova_frontend # (
    .XLEN                 (XLEN),
    .PipeWidth            (PipeWidth),
    .BootAddr             (BootAddr),
    .AddrWidth            (AddrWidth),
    .SnitchPMACfg         (SnitchPMACfg),
    .ICacheFetchDataWidth (ICacheFetchDataWidth),
    .block_ctrl_info_t    (block_ctrl_info_t),
    .addr_t               (addr_t)
  ) i_frontend (
    .clk_i,
    .rst_i,
    // From L0 instruction cache
    .instr_fetch_data_i       (inst_data_i),
    .instr_fetch_ready_i      (inst_ready_i),
    // To L0 instruction cache
    .instr_fetch_addr_o       (inst_addr_o),
    .instr_fetch_cacheable_o  (inst_cacheable_o),
    .instr_fetch_valid_o      (inst_valid_o),
    // From controller
    .exception_i              (exception),
    .stall_i                  (stall),
    .ctrl_stall_i             (ctrl_stall),
    .mret_i                   (mret),
    .sret_i                   (sret),
    .en_superscalar_i         (en_superscalar),
    // To controller
    .pc_o                     (pc),
    .consecutive_pc_o         (consecutive_pc),
    .jump_pc_o                (jump_pc),
    // Exception source interface
    .wfi_i                    (wfi),
    .barrier_stall_i          (barrier_stall),
    .mtvec_i                  (mtvec),
    .mepc_i                   (mepc),
    .sepc_i                   (sepc),
    // Branch result
    .alu_compare_res_i        (branch_result.compare_res),
    .alu_result_i             (branch_result.result),
    // From decoder
    .blk_ctrl_info_i          (blk_ctrl_info),
    // To decoder and dispatcher
    .instr_fetch_data_o      (instr_fetch_data),
    .instr_fetch_data_valid_o(instr_fetch_data_valid)
  );

  // Instruction Cache flush request interface
  assign flush_i_valid_o = flush_i_valid;

  /////////////
  // Decoder //
  /////////////

  // TODO(colluca): could lead to conflicts, e.g. instr_dec_t also depends on XLEN. The best would be
  // to only pass e.g. XLEN here, and internally derive instr_dec_t in the decoder using a macro.
  schnova_decoder #(
    .XLEN              (XLEN),
    .PipeWidth         (PipeWidth),
    .Xdma              (Xdma),
    .RVF               (RVF),
    .RVD               (RVD),
    .XF16              (XF16),
    .XF16ALT           (XF16ALT),
    .XF8               (XF8),
    .XF8ALT            (XF8ALT),
    .block_ctrl_info_t (block_ctrl_info_t),
    .instr_dec_t       (instr_dec_t)
  ) i_decoder (
    .clk_i,
    .rst_i,
    .en_superscalar_i        (en_superscalar),
    .exit_superscalar_o      (exit_superscalar),
    .instr_fetch_data_i      (instr_fetch_data),
    .instr_fetch_data_valid_i(instr_fetch_data_valid),
    .fpu_round_mode_i        (fpu_rnd_mode),
    .fpu_fmt_mode_i          (fpu_fmt_mode),
    .instr_valid_o           (instr_valid),
    .instr_illegal_o         (instr_decoded_illegal),
    .blk_ctrl_info_o         (blk_ctrl_info),
    .instr_dec_o             (instr_decoded)
  );

  // Read the operands - do always read (even if invalid instr) because controller depends on
  // values from registers. See for example the FREP instruction and its number of iterations.
  schnova_read_operands #(
    .PipeWidth     (PipeWidth),
    .XLEN          (XLEN),
    .FLEN          (FLEN),
    .RegAddrSize   (PhysRegAddrSize),
    .NrIntReadPorts(NrIntReadPorts),
    .NrFpReadPorts (NrFpReadPorts),
    .instr_dec_t   (instr_dec_t),
    .fu_data_t     (fu_data_t)
  ) i_read_operands (
    .jump_pc_i(jump_pc),
    .instr_dec_i(instr_decoded),
    .gpr_raddr_o(gpr_raddr),
    .gpr_rdata_i(gpr_rdata),
    .fpr_raddr_o(fpr_raddr),
    .fpr_rdata_i(fpr_rdata),
    .fu_data_o  (fu_data)
  );

  ////////////////
  // Controller //
  ////////////////

  logic                         rs_full;
  logic                         all_rs_finish;
  logic                         rs_restart;

  schnova_controller #(
    .PipeWidth          (PipeWidth),
    .XLEN               (XLEN),
    .NrIntWritePorts(NrIntWritePorts),
    .NrFpWritePorts (NrFpWritePorts),
    .RegAddrSize    (RegAddrSize),
    .instr_dec_t        (instr_dec_t),
    .block_ctrl_info_t  (block_ctrl_info_t),
    .priv_lvl_t         (priv_lvl_t)
  ) i_controller (
    .clk_i,
    .rst_i,
    // Frontend interface
    .flush_i_ready_i        (flush_i_ready_i),
    .flush_i_valid_o        (flush_i_valid),
    .consecutive_pc_i       (consecutive_pc),
    // Decoder interface
    .instr_decoded_i        (instr_decoded),
    .instr_valid_i          (instr_valid),
    .instr_decoded_illegal_i(instr_decoded_illegal),
    .blk_ctrl_info_i        (blk_ctrl_info),
    // To rename stage
    .flush_backend_o (flush_backend),
    .dispatched_o(dispatched),
    .all_rs_finish_i(all_rs_finish),
    .rs_restart_o(rs_restart),
    // Interface to dispatcher
    .dispatch_instr_valid_o (dispatch_instr_valid),
    .dispatch_instr_ready_i (dispatch_instr_ready),
    .instr_exec_commit_o    (instr_exec_commit),
    .stall_o                (stall),
    .ctrl_stall_o           (ctrl_stall),
    // Writeback interface
    .ctrl_instr_retired_i(ctrl_instr_retired),
    // Exception source interface
    .interrupt_i            (interrupt),
    .csr_exception_raw_i    (csr_exception_raw),
    .lsu_empty_i            (lsu_empty),
    .load_inflight_i        (1'b0),
    .store_inflight_i       (1'b0),
    .lsu_addr_misaligned_i  (lsu_addr_misaligned),
    .priv_lvl_i             (priv_lvl),
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
    .en_superscalar_o       (en_superscalar),
    .exit_superscalar_i     (exit_superscalar),
    // GPR & FPR Write back snooping for Scoreboard
    .registers_ready_i      (registers_ready),
    .sb_busy_i              (sb_busy)
  );

  ////////////
  // Rename //
  ////////////

  schnova_rename #(
    .PipeWidth(PipeWidth),
    .RmtNrIntReadPorts(RmtNrIntReadPorts),
    .RmtNrFpReadPorts(RmtNrFpReadPorts),
    .RmtNrWritePorts(RmtNrWritePorts),
    .PhysRegAddrSize(PhysRegAddrSize),
    .RegAddrSize(RegAddrSize),
    .instr_dec_t(instr_dec_t),
    .phy_id_t(phy_id_t),
    .rename_data_t(rename_data_t)
  ) i_rename (
    .clk_i,
    .rst_i,
    .en_superscalar_i(en_superscalar),
    .flush_i(flush_backend),
    .dispatched_i(dispatched),
    .dispatch_valid_i(dispatch_instr_valid),
    .instr_dec_i(instr_decoded),
    .rename_info_o(rename_info)
  );

  //////////////
  // Dispatch //
  //////////////

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

  schnova_dispatcher #(
    .PipeWidth(PipeWidth),
    .RegAddrSize(RegAddrSize),
    .NofAlus    (NofAlus),
    .NofLsus    (NofLsus),
    .NofFpus    (NofFpus),
    .instr_dec_t(instr_dec_t),
    .rmt_entry_t(rmt_entry_t),
    .phy_id_t(phy_id_t),
    .rename_data_t(rename_data_t),
    .disp_req_t (disp_req_t),
    .disp_rsp_t (disp_rsp_t),
    .producer_id_t(producer_id_t),
    .rs_id_t(rs_id_t),
    .fu_data_t  (fu_data_t),
    .acc_req_t  (acc_req_t),
    .sb_disp_data_t(sb_disp_data_t)
  ) i_dispatcher (
    .clk_i,
    .rst_i,
    // Rename interface
    .rename_info_i(rename_info),
    .sb_disp_data_o(sb_disp_data),
    .en_superscalar_i    (en_superscalar),
    .instr_dec_i         (instr_decoded),
    .instr_fu_data_i     (fu_data),
    .instr_fetch_data_i  (instr_fetch_data),
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
    .restart_i           (flush_backend),
    .frep_mem_cons_mode_i(frep_mem_cons_mode),
    .rs_full_o           (rs_full)
  );

  // Convert dispatch request to issue request for CSR.
  // The valid/ready is fed through so no extra signals.
  issue_req_t issue_req;
  assign issue_req.fu_data = dispatch_req.fu_data;
  assign issue_req.tag     = dispatch_req.tag;

  //////////////////////
  // Functional Units //
  //////////////////////

  logic            alu_result_valid;
  logic            alu_result_ready;
  logic            lsu_result_valid;
  logic            lsu_result_ready;
  schnova_instr_tag_t      lsu_result_tag;
  data_t           lsu_result;
  logic [FLEN-1:0] fpu_result;
  logic            fpu_result_valid;
  logic            fpu_result_ready;
  schnova_instr_tag_t      fpu_result_tag;

  // Trace signals
  // pragma translate_off
  issue_alu_trace_t  alu_trace       [NofAlus];
  issue_lsu_trace_t  lsu_trace       [NofLsus];
  issue_fpu_trace_t  fpu_trace       [NofFpus];
  retire_fu_trace_t  alu_retirements [NofAlus];
  retire_fu_trace_t  lsu_retirements [NofLsus];
  retire_fu_trace_t  fpu_retirements [NofFpus];
  // pragma translate_on

  schnova_fu_stage #(
    .Xfrep              (Xfrep),
    .MulInAlu0          (MulInAlu0),
    .NofAlus            (NofAlus),
    .AluNofRss          (AluNofRss),
    .AluNofOperands     (AluNofOperands),
    .AluNofResReqIfs    (AluNofResReqIfs),
    .AluNofResRspPorts  (AluNofResRspPorts),
    .NofLsus            (NofLsus),
    .LsuNofRss          (LsuNofRss),
    .LsuNofOperands     (LsuNofOperands),
    .LsuNofResReqIfs    (LsuNofResReqIfs),
    .LsuNofResRspPorts  (LsuNofResRspPorts),
    .NofFpus            (NofFpus),
    .FpuNofRss          (FpuNofRss),
    .FpuNofOperands     (FpuNofOperands),
    .FpuNofResReqIfs    (FpuNofResReqIfs),
    .FpuNofResRspPorts  (FpuNofResRspPorts),
    .NofOperandIfs      (NofOperandIfs),
    .NofResReqIfs       (NofResReqIfs),
    .XLEN               (XLEN),
    .FLEN               (FLEN),
    .OpLen              (OpLen),
    .AddrWidth          (AddrWidth),
    .DataWidth          (DataWidth),
    .RegAddrWidth       (RegAddrSize),
    .MaxIterationsW     (FrepMaxItersWidth),
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
    .fu_data_t          (fu_data_t),
    .instr_tag_t        (schnova_instr_tag_t),
    .alu_result_t       (alu_result_t),
    .alu_res_val_t      (alu_res_val_t),
    .dreq_t             (dreq_t),
    .drsp_t             (drsp_t)
  ) i_fu_stage (
    .clk_i,
    .rst_i,
    // TODO(colluca): typo
    .hard_id_i            (hart_id_i),
    .restart_i            (rs_restart),
    .en_superscalar_i     (en_superscalar),
    .disp_req_i           (dispatch_req),
    .all_rs_finish_o      (all_rs_finish),
    // Global commit signal
    .instr_exec_commit_i  (instr_exec_commit),
    // Trace
    // pragma translate_off
    .alu_trace_o          (alu_trace),
    .lsu_trace_o          (lsu_trace),
    .fpu_trace_o          (fpu_trace),
    .alu_retire_trace_o   (alu_retirements),
    .lsu_retire_trace_o   (lsu_retirements),
    .fpu_retire_trace_o   (fpu_retirements),
    // pragma translate_on
    // ALU
    .alu_disp_reqs_valid_i(alu_disp_req_valid),
    .alu_disp_reqs_ready_o(alu_disp_req_ready),
    .alu_disp_rsp_o       (alu_disp_rsp),
    .alu_rs_full_o        (alu_rs_full),
    // LSU
    .lsu_disp_reqs_valid_i(lsu_disp_req_valid),
    .lsu_disp_reqs_ready_o(lsu_disp_req_ready),
    .lsu_disp_rsp_o       (lsu_disp_rsp),
    .lsu_empty_o          (lsu_empty),
    .lsu_addr_misaligned_o(lsu_addr_misaligned),
    .lsu_dreq_o           (data_req_o), // Each LSU has its own reqrsp port
    .lsu_drsp_i           (data_rsp_i), // Each LSU has its own reqrsp port
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
  schnova_instr_tag_t csr_result_tag;
  logic [XLEN-1:0] csr_result;

  schnizo_csr #(
    .XLEN        (XLEN),
    .DebugSupport(0),
    .RVF         (RVF),
    .RVD         (RVD),
    .Xdma        (Xdma),
    .VMSupport   (0),
    .issue_req_t (issue_req_t),
    .result_tag_t(schnova_instr_tag_t),
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

  ////////////////
  // Write back //
  ////////////////

  // Convert the accelerator response to a proper result and result tag such that the
  // write back and scoreboard functions properly.
  logic [XLEN-1:0] acc_result;
  schnova_instr_tag_t      acc_result_tag;
  always_comb begin : acc_response_conversion
    acc_result = acc_prsp_i.data;
    acc_result_tag = '0;
    acc_result_tag.dest_reg = acc_prsp_i.id;
    acc_result_tag.dest_reg_is_fp = 1'b0;
  end

  // See module for details and specialities!
  schnova_writeback #(
    .PipeWidth      (PipeWidth),
    .XLEN           (XLEN),
    .FLEN           (FLEN),
    .NrIntWritePorts(NrIntWritePorts),
    .NrFpWritePorts (NrFpWritePorts),
    .RegAddrSize    (PhysRegAddrSize),
    .instr_tag_t    (schnova_instr_tag_t),
    .alu_result_t   (alu_result_t),
    .data_t         (data_t)
  ) i_writeback (
    // ALU interface
    .alu_result_i      (alu_result),
    .alu_result_tag_i  (alu_result_tag),
    .alu_result_valid_i(alu_result_valid),
    .alu_result_ready_o(alu_result_ready),
    // TODO (soderma): This used to be PC+4, the instruction after the jal/jalr
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
    .retired_acc_o         (instr_retired_acc),
    // Control instruction retirement
    .ctrl_instr_retired_o(ctrl_instr_retired)
  );

  /////////////////
  // Core Events //
  /////////////////

  // TODO (soderma): Make core events superscalar

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
  // TODO (soderma): This was just written to compile
  assign issue_fpu = (|all_issue_fpu_handshakes) & instr_exec_commit;
  // In Snitch this signal captures when an instruction is offloaded to the FP SS. This can include
  // also FP loads as the FP register is in the subsystem. Schnizo cannot distinguish this case as
  // we handle all instructions in the core. We thus set the same signal.
  // TODO: rework the core events
  // TODO (soderma): This was just written to compile
  assign issue_core_to_fpu = (|all_issue_fpu_handshakes) & instr_exec_commit;

  assign core_events_o.retired_instr = instr_retired_q;
  assign core_events_o.retired_i     = instr_retired_single_cycle_q;
  assign core_events_o.retired_load  = instr_retired_load_q;
  assign core_events_o.retired_acc   = instr_retired_acc_q;

  assign core_events_o.issue_fpu         = issue_fpu_q;
  assign core_events_o.issue_core_to_fpu = issue_core_to_fpu_q;
  assign core_events_o.issue_fpu_seq     = '0;

  ////////////////
  // Scoreboard //
  ////////////////

  schnova_scoreboard #(
    .PipeWidth(PipeWidth),
    .NrReadPorts(/* TODO(soderma)*/),
    .NrWritePorts(1),
    .AddrWidth(PhysRegAddrSize),
    .sb_disp_data_t(sb_disp_data_t)
  ) i_scoreboard (
    // clock and reset
    .clk_i,
    .rst_i,
    .en_superscalar_i(en_superscalar),
    // Dispatched instruction
    .dispatched_i(dispatched),
    .instr_valid_i(instr_valid),
    .disp_data_i(sb_disp_data),
    // Register writeback snooping
    .wb_gpr_addr_i(gpr_waddr),
    .wb_gpr_en_i(gpr_we),
    .wb_fpr_addr_i(fpr_waddr),
    .wb_fpr_en_i(fpr_we),
    // To controller
    .registers_ready_o(registers_ready),
    .sb_busy_o(sb_busy)
);

  /////////////////////////////
  // Physical Register Files //
  /////////////////////////////

  snitch_regfile #(
    .DataWidth   (XLEN),
    .NrReadPorts (NrIntReadPorts),
    .NrWritePorts(NrIntWritePorts),
    .ZeroRegZero (1),
    .AddrWidth   (PhysRegAddrSize)
  ) i_int_regfile (
    .clk_i,
    .rst_ni (~rst_i),
    .raddr_i(gpr_raddr),
    .rdata_o(gpr_rdata),
    .waddr_i(gpr_waddr),
    .wdata_i(gpr_wdata),
    .we_i   (gpr_we)
  );

  if (NofFpus > 0) begin : gen_fp_rf
    snitch_regfile #(
      .DataWidth    (FLEN),
      .NrReadPorts  (NrFpReadPorts),
      .NrWritePorts (NrFpWritePorts),
      .ZeroRegZero  (0),
      .AddrWidth    (PhysRegAddrSize)
    ) i_fp_regfile (
      .clk_i,
      .rst_ni (~rst_i),
      .raddr_i(fpr_raddr),
      .rdata_o(fpr_rdata),
      .waddr_i(fpr_waddr),
      .wdata_i(fpr_wdata),
      .we_i   (fpr_we)
    );
  end else begin
    assign fpr_rdata = '0;
  end
  ////////////
  // Tracer //
  ////////////

  // pragma translate_off

  // Core and dispatch traces
  schnizo_core_trace_t     core_trace;
  schnizo_dispatch_trace_t dispatch_trace;
  int unsigned             dispatch_rs_id;

  // Traces for regular execution
  issue_csr_trace_t csr_trace;
  issue_acc_trace_t acc_trace;

  // Traces for RSS issues
  issue_alu_trace_t rss_alu_traces [NofAlus][AluNofRss];
  issue_lsu_trace_t rss_lsu_traces [NofLsus][LsuNofRss];
  issue_fpu_trace_t rss_fpu_traces [NofFpus][FpuNofRss];

  // Traces for retirements
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

  // Traces for result captures (each RSS has one signal)
  rescap_trace_t alu_rescap_traces [NofAlus][AluNofRss];
  rescap_trace_t lsu_rescap_traces [NofLsus][LsuNofRss];
  rescap_trace_t fpu_rescap_traces [NofFpus][FpuNofRss];

  loop_state_e                  loop_state;
  logic [FrepMaxItersWidth-1:0] loop_iteration = '0;

  always_comb begin
    loop_state = LoopRegular;
    if (en_superscalar) begin
      loop_state = LoopLcp1;
    end
  end

  assign core_trace = '{
    priv_level: priv_lvl,
    state:      loop_state,
    iteration:  loop_iteration,
    stall:      stall,
    exception:  exception
  };

  assign dispatch_trace = '{
    valid:        i_controller.instr_dispatched || exception,
    pc_q:         i_frontend.pc_q,
    pc_d:         i_frontend.pc_d,
    instr_data:   instr_fetch_data[0],
    rs1:          instr_decoded[0].rs1,
    rs2:          instr_decoded[0].rs2,
    rs3:          instr_decoded[0].imm, // fused FPU instructions use imm as operand
    rd:           instr_decoded[0].rd,
    rs1_is_fp:    instr_decoded[0].rs1_is_fp,
    rs2_is_fp:    instr_decoded[0].rs2_is_fp,
    rd_is_fp:     instr_decoded[0].rd_is_fp,
    is_branch:    instr_decoded[0].is_branch,
    branch_taken: alu_result.compare_res,
    fu_type:      schnizo_pkg::fu_to_string(instr_decoded[0].fu),
    disp_resp:    i_fu_stage.producer_to_string(i_dispatcher.fu_response.producer)
  };

  assign dispatch_rs_id = i_dispatcher.fu_response.producer.rs_id;

  for (genvar alu = 0; alu < NofAlus; alu++) begin : gen_alu_traces
    for (genvar rss = 0; rss < AluNofRss; rss++) begin : gen_alu_traces_rss
      // verilog_lint: waive-start line-length
      if (Xfrep) begin : gen_alu_traces_rss_trace_resreq
        assign rss_alu_traces[alu][rss] = '{
          valid:          i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.i_slots.issue_hs &&
                          (i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.i_slots.disp_idx_i == rss),
                          // TODO(colluca): this only applies to the currently selected slot, this model no longer applies
                          // after porting issue slots to SRAM
          instr_iter:     1'b0,
          producer:       i_fu_stage.producer_to_string(
                            i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.i_slots.gen_rss[rss].i_res_req_handling.producer_id_i),
          alu_opa:        i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.i_slots.issue_req_raw.fu_data.operand_a[XLEN-1:0],
          alu_opb:        i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.i_slots.issue_req_raw.fu_data.operand_b[XLEN-1:0]
        };
        assign alu_rescap_traces[alu][rss] = '{
          // TODO(colluca): this combined signal should be derived inside the slot, not here. Do the same for other logic
          // sparse here in the tracer.
          valid:          i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.i_slots.capture_retired &&
                          !i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.i_slots.slot_wb_capture.has_dest &&
                          (i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.i_slots.result_rss_sel == rss),
          producer:       i_fu_stage.producer_to_string(
                            i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.i_slots.gen_rss[rss].i_res_req_handling.producer_id_i),
          result_iter:    1'b0,
          rd:             i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.i_slots.slot_wb_capture.dest_id,
          rd_is_fp:       i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.i_slots.slot_wb_capture.dest_is_fp,
          result:         i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.i_slots.slot_wb_capture.result.value
        };
      end else begin : gen_alu_traces_rss_no_trace_resreq
        assign rss_alu_traces[alu][rss]    = '{default: '0};
        assign alu_rescap_traces[alu][rss] = '{default: '0};
      end
      // each consumer can place a result request simultaneously
      for (genvar con = 0; con < NofOperandIfs; con++) begin : gen_alu_traces_rss_resreq
        if (Xfrep) begin : gen_alu_traces_rss_resreq_frep
          assign alu_resreq_traces[alu][rss][con] = '{
            valid:          i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.res_reqs_valid_i[rss] &&
                            i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.res_reqs_ready_o[rss] &&
                            i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.res_reqs_i[rss][con],
            producer:       i_fu_stage.producer_to_string(
                              i_fu_stage.gen_alus[alu].i_fu_block.gen_superscalar.i_res_stat.i_slots.gen_rss[rss].i_res_req_handling.producer_id_i),
            consumer:       i_fu_stage.consumer_to_string(con),
            // we only forward requests which we can serve. Thus we can take the current result iteration.
            requested_iter: 1'b0
          };
        end else begin : gen_alu_traces_rss_no_resreq
          assign alu_resreq_traces[alu][rss][con] = '{default: '0};
        end
      end
      // verilog_lint: waive-stop line-length
    end
  end

  for (genvar lsu = 0; lsu < NofLsus; lsu++) begin : gen_lsu_traces
    for (genvar rss = 0; rss < LsuNofRss; rss++) begin : gen_lsu_traces_rss
      // verilog_lint: waive-start line-length
      if (Xfrep) begin : gen_lsu_traces_rss_trace_resreq
        assign rss_lsu_traces[lsu][rss] = '{
          valid:          i_fu_stage.gen_lsus[lsu].i_fu_block.gen_superscalar.i_res_stat.i_slots.issue_hs &&
                          (i_fu_stage.gen_lsus[lsu].i_fu_block.gen_superscalar.i_res_stat.i_slots.disp_idx_i == rss),
          instr_iter:     1'b0,
          producer:       i_fu_stage.producer_to_string(
                            i_fu_stage.gen_lsus[lsu].i_fu_block.gen_superscalar.i_res_stat.i_slots.gen_rss[rss].i_res_req_handling.producer_id_i),
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
          valid:          i_fu_stage.gen_lsus[lsu].i_fu_block.gen_superscalar.i_res_stat.i_slots.capture_retired &&
                          !i_fu_stage.gen_lsus[lsu].i_fu_block.gen_superscalar.i_res_stat.i_slots.slot_wb_capture.has_dest &&
                          (i_fu_stage.gen_lsus[lsu].i_fu_block.gen_superscalar.i_res_stat.i_slots.result_rss_sel == rss),
          producer:       i_fu_stage.producer_to_string(
                            i_fu_stage.gen_lsus[lsu].i_fu_block.gen_superscalar.i_res_stat.i_slots.gen_rss[rss].i_res_req_handling.producer_id_i),
          result_iter:    1'b0,
          rd:             i_fu_stage.gen_lsus[lsu].i_fu_block.gen_superscalar.i_res_stat.i_slots.slot_wb_capture.dest_id,
          rd_is_fp:       i_fu_stage.gen_lsus[lsu].i_fu_block.gen_superscalar.i_res_stat.i_slots.slot_wb_capture.dest_is_fp,
          result:         i_fu_stage.gen_lsus[lsu].i_fu_block.gen_superscalar.i_res_stat.i_slots.slot_wb_capture.result.value
        };
      end else begin : gen_lsu_traces_rss_no_trace_resreq
        assign rss_lsu_traces[lsu][rss]    = '{default: '0};
        assign lsu_rescap_traces[lsu][rss] = '{default: '0};
      end
      // each consumer can place a result request simultaneously
      for (genvar con = 0; con < NofOperandIfs; con++) begin : gen_lsu_traces_rss_reqreq
        if (Xfrep) begin : gen_lsu_traces_rss_resreq_frep
          assign lsu_resreq_traces[lsu][rss][con] = '{
            valid:          i_fu_stage.gen_lsus[lsu].i_fu_block.gen_superscalar.i_res_stat.res_reqs_valid_i[rss] &&
                            i_fu_stage.gen_lsus[lsu].i_fu_block.gen_superscalar.i_res_stat.res_reqs_ready_o[rss] &&
                            i_fu_stage.gen_lsus[lsu].i_fu_block.gen_superscalar.i_res_stat.res_reqs_i[rss][con],
            producer:       i_fu_stage.producer_to_string(
                              i_fu_stage.gen_lsus[lsu].i_fu_block.gen_superscalar.i_res_stat.i_slots.gen_rss[rss].i_res_req_handling.producer_id_i),
            consumer:       i_fu_stage.consumer_to_string(con),
            // we only forward requests which we can serve. Thus we can take the current result iteration.
            requested_iter: 1'b0
          };
        end else begin : gen_lsu_traces_rss_no_resreq
          assign lsu_resreq_traces[lsu][rss][con] = '{default: '0};
        end
      end
      // verilog_lint: waive-stop line-length
    end
  end

  for (genvar fpu = 0; fpu < NofFpus; fpu++) begin : gen_fpu_traces
    for (genvar rss = 0; rss < FpuNofRss; rss++) begin : gen_fpu_traces_rss
      // verilog_lint: waive-start line-length
      if (Xfrep) begin : gen_fpu_traces_rss_trace
        assign rss_fpu_traces[fpu][rss] = '{
          valid:       i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.issue_hs &&
                      (i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.disp_idx_i == rss),
          instr_iter:  1'b0,
          producer:    i_fu_stage.producer_to_string(
                        i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.gen_rss[rss].i_res_req_handling.producer_id_i),
          fpu_opa:     i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.issue_req_raw.fu_data.operand_a,
          fpu_opb:     i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.issue_req_raw.fu_data.operand_b,
          fpu_opc:     i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.issue_req_raw.fu_data.imm,
          fpu_src_fmt: i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.issue_req_raw.fu_data.fpu_fmt_src,
          fpu_dst_fmt: i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.issue_req_raw.fu_data.fpu_fmt_dst,
          // Directly access the FPU because theses signals are decoded in the FPU. This requires
          // that there is no cut between the RSS and the FPU.
          fpu_int_fmt:    i_fu_stage.gen_fpus[fpu].i_fpu.int_fmt
        };
        assign fpu_rescap_traces[fpu][rss] = '{
          valid:          i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.capture_retired &&
                          !i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.slot_wb_capture.has_dest &&
                          (i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.result_rss_sel == rss),
          producer:       i_fu_stage.producer_to_string(
                            i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.gen_rss[rss].i_res_req_handling.producer_id_i),
          result_iter:    1'b0,
          rd:             i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.slot_wb_capture.dest_id,
          rd_is_fp:       i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.slot_wb_capture.dest_is_fp,
          result:         i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.slot_wb_capture.result.value
        };
      end else begin : gen_fpu_traces_no_rss
        assign rss_fpu_traces[fpu][rss]    = '{default: '0};
        assign fpu_rescap_traces[fpu][rss] = '{default: '0};
      end
      // each consumer can place a result request simultaneously
      for (genvar con = 0; con < NofOperandIfs; con++) begin : gen_fpu_traces_rss_resreq
        if (Xfrep) begin : gen_fpu_traces_rss_resreq_frep
          assign fpu_resreq_traces[fpu][rss][con] = '{
            valid:          i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.res_reqs_valid_i[rss] &&
                            i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.res_reqs_ready_o[rss] &&
                            i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.res_reqs_i[rss][con],
            producer:       i_fu_stage.producer_to_string(
                              i_fu_stage.gen_fpus[fpu].i_fu_block.gen_superscalar.i_res_stat.i_slots.gen_rss[rss].i_res_req_handling.producer_id_i),
            consumer:       i_fu_stage.consumer_to_string(con),
            // we only forward requests which we can serve. Thus we can take the current result iteration.
            requested_iter: 1'b0
          };
        end else begin : gen_fpu_traces_no_resreq
          assign fpu_resreq_traces[fpu][rss][con] = '{default: '0};
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

  schnizo_tracer #(
    .NofAlus        (NofAlus),
    .NofLsus        (NofLsus),
    .NofFpus        (NofFpus),
    .AluNofRss      (AluNofRss),
    .LsuNofRss      (LsuNofRss),
    .FpuNofRss      (FpuNofRss),
    .NofOperandIfs  (NofOperandIfs),
    .Xfrep          (Xfrep)
  ) i_tracer (
    .clk_i              (clk_i),
    .rst_i              (rst_i),
    .hart_id_i          (hart_id_i),
    .dispatch_rs_id     (dispatch_rs_id),
    .core_trace         (core_trace),
    .dispatch_trace     (dispatch_trace),
    .alu_trace          (alu_trace),
    .lsu_trace          (lsu_trace),
    .fpu_trace          (fpu_trace),
    .rss_alu_traces     (rss_alu_traces),
    .rss_lsu_traces     (rss_lsu_traces),
    .rss_fpu_traces     (rss_fpu_traces),
    .csr_trace          (csr_trace),
    .acc_trace          (acc_trace),
    .alu_retirements    (alu_retirements),
    .lsu_retirements    (lsu_retirements),
    .fpu_retirements    (fpu_retirements),
    .csr_retirement     (csr_retirement),
    .acc_retirement     (acc_retirement),
    .alu_wb_trace       (alu_wb_trace),
    .lsu_wb_trace       (lsu_wb_trace),
    .fpu_wb_trace       (fpu_wb_trace),
    .csr_wb_trace       (csr_wb_trace),
    .acc_wb_trace       (acc_wb_trace),
    .alu_resreq_traces  (alu_resreq_traces),
    .lsu_resreq_traces  (lsu_resreq_traces),
    .fpu_resreq_traces  (fpu_resreq_traces),
    .alu_rescap_traces  (alu_rescap_traces),
    .lsu_rescap_traces  (lsu_rescap_traces),
    .fpu_rescap_traces  (fpu_rescap_traces)
  );

  // pragma translate_on

endmodule
