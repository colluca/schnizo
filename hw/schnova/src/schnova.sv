// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

// Top-level of the Schnova core.
//
// As of this, it now features superscalar out of order execution
// in a region defined by an frep.o instruction.
// It also supports zero overhead loops (ZOL) via frep.i and frep.o instructions
// This core implements the following RISC-V extensions:
// - IMAFD (A ignoring aq and lr flags)
// - Zicsr, Zicntr (Cycle & Instret only, always enabled)
//
// Limitation:
// - Does not support precise exceptions when the core runs in superscalar out of order
//   mode
//
// Use automatic retiming options in the synthesis tool to optimize the fpnew design and multiplier in ALU
// if MulInALU0 parameter is set
module schnova import schnova_pkg::*, schnova_tracer_pkg::*; #(
  /// Boot address of core.
  parameter logic [31:0] BootAddr  = 32'h0000_1000,
  /// Physical Address width of the core.
  parameter int unsigned AddrWidth = 48,
  /// Data width of memory interface.
  parameter int unsigned DataWidth = 64,
  /// Enable Snitch DMA as accelerator.
  parameter bit          Xdma      = 0,
  /// Hardware loop feature for the schnova core (enable ZOL)
  parameter bit          XFREPI             = 1'b1,
  /// Superscalar out of order extension for the schnova core
  parameter bit          XFREPO             = 1'b1,
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
  /// Dispatch buffer configurations
  parameter int unsigned NofAluBufEntries = 32,
  parameter int unsigned NofLsuBufEntries = 32,
  parameter int unsigned NofFpuBufEntries = 32,
  parameter bit          MulInAlu0        = 1'b1,
  /// How many issued loads the LSU and thus the CAQ (consistency address queue) can hold.
  // This applies to all LSUs (each LSU can handle NumOutstandingLoads loads).
  parameter int unsigned NumOutstandingLoads = 0,
  /// How many total transactions (load and store) the LSU can handle at once
  // This applies to all LSUs (each LSU can handle NumOutstandingMem transactions).
  parameter int unsigned NumOutstandingMem = 0,
  /// Number of bits that get fetched per fetch request
  parameter int unsigned ICacheFetchDataWidth      = 0,
  /// Number of physical general purpose registers
  parameter int unsigned NofPhysGpr = 64,
  /// Number of physical floating point registers
  parameter int unsigned NofPhysFpr = 64,
  /// Number of total address bits needed to address both the FPR and GPR
  parameter int unsigned PhysRegAddrSize = 7,
  /// If a freelist based physical register reclamation strategy is used
  /// or a refernce counting based strategy.
  parameter bit          UseFreeList = 0,
  /// The amount of rob entries
  parameter int unsigned NofRobEntries = 128,
  // Physical memory attributes
  parameter snitch_pma_pkg::snitch_pma_t SnitchPMACfg = '{default: 0},
  /// Consistency Address Queue (CAQ) parameters
  parameter int unsigned CaqDepth    = 0,
  parameter int unsigned CaqTagWidth = 0,
  /// Enable debug support.
  parameter bit          DebugSupport = 0,
  /// FPU definitions
  parameter fpnew_pkg::fpu_implementation_t FPUImplementation = '0,
  /// Register the signals directly before the FPnew instance
  parameter bit RegisterFPUIn  = 0,
  /// Register the signals directly after the FPnew instance
  parameter bit RegisterFPUOut = 0,
  localparam type addr_t = logic [AddrWidth-1:0],
  localparam type data_t = logic [DataWidth-1:0]
) (
  input  logic                            clk_i,
  input  logic                            rst_i,
  input  logic [31:0]                     hart_id_i,
  input  interrupts_t                     irq_i,
  // Instruction cache flush request (for FENCE_I instruction)
  output logic                            flush_i_valid_o,
  // Flush has completed when the signal goes to `1`.
  // Tie to `1` if unused
  input  logic                            flush_i_ready_i,
  // Instruction Refill Port
  output addr_t                           inst_addr_o,
  output logic                            inst_cacheable_o,
  input  logic [ICacheFetchDataWidth-1:0] inst_data_i,
  output logic                            inst_valid_o,
  input  logic                            inst_ready_i,
  /// Accelerator Interface - Master Port
  /// Independent channels for transaction request and read completion.
  /// AXI-like handshaking.
  /// Same IDs need to be handled in-order.
  output acc_req_t                        acc_qreq_o,
  output logic                            acc_qvalid_o,
  input  logic                            acc_qready_i,
  input  acc_resp_t                       acc_prsp_i,
  input  logic                            acc_pvalid_i,
  output logic                            acc_pready_o,
  /// TCDM Data Interface
  /// Write transactions do not return data on the `P Channel`
  /// Transactions need to be handled strictly in-order.
  output dreq_t [NofLsus-1:0]             data_req_o,
  input  drsp_t [NofLsus-1:0]             data_rsp_i,
  /// Core events for performance counters
  output snitch_pkg::core_events_t        core_events_o,
  /// Cluster HW barrier
  output logic                            barrier_o,
  input  logic                            barrier_i
);

  //////////////////////////
  // Parameters and types //
  //////////////////////////

  localparam int unsigned XLEN = 32;

  // The pipeline width of the PipeWidth-wide superscalar schnova processor
  localparam int unsigned PipeWidth = ICacheFetchDataWidth/32;

  // Number of read ports to the physical register file, these ports are used to fetch
  // the operands from the physical register file during scalar execution mode
  localparam int unsigned NrIntReadPorts = 2;
  localparam int unsigned NrFpReadPorts = 3;

  // Number of write ports to the physical register file, in schnova these are 
  // set to the pipelinewidth to not have a bottleneck at the writeback stage
  localparam int unsigned NrIntWritePorts = PipeWidth;
  localparam int unsigned NrFpWritePorts = PipeWidth;

  // Number of reorder buffer write ports, has to have as many as there are potentially 
  // instructions that commit in one cycle
  localparam int unsigned NrRobWritePorts = NrIntWritePorts + NrFpWritePorts;

  // The address width for the physical register files
  // Note: Since the number of GPR and FPR can configured freely, these can differ
  // however there is a global address widtdh (PhysRegAddrSize) that is sized to accomodate
  // for both types of addresses.
  // In addition to that, there is the RegAddrSize this is the address width of the logical registers
  // defined by the ISA for this core 5 bits (32 logical registers)
  localparam int unsigned GprAddrWidth = $clog2(NofPhysGpr);
  localparam int unsigned FprAddrWidth = $clog2(NofPhysFpr);

  // Number of Register mapping table read and write ports
  // We have to read out a mapping for every source and destination operand
  // Integer instructons have 2 source + 1 destination register
  localparam int unsigned RmtNrIntReadPorts = 2*PipeWidth + 1*PipeWidth;
  // Float instructions have 3 source + 1 destination register
  localparam int unsigned RmtNrFpReadPorts = 3*PipeWidth + 1*PipeWidth;
  // We have to write the new mapping for every destination register
  localparam int unsigned RmtNrWritePorts = 1*PipeWidth;

  // The bit width of an operand. This is simply the maximal bit width such that we can have a
  // common data type for all FUs.
  localparam int OpLen = (FLEN > XLEN) ? FLEN : XLEN;

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
    logic                         use_rs1;
    logic [RegAddrSize-1:0]       rs2;
    logic                         rs2_is_fp; // set if rs2 is a FP register
    logic                         use_rs2;
    // Imm field: for unfinished floating-point fused operations (FMADD, FMSUB, FNMADD, FNMSUB)
    // this field holds the address of the third operand (rs3) from the floating-point regfile
    logic [XLEN-1:0]              imm;
    logic                         use_imm_as_rs3; // set if rs3 is a FP register
    logic                         use_imm;
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

  // Common type for both physical gpr and fpr addresses
  typedef logic [PhysRegAddrSize-1:0] phy_id_t;

  // Data type common for every fetch block that is fetched
  // this info is needed by the controller and frontend
  typedef struct packed {
    logic [XLEN-1:0]              imm;
    logic                         is_branch; // set if instruction is a branch
    logic                         is_jal; // set if JAL
    logic                         is_jalr; // set if JALR
    logic                         is_ctrl;
    logic [$clog2(PipeWidth)-1:0] instr_idx;
  } block_ctrl_info_t;

  // Common data type for input data to every functional unit
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

  // ----------------------------
  // RS definitions / parameters
  // ----------------------------

  localparam integer unsigned AluNofOperands = 2;
  localparam integer unsigned LsuNofOperands = 2; // the 3rd operand is the address offset which is a constant
  localparam integer unsigned FpuNofOperands = 3;

  // There are three types of Reservation Stations (RS); ALU, LSU and FPU RS.
  // Each of them has to fetch a number of operands from the register file
  // ALU: 
  // - operand A: Potentially from the GPR (if not a constant/immediate)
  // - operand B: Potentially from the GPR (if not a constant/immediate)
  // LSU:
  // - operand A: Always from the GPR
  // - operand B: Either from the GPR or the FPR
  // - imm: Immediate decoded from the instruction
  // FPU:
  // - operand A: Either from the GPR or the FPR
  // - operand B: From the FPR
  // - operand C: Potentially from the FPR (if not an immediate)
  // Note: ALU instructions can have constant values that are not directly derived from the
  // instruction (not immediates), for example that can be derived from the PC

  // Total number of operand interfaces, each operand interface can either fetch/request
  // an operand from the physical FPR or GPR
  localparam integer unsigned NofOperandIfs = NofAlus * AluNofOperands +
                                              NofLsus * LsuNofOperands +
                                              NofFpus * FpuNofOperands;

  // The number of operand read ports to the GPR and FPR is not the same since
  // some operands only have to read for example from the GPR or FPR for more information
  // see the explanation above
  localparam integer unsigned NofOperandGprReadPorts = NofAlus * 2 +
                                                       NofLsus * 2 +
                                                       NofFpus * 1;

  localparam integer unsigned NofOperandFprReadPorts = NofLsus * 1 +
                                                       NofFpus * 3;

  // Total number of functional units
  localparam integer unsigned NofFus = NofAlus + NofLsus + NofFpus;

  // Each RS has an unique number. The slots have unique numbers within the RS.
  localparam integer unsigned MaxNofRss = (AluNofRss > LsuNofRss) ?
                                          // AluNofRss > LsuNofRss
                                          ((AluNofRss > FpuNofRss) ? AluNofRss : FpuNofRss)
                                          : // AluNofRss < LsuNofRss
                                          ((LsuNofRss > FpuNofRss) ? LsuNofRss : FpuNofRss);

  localparam integer unsigned SlotIdWidth = cf_math_pkg::idx_width(MaxNofRss);
  localparam integer unsigned RsIdWidth  = cf_math_pkg::idx_width(NofFus);

  typedef logic [SlotIdWidth-1:0] slot_id_t;
  typedef logic [RsIdWidth-1:0]   rs_id_t;

  // Each Reorderbuffer entry has an assocaiated tag, the address/tag widtdh is 
  // defined by the reorder buffer size
  localparam int unsigned RobTagWidth = $clog2(NofRobEntries);

  // Type that uniquely defines an reservation station slot
  typedef struct packed {
    slot_id_t slot_id; // used to select the slot of the request within the RS
    rs_id_t   rs_id;   // used to control the request crossbar
  } producer_id_t;

  // Type for the tag (additional information) that every instruction carries
  // through the pipeline. This tag is then needed at specific stages in the pipeline
  // for example in the writeback to know where to writeback this value to.
  typedef struct packed {
    producer_id_t               producer_id;
    phy_id_t                    dest_reg;
    logic [RobTagWidth-1:0]     rob_tag;
    logic                       dest_reg_is_fp;
    logic                       is_branch;
    logic                       is_jump;
  } instr_tag_t;

  // ---------------------------
  // Dispatch/issue/result data types
  // ---------------------------

  // Dispatch response type, every dispatch request leads to a response. This
  // type is used to identify which functional unit responded to the dispatch request
  typedef struct packed {
    producer_id_t producer;
  } disp_rsp_t;

  // Data type for information that the scoreboard needs for every dispatched
  // instruction
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

  // Register mapping table, data type contains information about all the physical
  // source and destination register addresses
  typedef struct packed {
    phy_id_t phy_reg_rs1;
    phy_id_t phy_reg_rs2;
    phy_id_t phy_reg_rs3;
    phy_id_t phy_reg_rd_new;
    phy_id_t phy_reg_rd_old;
  } reg_map_t;

  typedef struct packed {
    csr_op_e          csr_op;
    logic [OpLen-1:0] operand_a;
    logic [11:0]      imm;
    instr_tag_t tag;
  } csr_disp_req_t;

  typedef csr_disp_req_t csr_issue_req_t;

  typedef struct packed {
    alu_op_e         alu_op;
    logic [XLEN-1:0] operand_a;
    logic [XLEN-1:0] operand_b;
    instr_tag_t      tag;
  } alu_si_disp_req_t;

  typedef struct packed {
    alu_op_e         alu_op;
    logic [XLEN-1:0] operand_a;
    logic [XLEN-1:0] operand_b;
    instr_tag_t      tag;
    phy_id_t         phy_reg_op_a;
    logic            is_op_a_cnst;
    phy_id_t         phy_reg_op_b;
    logic            is_op_b_cnst;
  } alu_rs_disp_req_t;

  typedef struct packed {
    lsu_op_e          lsu_op;
    logic [XLEN-1:0]  operand_a; // Can only be an integer value
    logic [OpLen-1:0] operand_b; // Can be either integer or floating point
    logic [XLEN-1:0]  imm;       // Only ever used as an integer
    lsu_size_e        lsu_size;
    instr_tag_t       tag;
  } lsu_si_disp_req_t;

  typedef struct packed {
    lsu_op_e          lsu_op;
    logic [XLEN-1:0]  imm;       // Only ever used as an integer
    lsu_size_e        lsu_size;
    instr_tag_t       tag;
    phy_id_t          phy_reg_op_a;
    phy_id_t          phy_reg_op_b;
    logic             is_op_b_fp;
  } lsu_rs_disp_req_t;

  typedef struct packed {
    fpu_op_e               fpu_op;
    logic [OpLen-1:0]      operand_a;
    logic [OpLen-1:0]      operand_b;
    logic [OpLen-1:0]      imm;
    fpnew_pkg::fp_format_e fpu_fmt_src;
    fpnew_pkg::fp_format_e fpu_fmt_dst;
    fpnew_pkg::roundmode_e fpu_rnd_mode;
    instr_tag_t            tag;
  } fpu_si_disp_req_t;

  typedef struct packed {
    fpu_op_e               fpu_op;
    logic [OpLen-1:0]      imm;
    fpnew_pkg::fp_format_e fpu_fmt_src;
    fpnew_pkg::fp_format_e fpu_fmt_dst;
    fpnew_pkg::roundmode_e fpu_rnd_mode;
    instr_tag_t            tag;
    phy_id_t               phy_reg_op_a;
    logic                  is_op_a_fp;
    phy_id_t               phy_reg_op_b;
    phy_id_t               phy_reg_op_c;
    logic                  is_op_c_cnst;
  } fpu_rs_disp_req_t;

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

  typedef logic [FLEN-1:0] fpu_result_t;

  typedef struct packed {
    phy_id_t  phy_reg; // which physical register we request
    logic     is_fp;   // if the physical register is a FPR
  } operand_req_t;

  typedef struct packed {
    phy_id_t phy_reg_op_a;
    logic is_op_a_cnst;
    logic is_op_a_fp;
    phy_id_t phy_reg_op_b;
    logic is_op_b_cnst;
    logic is_op_b_fp;
    phy_id_t phy_reg_op_c;
    logic is_op_c_cnst;
  } refcnt_req_t;

  typedef logic [OpLen-1:0] operand_t;

  // ----------------------------------------
  // Global Signals
  // Signals connecting more than one module
  // ----------------------------------------
  logic       [PipeWidth-1:0][31:0] instr_fetch_data;
  instr_dec_t [PipeWidth-1:0]       instr_decoded;
  logic       [PipeWidth-1:0]       instr_valid_masked;
  logic       [PipeWidth-1:0]       instr_rename_gpr_valid;
  logic       [$clog2(PipeWidth):0] instr_rename_gpr_count;
  logic       [PipeWidth-1:0]       instr_rename_fpr_valid;
  logic       [$clog2(PipeWidth):0] instr_rename_fpr_count;

  logic [31:0]              pc;
  fu_data_t [PipeWidth-1:0] fu_data;
  reg_map_t [PipeWidth-1:0] reg_map;

  logic        dispatched;
  logic        en_superscalar;
  logic        instr_exec_commit;
  logic        rs_restart;
  loop_state_e loop_state;

  // ---------------------
  // Frontend <-> Decoder
  // ---------------------
  logic [PipeWidth-1:0] instr_fetch_data_valid;


  // ------------------------
  // Frontend <-> Controller
  // ------------------------
  logic [XLEN-1:0] next_pc;
  logic            loop_jump;
  logic [31:0]     loop_jump_addr;


  // ---------------------------
  // Frontend <-> Read Operands
  // ---------------------------
  logic [31:0] jump_pc;


  // -----------------------
  // Frontend <-> Writeback
  // -----------------------
  logic [XLEN-1:0] consecutive_pc;


  // -----------------------
  // Decoder <-> Controller
  // -----------------------
  logic [PipeWidth-1:0] instr_valid;
  logic [PipeWidth-1:0] instr_decoded_illegal;
  block_ctrl_info_t     blk_ctrl_info;
  block_ctrl_info_t     blk_ctrl_info_masked;


  // ----------------
  // Decoder <-> CSR
  // ----------------
  fpnew_pkg::roundmode_e fpu_rnd_mode;
  fpnew_pkg::fmt_mode_t  fpu_fmt_mode; 

 
  // -----------------------------------------
  // Read operands <-> Physical Register File
  // -----------------------------------------
  logic [NrIntReadPorts-1:0][GprAddrWidth-1:0]  gpr_raddr;
  logic [NrIntReadPorts-1:0][XLEN-1:0]          gpr_rdata;
  logic [NrIntWritePorts-1:0][GprAddrWidth-1:0] gpr_waddr;
  logic [NrIntWritePorts-1:0][XLEN-1:0]         gpr_wdata;
  logic [NrIntWritePorts-1:0]                   gpr_we;

  logic [NrFpReadPorts-1:0][FprAddrWidth-1:0]  fpr_raddr;
  logic [NrFpReadPorts-1:0][FLEN-1:0]          fpr_rdata;
  logic [NrFpWritePorts-1:0][FprAddrWidth-1:0] fpr_waddr;
  logic [NrFpWritePorts-1:0][FLEN-1:0]         fpr_wdata;
  logic [NrFpWritePorts-1:0]                   fpr_we;


  // ----------------------------
  // Controller <-> CSR/Frontend
  // ----------------------------
  logic [$clog2(PipeWidth):0] instr_valid_count;
  logic                       instr_illegal;
  logic                       enter_wfi;
  logic                       ebreak;
  logic                       ecall;
  logic                       mret;
  logic                       sret;
  logic [31:0]                mtvec;
  logic [31:0]                mepc;
  logic [31:0]                sepc;
  logic                       stall;
  logic                       csr_exception_raw;
  logic                       barrier_stall;
  logic                       instr_addr_misaligned;
  logic                       lsu_addr_misaligned;
  logic                       load_addr_misaligned;
  logic                       store_addr_misaligned;
  priv_lvl_t                  priv_lvl;
  logic                       interrupt;
  logic                       exception;
  logic                       wfi; // asserted if we are waiting for an interrupt


  // --------------------------
  // Controller <-> Dispatcher
  // --------------------------
  logic dispatch_instr_valid;
  logic dispatch_instr_ready;
  logic disp_buffers_empty;


  // ------------------------
  // Controller <-> FU Stage
  // ------------------------
  logic fpu_instr_exec_commit;


  // --------------------------
  // Controller <-> Scoreboard
  // --------------------------
  logic registers_ready;
  logic sb_busy;
  // -------------------------
  // Controller <-> Writeback
  // -------------------------
  logic ctrl_instr_retired;

  // -------------------
  // Dispatcher <-> CSR
  // -------------------
  frep_mem_cons_mode_e frep_mem_cons_mode;
  logic [NofLsus-1:0]  frep_lsu_load_en;
  logic [NofLsus-1:0]  frep_lsu_store_en;
  csr_disp_req_t       csr_disp_req;
  logic                csr_disp_req_valid;
  logic                csr_disp_req_ready;
  csr_issue_req_t      csr_issue_req;

  // ------------------------
  // Dispatcher <-> FU Stage
  // ------------------------
  alu_si_disp_req_t               alu_si_disp_req;
  logic                           alu_si_disp_req_valid;
  logic                           alu_si_disp_req_ready;
  alu_rs_disp_req_t [NofAlus-1:0] alu_rs_disp_reqs;
  logic             [NofAlus-1:0] alu_rs_disp_req_valid;
  logic             [NofAlus-1:0] alu_rs_disp_req_ready;
  disp_rsp_t        [NofAlus-1:0] alu_rs_disp_rsp;
  logic             [NofAlus-1:0] alu_rs_full;
  lsu_si_disp_req_t               lsu_si_disp_req;
  logic                           lsu_si_disp_req_valid;
  logic                           lsu_si_disp_req_ready;
  lsu_rs_disp_req_t [NofLsus-1:0] lsu_rs_disp_reqs;
  logic             [NofLsus-1:0] lsu_rs_disp_req_valid;
  logic             [NofLsus-1:0] lsu_rs_disp_req_ready;
  disp_rsp_t        [NofLsus-1:0] lsu_rs_disp_rsp;
  logic             [NofLsus-1:0] lsu_rs_full;
  fpu_si_disp_req_t               fpu_si_disp_req;
  logic                           fpu_si_disp_req_valid;
  logic                           fpu_si_disp_req_ready;
  fpu_rs_disp_req_t [NofFpus-1:0] fpu_rs_disp_reqs;
  logic             [NofFpus-1:0] fpu_rs_disp_req_valid;
  logic             [NofFpus-1:0] fpu_rs_disp_req_ready;
  disp_rsp_t        [NofFpus-1:0] fpu_rs_disp_rsp;
  logic             [NofFpus-1:0] fpu_rs_full;


  // -----------------------------------------
  // Dispatcher <-> Physical Register Manager
  // -----------------------------------------
  refcnt_req_t [PipeWidth-1:0] refcnt_disp_req;

  // -----------------------
  // FU Stage <-> Writeback
  // -----------------------
  alu_result_t [NofAlus-1:0] alu_results;
  instr_tag_t  [NofAlus-1:0] alu_results_tag;


  // ----------------------
  // FU Stage <-> Frontend
  // ----------------------
  alu_result_t branch_result;


  // ------------------------
  // FU Stage <-> Controller
  // ------------------------
  logic lsu_empty;


  // -----------------
  // FU Stage <-> CSR
  // -----------------
  fpnew_pkg::status_t fpu_status;
  logic               fpu_status_valid;


  // ------------------------------------
  // FU Stage <-> Physical Register File
  // ------------------------------------
  operand_req_t [NofOperandIfs-1:0] op_reqs;
  operand_t [NofOperandIfs-1:0]     op_rsps_data;
  logic [NofOperandIfs-1:0]         op_rsps_valid;
  operand_t [NofOperandIfs-1:0]     op_rsps_fpr_data;
  operand_t [NofOperandIfs-1:0]     op_rsps_gpr_data;

  
  // ---------------------------------------
  // FU Stage <-> Physical Register Manager
  // ---------------------------------------
  logic        [NofAlus-1:0] issue_alu_clr_req_valid;
  refcnt_req_t [NofAlus-1:0] issue_alu_clr_req;
  logic        [NofLsus-1:0] issue_lsu_clr_req_valid;
  refcnt_req_t [NofLsus-1:0] issue_lsu_clr_req;
  logic        [NofFpus-1:0] issue_fpu_clr_req_valid;
  refcnt_req_t [NofFpus-1:0] issue_fpu_clr_req;
  

  logic [NofAlus-1:0]                  alu_rob_z_wb_valid;
  logic [NofAlus-1:0][RobTagWidth-1:0] alu_rob_z_tag;
  logic [NofLsus-1:0]                  lsu_rob_z_wb_valid;
  logic [NofLsus-1:0][RobTagWidth-1:0] lsu_rob_z_tag;
  logic [NofFpus-1:0]                  fpu_rob_z_wb_valid;
  logic [NofFpus-1:0][RobTagWidth-1:0] fpu_rob_z_tag;


  // --------------------
  // FU Stage <-> Tracer
  // --------------------
  // Trace signals
  // pragma translate_off
  issue_alu_trace_t  alu_trace       [NofAlus];
  issue_lsu_trace_t  lsu_trace       [NofLsus];
  issue_fpu_trace_t  fpu_trace       [NofFpus];
  retire_fu_trace_t  alu_retirements [NofAlus];
  retire_fu_trace_t  lsu_load_retirements [NofLsus];
  retire_fu_trace_t  lsu_store_retirements [NofLsus];
  retire_fu_trace_t  fpu_retirements [NofFpus];
  // pragma translate_on


  // -----------------------------------
  // Physical Reg Manage <-> Controller
  // -----------------------------------
  logic phy_reg_alloc_ready;


  // -----------------------------------
  // Physical Reg Manage <-> Dispatcher
  // -----------------------------------
  phy_id_t [PipeWidth-1:0]                  allocated_gpr_regs;
  phy_id_t [PipeWidth-1:0]                  allocated_fpr_regs;
  logic                                     first_instr_dispatched;
  logic    [PipeWidth-1:0][RobTagWidth-1:0] rob_idx;
  logic                                     rob_ready;

  // -----------------------------------
  // Physical Reg Manage <-> Scoreboard
  // -----------------------------------
  logic [NofPhysGpr-1:0] sbi_q;
  logic [NofPhysFpr-1:0] sbf_q;


  // --------------------------------------
  // Scoreboard <-> Physical Register File
  // --------------------------------------
  logic [NofOperandIfs-1:0][PhysRegAddrSize-1:0] sb_raddr;
  logic [NofOperandIfs-1:0]                      sb_read_fp;
  logic [NofOperandIfs-1:0]                      sb_rdata;


  // -------------------------------------
  // Writeback <-> Physical Register File
  // -------------------------------------
  logic [NrRobWritePorts-1:0]                   wb_valid;
  logic [NrRobWritePorts-1:0][RobTagWidth-1:0]  wb_rob_idx;
    logic       [NofAlus-1:0]                   alu_results_valid;
  logic         [NofAlus-1:0]                   alu_results_ready;
  logic         [NofLsus-1:0]                   lsu_results_valid;
  logic         [NofLsus-1:0]                   lsu_results_ready;
  instr_tag_t   [NofLsus-1:0]                   lsu_results_tag;
  data_t        [NofLsus-1:0]                   lsu_results;
  fpu_result_t  [NofFpus-1:0]                   fpu_results;
  logic         [NofFpus-1:0]                   fpu_results_valid;
  logic         [NofFpus-1:0]                   fpu_results_ready;
  instr_tag_t   [NofFpus-1:0]                   fpu_results_tag;


  // ------------------
  // Writeback <-> CSR
  // ------------------
  logic csr_result_valid;
  logic csr_result_ready;
  instr_tag_t csr_result_tag;
  logic [XLEN-1:0] csr_result;


  // ------------
  // Core Events
  // ------------
  // Store if an instruction has retired last cycle and store the type of instruction retired
  logic instr_retired,              instr_retired_q;
  logic instr_retired_single_cycle, instr_retired_single_cycle_q;
  logic instr_retired_load,         instr_retired_load_q;
  logic instr_retired_acc,          instr_retired_acc_q;

  // 1to1 from Snitch FP SS
  logic issue_fpu,         issue_fpu_q;
  logic issue_core_to_fpu, issue_core_to_fpu_q;
  // we do not have a sequencer.

  // ------
  // State
  // ------
  `FFAR(instr_retired_q,              instr_retired,              '0, clk_i, rst_i)
  `FFAR(instr_retired_single_cycle_q, instr_retired_single_cycle, '0, clk_i, rst_i)
  `FFAR(instr_retired_load_q,         instr_retired_load,         '0, clk_i, rst_i)
  `FFAR(instr_retired_acc_q,          instr_retired_acc,          '0, clk_i, rst_i)
  `FFAR(issue_fpu_q,                  issue_fpu,                  '0, clk_i, rst_i)
  `FFAR(issue_core_to_fpu_q,          issue_core_to_fpu,          '0, clk_i, rst_i)

  // -----------------------------
  // Frontend (Instruction Fetch)
  // -----------------------------
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
    // To/From L0 Instruction Cache
    .instr_fetch_data_i       (inst_data_i),
    .instr_fetch_valid_o      (inst_valid_o),
    .instr_fetch_ready_i      (inst_ready_i),
    .instr_fetch_addr_o       (inst_addr_o),
    .instr_fetch_cacheable_o  (inst_cacheable_o),
    // From controller
    .instr_valid_count_i      (instr_valid_count),
    .exception_i              (exception),
    .stall_i                  (stall),
    .mret_i                   (mret),
    .sret_i                   (sret),
    .en_superscalar_i         (en_superscalar),
    .loop_jump_i              (loop_jump),
    .loop_jump_addr_i         (loop_jump_addr),
    // To controller / CSR
    .pc_o                     (pc),
    .next_pc_o                (next_pc),
    // To Writeback
    .consecutive_pc_o         (consecutive_pc),
    // To Read Operands
    .jump_pc_o                (jump_pc),
    // From CSR (Exception Source Interface)
    .wfi_i                    (wfi),
    .barrier_stall_i          (barrier_stall),
    .mtvec_i                  (mtvec),
    .mepc_i                   (mepc),
    .sepc_i                   (sepc),
    // From ALU0 (branch result)
    .alu_compare_res_i        (branch_result.compare_res),
    .alu_result_i             (branch_result.result),
    // From decoder
    .blk_ctrl_info_i          (blk_ctrl_info_masked),
    // To Decoder / Dispatcher
    .instr_fetch_data_o      (instr_fetch_data),
    .instr_fetch_data_valid_o(instr_fetch_data_valid)
  );


  // --------
  // Decoder
  // --------
  schnova_decoder #(
    .XLEN              (XLEN),
    .XFREPI            (XFREPI),
    .XFREPO            (XFREPO),
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
    // From Dispatcher
    .instr_fetch_data_i      (instr_fetch_data),
    .instr_fetch_data_valid_i(instr_fetch_data_valid),
    // From CSR
    .fpu_round_mode_i        (fpu_rnd_mode),
    .fpu_fmt_mode_i          (fpu_fmt_mode),
    // To Controller
    .instr_valid_o           (instr_valid),
    .instr_illegal_o         (instr_decoded_illegal),
    .blk_ctrl_info_o         (blk_ctrl_info),
    // Decoded Instruction
    .instr_dec_o             (instr_decoded)
  );


  // --------------
  // Read Operands
  // --------------
  // Read the operands - do always read (even if invalid instr) because controller depends on
  // values from registers. See for example the FREP instruction and its number of iterations.
  schnova_read_operands #(
    .PipeWidth     (PipeWidth),
    .XLEN          (XLEN),
    .FLEN          (FLEN),
    .GprAddrWidth  (GprAddrWidth),
    .FprAddrWidth  (FprAddrWidth),
    .NrIntReadPorts(NrIntReadPorts),
    .NrFpReadPorts (NrFpReadPorts),
    .instr_dec_t   (instr_dec_t),
    .reg_map_t     (reg_map_t),
    .fu_data_t     (fu_data_t)
  ) i_read_operands (
    .en_superscalar_i(en_superscalar),
    // From Frontend
    .jump_pc_i       (jump_pc),
    // From Decoder
    .instr_dec_i     (instr_decoded),
    // From Renaming Stage
    .reg_map_i  (reg_map[0]), // Only the first instruction directly reads its operands
    // From / To Physical Register File
    .gpr_raddr_o(gpr_raddr),
    .gpr_rdata_i(gpr_rdata),
    .fpr_raddr_o(fpr_raddr),
    .fpr_rdata_i(fpr_rdata),
    // To Dispatcher and Controller (For Frep Iterations)
    .fu_data_o  (fu_data)
  );


  // -----------
  // Controller
  // -----------
  logic all_rs_finish;
  logic rs_idle;

  schnova_controller #(
    .PipeWidth          (PipeWidth),
    .XLEN               (XLEN),
    .XFREPI             (XFREPI),
    .XFREPO             (XFREPO),
    .NrIntWritePorts    (NrIntWritePorts),
    .NrFpWritePorts     (NrFpWritePorts),
    .RegAddrSize        (RegAddrSize),
    .MaxIterationsWidth (FrepMaxItersWidth),
    .instr_dec_t        (instr_dec_t),
    .block_ctrl_info_t  (block_ctrl_info_t),
    .priv_lvl_t         (priv_lvl_t)
  ) i_controller (
    .clk_i,
    .rst_i,
    // Frontend interface
    .flush_i_ready_i        (flush_i_ready_i),
    .flush_i_valid_o        (flush_i_valid_o),
    .pc_i                   (pc),
    .next_pc_i              (next_pc),
    .loop_jump_o            (loop_jump),
    .loop_jump_addr_o       (loop_jump_addr),
    // Decoder interface
    .instr_decoded_i        (instr_decoded),
    .instr_valid_i          (instr_valid),
    .instr_valid_o           (instr_valid_masked),
    .instr_decoded_illegal_i(instr_decoded_illegal),
    .blk_ctrl_info_i        (blk_ctrl_info),
    .blk_ctrl_info_masked_o (blk_ctrl_info_masked),
    .instr_valid_count_o     (instr_valid_count),
    .instr_rename_gpr_valid_o(instr_rename_gpr_valid),
    .instr_rename_gpr_count_o(instr_rename_gpr_count),
    .instr_rename_fpr_valid_o(instr_rename_fpr_valid),
    .instr_rename_fpr_count_o(instr_rename_fpr_count),
    // Special FREP data
    .frep_iterations_i      (fu_data[0].operand_a[FrepMaxItersWidth-1:0]),
    // To rename stage
    .dispatched_o(dispatched),
    .phy_reg_alloc_ready_i(phy_reg_alloc_ready),
    .rs_idle_i(rs_idle),
    .rs_restart_o(rs_restart),
    // ROB
    .rob_ready_i(rob_ready),
    // Interface to dispatcher
    .dispatch_instr_valid_o (dispatch_instr_valid),
    .dispatch_instr_ready_i (dispatch_instr_ready),
    .instr_exec_commit_o    (instr_exec_commit),
    .fpu_instr_exec_commit_o(fpu_instr_exec_commit),
    .stall_o                (stall),
    // Writeback interface
    .ctrl_instr_retired_i(ctrl_instr_retired),
    // Exception source interface
    .interrupt_i            (interrupt),
    .csr_exception_raw_i    (csr_exception_raw),
    .lsu_empty_i            (lsu_empty),
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
    .loop_state_o           (loop_state),
    // GPR & FPR Write back snooping for Scoreboard
    .registers_ready_i      (registers_ready),
    .sb_busy_i              (sb_busy)
  );

  // The reservation is idle if there are no instructions inflight targeting reservation stations
  // This is the case if
  // 1) The dispatch buffer is empty (otherwise new instruction can be dispatched to the rs even if the frontend is stalled)
  // 2) The reservation stations is empty and the functional units are not busy
  assign rs_idle = all_rs_finish && disp_buffers_empty;


  // -------
  // Rename
  // -------
  if (XFREPO) begin : gen_rename
    schnova_rename #(
      .PipeWidth        (PipeWidth),
      .RmtNrIntReadPorts(RmtNrIntReadPorts),
      .RmtNrFpReadPorts (RmtNrFpReadPorts),
      .RmtNrWritePorts  (RmtNrWritePorts),
      .RegAddrSize      (RegAddrSize),
      .NofPhysGpr       (NofPhysGpr),
      .NofPhysFpr       (NofPhysFpr),
      .instr_dec_t      (instr_dec_t),
      .phy_id_t         (phy_id_t),
      .reg_map_t        (reg_map_t)
    ) i_rename (
      .clk_i,
      .rst_i,
      // From Decoder
      .instr_dec_i              (instr_decoded),
      // From Controller
      .en_superscalar_i         (en_superscalar),
      .dispatched_i             (dispatched),
      .instr_rename_gpr_valid_i (instr_rename_gpr_valid),
      .instr_rename_fpr_valid_i (instr_rename_fpr_valid),
      // From Physical Register Management
      .allocated_gpr_regs_i     (allocated_gpr_regs),
      .allocated_fpr_regs_i     (allocated_fpr_regs),
      // Register Mapping output
      .reg_map_o                (reg_map)
    );
  end else begin : gen_no_rename
    // If XFREPO is not enabled, the core is a scalar core
    // no superscalar out of order is enabled so we don't need
    // renaming.
    assign reg_map[0] = '{
      phy_reg_rs1:      instr_decoded[0].rs1,
      phy_reg_rs2:      instr_decoded[0].rs2,
      phy_reg_rs3:      instr_decoded[0].imm[RegAddrSize-1:0],
      phy_reg_rd_new :  '0,
      phy_reg_rd_old :  instr_decoded[0].rd
    };
  end


  // -----------
  // Dispatcher
  // -----------
  schnova_dispatcher #(
    .XFREPO           (XFREPO),
    .UseFreeList      (UseFreeList),
    .PipeWidth        (PipeWidth),
    .XLEN             (XLEN),
    .RobTagWidth      (RobTagWidth),
    .NofAlus          (NofAlus),
    .NofLsus          (NofLsus),
    .NofFpus          (NofFpus),
    .NofAluBufEntries (NofAluBufEntries),
    .NofLsuBufEntries (NofLsuBufEntries),
    .NofFpuBufEntries (NofFpuBufEntries),
    .instr_dec_t      (instr_dec_t),
    .reg_map_t        (reg_map_t),
    .instr_tag_t      (instr_tag_t),
    .csr_disp_req_t   (csr_disp_req_t),
    .alu_si_disp_req_t(alu_si_disp_req_t),
    .lsu_si_disp_req_t(lsu_si_disp_req_t),
    .fpu_si_disp_req_t(fpu_si_disp_req_t),
    .alu_rs_disp_req_t(alu_rs_disp_req_t),
    .lsu_rs_disp_req_t(lsu_rs_disp_req_t),
    .fpu_rs_disp_req_t(fpu_rs_disp_req_t),
    .disp_rsp_t       (disp_rsp_t),
    .refcnt_req_t     (refcnt_req_t),
    .producer_id_t    (producer_id_t),
    .rs_id_t          (rs_id_t),
    .fu_data_t        (fu_data_t),
    .acc_req_t        (acc_req_t),
    .sb_disp_data_t   (sb_disp_data_t)
  ) i_dispatcher (
    .clk_i,
    .rst_i,
    // From / To Controller
    .en_superscalar_i         (en_superscalar),
    .restart_i                (rs_restart),
    .dispatch_valid_i         (dispatch_instr_valid),
    .dispatch_ready_o         (dispatch_instr_ready),
    .instr_valid_i            (instr_valid_masked),
    .instr_rename_gpr_valid_i (instr_rename_gpr_valid),
    .instr_rename_gpr_count_i (instr_rename_gpr_count),
    .instr_rename_fpr_valid_i (instr_rename_fpr_valid),
    .instr_rename_fpr_count_i (instr_rename_fpr_count),
    .instr_exec_commit_i      (instr_exec_commit),
    .disp_buffers_empty_o     (disp_buffers_empty),
    // From Decoder
    .instr_dec_i              (instr_decoded),
    // From Rename
    .reg_map_i                (reg_map),
    // From Read Operands
    .instr_fu_data_i          (fu_data),
    .instr_fetch_data_i       (instr_fetch_data),
    // From CSR
    .frep_mem_cons_mode_i     (frep_mem_cons_mode),
    .frep_lsu_load_en_i       (frep_lsu_load_en),
    .frep_lsu_store_en_i      (frep_lsu_store_en),
    // From / To Physical Register Manager
    .first_instr_dispatched_o (first_instr_dispatched),
        .refcnt_disp_req_o    (refcnt_disp_req),
    .rob_idx_i                (rob_idx),
    // ALU Dispatch
    .alu_si_disp_req_o        (alu_si_disp_req),
    .alu_si_disp_req_valid_o  (alu_si_disp_req_valid),
    .alu_si_disp_req_ready_i  (alu_si_disp_req_ready),
    .alu_rs_disp_reqs_o       (alu_rs_disp_reqs),
    .alu_rs_disp_req_valid_o  (alu_rs_disp_req_valid),
    .alu_rs_disp_req_ready_i  (alu_rs_disp_req_ready),
    .alu_rs_disp_rsp_i        (alu_rs_disp_rsp),
    .alu_rs_full_i            (alu_rs_full),
    // LSU Dispatch
    .lsu_si_disp_req_o        (lsu_si_disp_req),
    .lsu_si_disp_req_valid_o  (lsu_si_disp_req_valid),
    .lsu_si_disp_req_ready_i  (lsu_si_disp_req_ready),
    .lsu_rs_disp_reqs_o       (lsu_rs_disp_reqs),
    .lsu_rs_disp_req_valid_o  (lsu_rs_disp_req_valid),
    .lsu_rs_disp_req_ready_i  (lsu_rs_disp_req_ready),
    .lsu_rs_disp_rsp_i        (lsu_rs_disp_rsp),
    .lsu_rs_full_i            (lsu_rs_full),
    // CSR Dispatch
    .csr_disp_req_o           (csr_disp_req),
    .csr_disp_req_valid_o     (csr_disp_req_valid),
    .csr_disp_req_ready_i     (csr_disp_req_ready),
    // FPU Dispatch
    .fpu_si_disp_req_o        (fpu_si_disp_req),
    .fpu_si_disp_req_valid_o  (fpu_si_disp_req_valid),
    .fpu_si_disp_req_ready_i  (fpu_si_disp_req_ready),
    .fpu_rs_disp_reqs_o       (fpu_rs_disp_reqs),
    .fpu_rs_disp_req_valid_o  (fpu_rs_disp_req_valid),
    .fpu_rs_disp_req_ready_i  (fpu_rs_disp_req_ready),
    .fpu_rs_disp_rsp_i        (fpu_rs_disp_rsp),
    .fpu_rs_full_i            (fpu_rs_full),
    // ACC Dispatch
    .acc_req_o                (acc_qreq_o),
    .acc_disp_req_valid_o     (acc_qvalid_o),
    .acc_disp_req_ready_i     (acc_qready_i)
  );


  // ---------
  // FU Stage
  // ---------
  schnova_fu_stage #(
    .XFREPO             (XFREPO),
    .UseFreeList        (UseFreeList),
    .RobTagWidth        (RobTagWidth),
    .MulInAlu0          (MulInAlu0),
    .NofAlus            (NofAlus),
    .AluNofRss          (AluNofRss),
    .AluNofOperands     (AluNofOperands),
    .NofLsus            (NofLsus),
    .LsuNofRss          (LsuNofRss),
    .LsuNofOperands     (LsuNofOperands),
    .NofFpus            (NofFpus),
    .FpuNofRss          (FpuNofRss),
    .FpuNofOperands     (FpuNofOperands),
    .NofOperandIfs      (NofOperandIfs),
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
    .alu_si_disp_req_t  (alu_si_disp_req_t),
    .lsu_si_disp_req_t  (lsu_si_disp_req_t),
    .fpu_si_disp_req_t  (fpu_si_disp_req_t),
    .alu_rs_disp_req_t  (alu_rs_disp_req_t),
    .lsu_rs_disp_req_t  (lsu_rs_disp_req_t),
    .fpu_rs_disp_req_t  (fpu_rs_disp_req_t),
    .disp_rsp_t         (disp_rsp_t),
    .fu_data_t          (fu_data_t),
    .phy_id_t           (phy_id_t),
    .operand_req_t      (operand_req_t),
    .operand_t          (operand_t),
    .instr_tag_t        (instr_tag_t),
    .issue_req_t        (issue_req_t),
    .alu_result_t       (alu_result_t),
    .fpu_result_t       (fpu_result_t),
    .alu_res_val_t      (alu_res_val_t),
    .refcnt_req_t       (refcnt_req_t),
    .dreq_t             (dreq_t),
    .drsp_t             (drsp_t)
  ) i_fu_stage (
    .clk_i,
    .rst_i,
    .hart_id_i                (hart_id_i),
    // From / To Controller
    .restart_i                (rs_restart),
    .en_superscalar_i         (en_superscalar),
    .all_rs_finish_o          (all_rs_finish),
    .instr_exec_commit_i      (instr_exec_commit),
    .fpu_instr_exec_commit_i  (fpu_instr_exec_commit),
    // To Tracer
    // pragma translate_off
    .alu_trace_o              (alu_trace),
    .lsu_trace_o              (lsu_trace),
    .fpu_trace_o              (fpu_trace),
    .alu_retire_trace_o       (alu_retirements),
    .lsu_load_retire_trace_o  (lsu_load_retirements),
    .lsu_store_retire_trace_o (lsu_store_retirements),
    .fpu_retire_trace_o       (fpu_retirements),
    // pragma translate_on
    // ALU Dispatch
    .alu_si_disp_req_i        (alu_si_disp_req),
    .alu_si_disp_req_valid_i  (alu_si_disp_req_valid),
    .alu_si_disp_req_ready_o  (alu_si_disp_req_ready),
    .alu_rs_disp_reqs_i       (alu_rs_disp_reqs),
    .alu_rs_disp_reqs_valid_i (alu_rs_disp_req_valid),
    .alu_rs_disp_reqs_ready_o (alu_rs_disp_req_ready),
    .alu_rs_disp_rsp_o        (alu_rs_disp_rsp),
    .alu_rs_full_o            (alu_rs_full),
    // LSU Dispatch
    .lsu_si_disp_req_i        (lsu_si_disp_req),
    .lsu_si_disp_req_valid_i  (lsu_si_disp_req_valid),
    .lsu_si_disp_req_ready_o  (lsu_si_disp_req_ready),
    .lsu_rs_disp_reqs_i       (lsu_rs_disp_reqs),
    .lsu_rs_disp_reqs_valid_i (lsu_rs_disp_req_valid),
    .lsu_rs_disp_reqs_ready_o (lsu_rs_disp_req_ready),
    .lsu_rs_disp_rsp_o        (lsu_rs_disp_rsp),
    .lsu_empty_o              (lsu_empty),
    .lsu_addr_misaligned_o    (lsu_addr_misaligned),
    .lsu_dreq_o               (data_req_o), // Each LSU has its own reqrsp port
    .lsu_drsp_i               (data_rsp_i), // Each LSU has its own reqrsp port
    .lsu_rs_full_o            (lsu_rs_full),
    // LSU CAQ Signals
    .caq_addr_i               ('0),
    .caq_track_write_i        ('0),
    .caq_req_valid_i          ('0),
    .caq_req_ready_o          (),
    .caq_rsp_valid_i          ('0),
    .caq_rsp_valid_o          (),
    //FPU Dispatch
    .fpu_si_disp_req_i        (fpu_si_disp_req),
    .fpu_si_disp_req_valid_i  (fpu_si_disp_req_valid),
    .fpu_si_disp_req_ready_o  (fpu_si_disp_req_ready),
    .fpu_rs_disp_reqs_i       (fpu_rs_disp_reqs),
    .fpu_rs_disp_reqs_valid_i (fpu_rs_disp_req_valid),
    .fpu_rs_disp_reqs_ready_o (fpu_rs_disp_req_ready),
    .fpu_rs_disp_rsp_o        (fpu_rs_disp_rsp),
    .fpu_rs_full_o            (fpu_rs_full),
    .fpu_status_o             (fpu_status),
    .fpu_status_valid_o       (fpu_status_valid),
    // Operand Request /Responses
    .op_reqs_o                (op_reqs),
    .op_rsps_i                (op_rsps_data),
    .op_rsps_valid_i          (op_rsps_valid),
    // To Physical Register File
    .issue_alu_clr_req_valid_o(issue_alu_clr_req_valid),
    .issue_alu_clr_req_o      (issue_alu_clr_req),
    .issue_lsu_clr_req_valid_o(issue_lsu_clr_req_valid),
    .issue_lsu_clr_req_o      (issue_lsu_clr_req),
    .issue_fpu_clr_req_valid_o(issue_fpu_clr_req_valid),
    .issue_fpu_clr_req_o      (issue_fpu_clr_req),
    // ALU WB
    .alu_results_o            (alu_results),
    .alu_results_tag_o        (alu_results_tag),
    .alu_results_valid_o      (alu_results_valid),
    .alu_results_ready_i      (alu_results_ready),
    .branch_result_o          (branch_result),
    // LSU WB
    .lsu_results_o            (lsu_results),
    .lsu_results_tag_o        (lsu_results_tag),
    .lsu_results_valid_o      (lsu_results_valid),
    .lsu_results_ready_i      (lsu_results_ready),
    // FPU WB
    .fpu_results_o            (fpu_results),
    .fpu_results_tag_o        (fpu_results_tag),
    .fpu_results_valid_o      (fpu_results_valid),
    .fpu_results_ready_i      (fpu_results_ready),
    // To ROB
    .alu_rob_z_wb_valid_o(alu_rob_z_wb_valid),
    .alu_rob_z_tag_o(alu_rob_z_tag),
    .lsu_rob_z_wb_valid_o(lsu_rob_z_wb_valid),
    .lsu_rob_z_tag_o(lsu_rob_z_tag),
    .fpu_rob_z_wb_valid_o(fpu_rob_z_wb_valid),
    .fpu_rob_z_tag_o(fpu_rob_z_tag)
  );


  // ----
  // CSR
  // ----
  // Has direct connection to control logic, exceptions are handled directly without the commit guard.
  // I.e., the CSR always checks for exception but the controller masks it out if the current
  //instruction isn't a CSR instruction.

  // Convert dispatch request to issue request for CSR.
  // The valid/ready is fed through so no extra signals.
  assign csr_issue_req = csr_disp_req;

  schnova_csr #(
    .XLEN        (XLEN),
    .DebugSupport(0),
    .RVF         (RVF),
    .RVD         (RVD),
    .Xdma        (Xdma),
    .VMSupport   (0),
    .issue_req_t (csr_issue_req_t),
    .result_tag_t(instr_tag_t),
    .NofAlus     (NofAlus),
    .AluNofRss   (AluNofRss),
    .NofLsus     (NofLsus),
    .LsuNofRss   (LsuNofRss),
    .NofFpus     (NofFpus),
    .FpuNofRss   (FpuNofRss)
  ) i_csr (
    .clk_i                  (clk_i),
    .rst_i                  (rst_i),
    .issue_req_i            (csr_issue_req),
    .issue_req_valid_i      (csr_disp_req_valid),
    .issue_req_ready_o      (csr_disp_req_ready),
    .illegal_csr_instr_o    (csr_exception_raw),
    .result_o               (csr_result),
    .result_tag_o           (csr_result_tag),
    .result_valid_o         (csr_result_valid),
    .result_ready_i         (csr_result_ready),
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
    .frep_lsu_load_en_o     (frep_lsu_load_en),
    .frep_lsu_store_en_o    (frep_lsu_store_en),
    .fpu_status_i           (fpu_status),
    .fpu_status_valid_i     (fpu_status_valid),
    .fpu_rnd_mode_o         (fpu_rnd_mode),
    .fpu_fmt_mode_o         (fpu_fmt_mode),
    .instr_retired_i        (instr_retired)
  );


  // ----------
  // Writeback
  // ----------
  // Convert the accelerator response to a proper result and result tag such that the
  // writeback and scoreboard functions properly.
  logic [XLEN-1:0] acc_result;
  instr_tag_t      acc_result_tag;
  always_comb begin : acc_response_conversion
    acc_result = acc_prsp_i.data;
    acc_result_tag = '0;
    acc_result_tag.dest_reg = acc_prsp_i.id;
    acc_result_tag.dest_reg_is_fp = 1'b0;
  end

  schnova_writeback #(
    .XFREPO         (XFREPO),
    .UseFreeList    (UseFreeList),
    .PipeWidth      (PipeWidth),
    .RobTagWidth    (RobTagWidth),
    .XLEN           (XLEN),
    .FLEN           (FLEN),
    .NofAlus        (NofAlus),
    .NofLsus        (NofLsus),
    .NofFpus        (NofFpus),
    .NrIntWritePorts(NrIntWritePorts),
    .NrFpWritePorts (NrFpWritePorts),
    .NrRobWritePorts(NrRobWritePorts),
    .GprAddrWidth   (GprAddrWidth),
    .FprAddrWidth   (FprAddrWidth),
    .instr_tag_t    (instr_tag_t),
    .alu_result_t   (alu_result_t),
    .fpu_result_t   (fpu_result_t),
    .data_t         (data_t)
  ) i_writeback (
    .en_superscalar_i  (en_superscalar),
    // From / To ALU
    .alu_results_i      (alu_results),
    .alu_results_tag_i  (alu_results_tag),
    .alu_results_valid_i(alu_results_valid),
    .alu_results_ready_o(alu_results_ready),
    // To ROB
    .wb_valid_o(wb_valid),
    .wb_rob_idx_o(wb_rob_idx),
    // From Frontend
    .consecutive_pc_i  (consecutive_pc),
    // From / To CSR
    .csr_result_i      (csr_result),
    .csr_result_tag_i  (csr_result_tag),
    .csr_result_valid_i(csr_result_valid),
    .csr_result_ready_o(csr_result_ready),
    // From / To LSU
    .lsu_results_i      (lsu_results),
    .lsu_results_tag_i  (lsu_results_tag),
    .lsu_results_valid_i(lsu_results_valid),
    .lsu_results_ready_o(lsu_results_ready),
    // From / To FPU
    .fpu_results_i      (fpu_results),
    .fpu_results_tag_i  (fpu_results_tag),
    .fpu_results_valid_i(fpu_results_valid),
    .fpu_results_ready_o(fpu_results_ready),
    // From / To ACC
    .acc_result_i      (acc_result),
    .acc_result_tag_i  (acc_result_tag),
    .acc_result_valid_i(acc_pvalid_i),
    .acc_result_ready_o(acc_pready_o),
    // To Physical Register File
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
    // To Controller
    .ctrl_instr_retired_o(ctrl_instr_retired)
  );


  // ------------
  // Core Events
  // ------------
  // TODO: Make core events superscalar

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
    if (i == 0) begin
      assign all_issue_fpu_handshakes[i] = en_superscalar ? fpu_rs_disp_req_valid[i] & fpu_rs_disp_req_ready[i]
                                                          : fpu_si_disp_req_valid & fpu_si_disp_req_ready;
    end else begin
      assign all_issue_fpu_handshakes[i] = fpu_rs_disp_req_valid[i] & fpu_rs_disp_req_ready[i];
    end
  end
  assign issue_fpu = (|all_issue_fpu_handshakes) & instr_exec_commit;
  // In Snitch this signal captures when an instruction is offloaded to the FP SS. This can include
  // also FP loads as the FP register is in the subsystem. schnova cannot distinguish this case as
  // we handle all instructions in the core. We thus set the same signal.
  assign issue_core_to_fpu = (|all_issue_fpu_handshakes) & instr_exec_commit;

  assign core_events_o.retired_instr = instr_retired_q;
  assign core_events_o.retired_i     = instr_retired_single_cycle_q;
  assign core_events_o.retired_load  = instr_retired_load_q;
  assign core_events_o.retired_acc   = instr_retired_acc_q;
  assign core_events_o.retired_x     = '0;

  assign core_events_o.issue_fpu         = issue_fpu_q;
  assign core_events_o.issue_core_to_fpu = issue_core_to_fpu_q;
  assign core_events_o.issue_fpu_seq     = '0;

  // -----------------------------
  // Physical Register Management
  // -----------------------------
  // 1) Either it is done via a classic approach with a rob and free list
  // 2) Or it is done via a reference counting based approach
  if (XFREPO) begin : gen_phys_reg_manage
    if (UseFreeList) begin : gen_freelist_reg_manage
      // ---------
      // Freelist
      // ---------

      // Local parameters and connections
      localparam int unsigned NumArchRegs = 2**RegAddrSize;

      logic freelist_push;
      logic pop_freelist;
      logic freelist_gpr_ready;
      logic freelist_fpr_ready;

      logic [$clog2(PipeWidth):0] freelist_gpr_push_count;
      logic [$clog2(PipeWidth):0] freelist_fpr_push_count;
      phy_id_t [PipeWidth-1:0]    retired_gpr_regs;
      phy_id_t [PipeWidth-1:0]    retired_fpr_regs;

      // We pop physical registers from the free list
      // once we have sucessfully dispatched  all instructions
      // and are in the super scalar execution mode.
      assign pop_freelist = dispatched & en_superscalar;

      schnova_free_list #(
        .PipeWidth  (PipeWidth),
        .NumPhysRegs(NofPhysGpr),
        .NumArchRegs(NumArchRegs),
        .phy_id_t   (phy_id_t)
      ) i_gpr_free_list (
        .clk_i,
        .rst_i,
        // To / From Controller
        .pop_i            (pop_freelist),
        .freelist_ready_o (freelist_gpr_ready),
        .pop_count_i      (instr_rename_gpr_count),
        // To Rename
        .allocated_regs_o (allocated_gpr_regs),
        // From Reorder Buffer
        .push_i           (freelist_push),
        .push_count_i     (freelist_gpr_push_count),
        .retired_regs_i   (retired_gpr_regs)
      );

      schnova_free_list #(
        .PipeWidth  (PipeWidth),
        .NumPhysRegs(NofPhysFpr),
        .NumArchRegs(NumArchRegs),
        .phy_id_t   (phy_id_t)
      ) i_fpr_free_list (
        .clk_i,
        .rst_i,
        // To / From Controller
        .pop_i            (pop_freelist),
        .freelist_ready_o (freelist_fpr_ready),
        .pop_count_i      (instr_rename_fpr_count),
        // To Rename
        .allocated_regs_o (allocated_fpr_regs),
        // From Reorder Buffer
        .push_i           (freelist_push),
        .push_count_i     (freelist_fpr_push_count),
        .retired_regs_i   (retired_fpr_regs)
      );

      // New instructions can only be dispatched if there are both enough physical gpr and fpr registers
      // for renaming in superscalar execution mode.
      assign phy_reg_alloc_ready = freelist_fpr_ready & freelist_gpr_ready;


      // ---------------
      // Reorder Buffer
      // ---------------

      // Local connections
      logic                          rob_push;
      logic    [$clog2(PipeWidth):0] rob_push_count;
      phy_id_t [PipeWidth-1:0]       phy_reg_rd_old;
      logic    [PipeWidth-1:0]       phy_reg_rd_old_is_fp;

      // Pack the old destination register and whether the target is the fpr or gpr
      always_comb begin : pack_old_phy_reg
        for (int unsigned i = 0; i < PipeWidth; i++) begin
          phy_reg_rd_old[i]       = reg_map[i].phy_reg_rd_old;
          phy_reg_rd_old_is_fp[i] = instr_decoded[i].rd_is_fp;
        end
      end

      // New ROB entries are only allocated in the superscalar mode
      // Allocation happens once for the entire fetch block, at the cycle the first instruction
      // was successfully dispatched.
      assign rob_push = first_instr_dispatched & en_superscalar;
      assign rob_push_count = instr_valid_count;

      schnova_reorder_buffer #(
        .PipeWidth      (PipeWidth),
        .NofEntries     (NofRobEntries),
        .NrRobWritePorts(NrRobWritePorts),
        .NofAlus        (NofAlus),
        .NofLsus        (NofLsus),
        .NofFpus        (NofFpus),
        .phy_id_t       (phy_id_t)
      ) i_rob (
        .clk_i,
        .rst_i,
        // From / To Controller
        .rob_ready_o                (rob_ready),
        .rob_push_count_i           (rob_push_count),
        // From / To Dispatcher
        .rob_push_i                 (rob_push),
        .rob_idx_o                  (rob_idx),
        // From FU Stage
        .alu_rob_z_wb_valid_i       (alu_rob_z_wb_valid),
        .alu_rob_z_tag_i            (alu_rob_z_tag),
        .lsu_rob_z_wb_valid_i       (lsu_rob_z_wb_valid),
        .lsu_rob_z_tag_i            (lsu_rob_z_tag),
        .fpu_rob_z_wb_valid_i       (fpu_rob_z_wb_valid),
        .fpu_rob_z_tag_i            (fpu_rob_z_tag),
        // From Rename
        .rob_phy_reg_rd_old_i       (phy_reg_rd_old),
        .rob_phy_reg_rd_old_is_fp_i (phy_reg_rd_old_is_fp),
        // From Writeback
        .wb_valid_i                 (wb_valid),
        .wb_rob_idx_i               (wb_rob_idx),
        // To Freelist
        .freelist_push_o            (freelist_push),
        .gpr_push_count_o           (freelist_gpr_push_count),
        .gpr_retired_regs_o         (retired_gpr_regs),
        .fpr_push_count_o           (freelist_fpr_push_count),
        .fpr_retired_regs_o         (retired_fpr_regs)
      );
    end else begin : gen_refcount_reg_manage
      // -------------------
      // Reference Counting
      // -------------------

      // Local connections
      phy_id_t [PipeWidth-1:0] phy_reg_rd;
      phy_id_t [PipeWidth-1:0] phy_reg_rd_old;
      logic    [PipeWidth-1:0] is_rd_fp;
      logic                    instr_exec_commit_superscalar;

      always_comb begin : pack_reg_rd_old
        for (int unsigned i = 0; i < PipeWidth; i++) begin
          phy_reg_rd[i]     = en_superscalar ? reg_map[i].phy_reg_rd_new : reg_map[i].phy_reg_rd_old;
          phy_reg_rd_old[i] = reg_map[i].phy_reg_rd_old;
          is_rd_fp[i]       = instr_decoded[i].rd_is_fp;
        end
      end

      // There is no reorder buffer so we set is as always ready
      assign rob_ready = 1'b1;
      assign rob_idx = '0; // Not used

      // We only perform reference counting in superscalar execution mode
      assign instr_exec_commit_superscalar = en_superscalar ? instr_exec_commit: 1'b0;

      schnova_refcount #(
        .PipeWidth    (PipeWidth),
        .NofPhysGpr   (NofPhysGpr),
        .NofPhysFpr   (NofPhysFpr),
        .NofAlus      (NofAlus),
        .AluNofRss    (AluNofRss),
        .NofLsus      (NofLsus),
        .LsuNofRss    (LsuNofRss),
        .NofFpus      (NofFpus),
        .FpuNofRss    (FpuNofRss),
        .phy_id_t     (phy_id_t),
        .refcnt_req_t (refcnt_req_t)
      ) i_refcount (
        .clk_i,
        .rst_i,
        // From / To Controller
        .instr_exec_commit_superscalar_i(instr_exec_commit_superscalar),
        .instr_valid_i                  (instr_valid_masked),
        .dispatched_i                   (dispatched),
        .rename_gpr_count_i             (instr_rename_gpr_count),
        .rename_fpr_count_i             (instr_rename_fpr_count),
        .phy_reg_alloc_ready_o          (phy_reg_alloc_ready),
        // From / To Dispatcher
        .refcnt_disp_req_i              (refcnt_disp_req),
        // From / To Rename
        .phy_reg_rd_i                   (phy_reg_rd),
        .phy_reg_rd_old_i               (phy_reg_rd_old),
        .is_rd_fp_i                     (is_rd_fp),
        .allocated_gpr_regs_o           (allocated_gpr_regs),
        .allocated_fpr_regs_o           (allocated_fpr_regs),
        // From FU Stage (Reservation Stations)
        .issue_alu_clr_req_valid_i      (issue_alu_clr_req_valid),
        .issue_alu_clr_req_i            (issue_alu_clr_req),
        .issue_lsu_clr_req_valid_i      (issue_lsu_clr_req_valid),
        .issue_lsu_clr_req_i            (issue_lsu_clr_req),
        .issue_fpu_clr_req_valid_i      (issue_fpu_clr_req_valid),
        .issue_fpu_clr_req_i            (issue_fpu_clr_req),
        // From Scoreboard
        .sbi_q_i(sbi_q),
        .sbf_q_i(sbf_q)
      );
    end
  end else begin : gen_no_phys_reg_manage
    // Make sure the core stalls if configured wrongly
    // (If it jumps to superscalar execution when no
    // physical register management is implemented)
    assign phy_reg_alloc_ready = 1'b0;
    assign rob_ready           = 1'b0;
    assign rob_idx             = '0; // Not used
  end


  // -----------
  // Scoreboard
  // -----------

  // Local connections
  logic update_sb;
  sb_disp_data_t [PipeWidth-1:0] disp_data;

  // In superscalar mode, we update the scoreboard at the same cycle the first instruction
  // was successfully dispatched (similarily to how the rob is handled)
  // in scalar mode we update once all instructions are dispatched (which is only one in that case)
  assign update_sb = en_superscalar ? first_instr_dispatched : dispatched;

  always_comb begin : pack_disp_data
    // Forward the new destination mappings to the rename stage
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      // In scalar mode we don't perform renaming, so we use the old value stored in the rmt
      disp_data[i].rd             = en_superscalar  ? reg_map[i].phy_reg_rd_new
                                                    : reg_map[i].phy_reg_rd_old;
      disp_data[i].rd_is_fp       = instr_decoded[i].rd_is_fp;
      disp_data[i].rs1            = reg_map[i].phy_reg_rs1;
      disp_data[i].rs1_is_fp      = instr_decoded[i].rs1_is_fp;
      disp_data[i].rs2            = reg_map[i].phy_reg_rs2;
      disp_data[i].rs2_is_fp      = instr_decoded[i].rs2_is_fp;
      disp_data[i].rs3            = reg_map[i].phy_reg_rs3;
      disp_data[i].use_imm_as_rs3 = instr_decoded[i].use_imm_as_rs3;
    end
  end

  schnova_scoreboard #(
    .XFREPO         (XFREPO),
    .PipeWidth      (PipeWidth),
    .NrReadPorts    (NofOperandIfs),
    .NrIntWritePorts(NrIntWritePorts),
    .NrFpWritePorts (NrFpWritePorts),
    .PhysAddrWidth  (PhysRegAddrSize),
    .GprAddrWidth   (GprAddrWidth),
    .FprAddrWidth   (FprAddrWidth),
    .NofPhysGpr     (NofPhysGpr),
    .NofPhysFpr     (NofPhysFpr),
    .sb_disp_data_t (sb_disp_data_t)
  ) i_scoreboard (
    .clk_i,
    .rst_i,
    // From / To Controller
    .en_superscalar_i (en_superscalar),
    .dispatched_i     (update_sb),
    .instr_valid_i    (instr_valid_masked),
    .registers_ready_o(registers_ready),
    .sb_busy_o        (sb_busy),
    // From Dispatcher
    .disp_data_i      (disp_data),
    // From Physical Register File
    .raddr_i          (sb_raddr),
    .read_fp_i        (sb_read_fp),
    .rdata_o          (sb_rdata),
    // Frome Writeback
    .wb_gpr_addr_i    (gpr_waddr),
    .wb_gpr_en_i      (gpr_we),
    .wb_fpr_addr_i    (fpr_waddr),
    .wb_fpr_en_i      (fpr_we),
    // To Reference Count
    .sbi_q_o(sbi_q),
    .sbf_q_o(sbf_q)
);


  // ------------------------
  // Physical Register Files
  // ------------------------
  schnova_phys_regfile #(
    .XFREPO             (XFREPO),
    .DataWidth          (XLEN),
    .OpLen              (OpLen),
    .NofAlus            (NofAlus),
    .NofLsus            (NofLsus),
    .NofFpus            (NofFpus),
    .NrReadPorts        (NrIntReadPorts),
    .NrOperandReadPorts (NofOperandGprReadPorts),
    .NofOperandIfs      (NofOperandIfs),
    .NrWritePorts       (NrIntWritePorts),
    .IsGpr              (1),
    .PhysAddrWidth      (PhysRegAddrSize),
    .AddrWidth          (GprAddrWidth),
    .NumRegs            (NofPhysGpr),
    .operand_req_t      (operand_req_t)
  ) i_int_phy_regfile (
    .clk_i,
    .rst_ni         (~rst_i),
    // From / To Read operands
    .raddr_i        (gpr_raddr),
    .rdata_o        (gpr_rdata),
    // From Writeback
    .waddr_i        (gpr_waddr),
    .wdata_i        (gpr_wdata),
    .we_i           (gpr_we),
    // From / To FU Stage (Reservation Stations)
    .op_reqs_i      (op_reqs),
    .op_rsps_data_o (op_rsps_gpr_data)
  );

  if (NofFpus > 0) begin : gen_fp_rf
    schnova_phys_regfile #(
      .XFREPO             (XFREPO),
      .DataWidth          (FLEN),
      .OpLen              (OpLen),
      .NofAlus            (NofAlus),
      .NofLsus            (NofLsus),
      .NofFpus            (NofFpus),
      .NrReadPorts        (NrFpReadPorts),
      .NrOperandReadPorts (NofOperandFprReadPorts),
      .NofOperandIfs      (NofOperandIfs),
      .NrWritePorts       (NrFpWritePorts),
      .IsGpr              (0),
      .PhysAddrWidth      (PhysRegAddrSize),
      .AddrWidth          (FprAddrWidth),
      .NumRegs            (NofPhysFpr),
      .operand_req_t      (operand_req_t)
    ) i_fp_phy_regfile (
      .clk_i,
      .rst_ni         (~rst_i),
      // From / To Read operands
      .raddr_i        (fpr_raddr),
      .rdata_o        (fpr_rdata),
      // From Writeback
      .waddr_i        (fpr_waddr),
      .wdata_i        (fpr_wdata),
      .we_i           (fpr_we),
      // From / To FU Stage (Reservation Stations)
      .op_reqs_i      (op_reqs),
      .op_rsps_data_o (op_rsps_fpr_data)
    );
  end else begin : gen_no_fp_rf
    assign fpr_rdata = '0;
    assign op_rsps_fpr_data = '0;
  end

  if (XFREPO) begin : gen_op_handling
    // For every operand request we snoop the scoreboard to know
    // whether the requested physical register is valid or not
    always_comb begin : sb_operand_req_snooping
      for (int unsigned op = 0; op < NofOperandIfs; op++) begin
        sb_raddr[op]      =  op_reqs[op].phy_reg;
        sb_read_fp[op]    = op_reqs[op].is_fp;
        op_rsps_valid[op] = ~sb_rdata[op];
      end
    end

    always_comb begin : op_rsps_mux
      for (int unsigned op = 0; op < NofOperandIfs; op++) begin
        // Depending on whether the request targets the GPR or the FPR we select the response data
        op_rsps_data[op] = op_reqs[op].is_fp ? op_rsps_fpr_data[op] : op_rsps_gpr_data[op];
      end
    end

  end else begin : gen_no_op_handling
    assign sb_raddr      = '0;
    assign sb_read_fp    = '0;
    assign op_rsps_valid = '0;
    assign op_rsps_data  = '0;
  end

  ////////////
  // Tracer //
  ////////////

  // pragma translate_off

  // Core and dispatch traces
  core_trace_t     core_trace;
  dispatch_trace_t rs_dispatch_trace[PipeWidth];
  dispatch_trace_t si_dispatch_trace;

  disp_req_trace_t alu_disp_req_trace[NofAlus];
  disp_req_trace_t lsu_disp_req_trace[NofLsus];
  disp_req_trace_t fpu_disp_req_trace[NofFpus];

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
  wb_fu_trace_t alu_wb_trace [NofAlus];
  wb_fu_trace_t lsu_wb_trace [NofLsus];
  wb_fu_trace_t fpu_wb_trace [NofFpus];
  wb_fu_trace_t csr_wb_trace;
  wb_fu_trace_t acc_wb_trace;

  if (XFREPO) begin : gen_superscalar_core_trace
    assign core_trace = '{
      priv_level:     priv_lvl,
      loop_state:     loop_state,
      // Whether the fetching was stalled
      stall:          stall,
      // Whether the dispatcher was stalled
      stall_dispatch: !(|i_dispatcher.gen_rs_dispatcher.i_rs_dispatcher.instr_dispatched),
      exception:      exception
    };
  end else begin: gen_scalar_core_trace
    assign core_trace = '{
      priv_level:     priv_lvl,
      loop_state:     loop_state,
      // Whether the fetching was stalled
      stall:          stall,
      // Whether the dispatcher was stalled
      stall_dispatch: !i_dispatcher.dispatched,
      exception:      exception
    };
  end

  assign si_dispatch_trace =  '{
      valid:        (instr_exec_commit && instr_valid_masked[0] && i_dispatcher.i_si_dispatcher.fu_ready) || exception,
      pc_q:         i_frontend.pc_q,
      pc_d:         i_frontend.pc_d,
      instr_data:   instr_fetch_data[0],
      rs1:          instr_decoded[0].rs1,
      phy_rs1:      reg_map[0].phy_reg_rs1,
      rs2:          instr_decoded[0].rs2,
      phy_rs2:      reg_map[0].phy_reg_rs2,
      rs3:          instr_decoded[0].imm, // fused FPU instructions use imm as operand
      phy_rs3:      reg_map[0].phy_reg_rs3,
      rd:           instr_decoded[0].rd,
      phy_rd:       reg_map[0].phy_reg_rd_old,
      rs1_is_fp:    instr_decoded[0].rs1_is_fp,
      rs2_is_fp:    instr_decoded[0].rs2_is_fp,
      rd_is_fp:     instr_decoded[0].rd_is_fp,
      fu_type:      schnova_pkg::fu_to_string(instr_decoded[0].fu),
      disp_resp:    i_fu_stage.producer_to_string(i_dispatcher.i_si_dispatcher.tag.producer_id)
    };

  for (genvar idx = 0; idx < PipeWidth; idx++) begin : gen_rs_dispatch_traces
    // verilog_lint: waive-start line-length
    if (XFREPO) begin : gen_rs_dispatch_trace
      assign rs_dispatch_trace[idx] = '{
        valid:        (instr_exec_commit && instr_valid_masked[idx] && !i_dispatcher.gen_rs_dispatcher.i_rs_dispatcher.instr_has_hazard[idx] && !i_dispatcher.gen_rs_dispatcher.i_rs_dispatcher.dispatched_q[idx]) || exception,
        pc_q:         i_frontend.pc_q + (idx * 4),
        pc_d:         i_frontend.pc_d,
        instr_data:   instr_fetch_data[idx],
        rs1:          instr_decoded[idx].rs1,
        phy_rs1:      reg_map[idx].phy_reg_rs1,
        rs2:          instr_decoded[idx].rs2,
        phy_rs2:      reg_map[idx].phy_reg_rs2,
        rs3:          instr_decoded[idx].imm, // fused FPU instructions use imm as operand
        phy_rs3:      reg_map[idx].phy_reg_rs3,
        rd:           instr_decoded[idx].rd,
        phy_rd:       en_superscalar ? reg_map[idx].phy_reg_rd_new : reg_map[idx].phy_reg_rd_old,
        rs1_is_fp:    instr_decoded[idx].rs1_is_fp,
        rs2_is_fp:    instr_decoded[idx].rs2_is_fp,
        rd_is_fp:     instr_decoded[idx].rd_is_fp,
        fu_type:      schnova_pkg::fu_to_string(instr_decoded[idx].fu),
        disp_resp:    "" // Not used in superscalar dispatch
      };
    end else begin : gen_no_rs_dispatch_trace
      assign rs_dispatch_trace[idx] = '{default: '0};
    end
  end



  for (genvar alu = 0; alu < NofAlus; alu++) begin : gen_alu_traces

    assign alu_disp_req_trace[alu] = '{
      valid: alu_rs_disp_req_valid[alu] && alu_rs_disp_req_ready[alu],
      rs_id: alu,
      disp_resp:  i_fu_stage.producer_to_string(alu_rs_disp_rsp[alu].producer),
      phy_rd:   alu_rs_disp_reqs[alu].tag.dest_reg,
      rd_is_fp: alu_rs_disp_reqs[alu].tag.dest_reg_is_fp
    };

    for (genvar rss = 0; rss < AluNofRss; rss++) begin : gen_alu_traces_rss
      // verilog_lint: waive-start line-length
      if (XFREPO) begin : gen_alu_traces_rss_trace
        assign rss_alu_traces[alu][rss] = '{
          valid:          i_fu_stage.gen_alus[alu].alu_rs_issue_req_valid &&
                          i_fu_stage.gen_alus[alu].alu_rs_issue_req_ready &&
                          (i_fu_stage.gen_alus[alu].alu_rs_issue_req.tag.producer_id.slot_id == rss),
          producer:       i_fu_stage.producer_to_string(
                            i_fu_stage.gen_alus[alu].alu_rs_issue_req.tag.producer_id),
          alu_opa:        i_fu_stage.gen_alus[alu].alu_rs_issue_req.operand_a[XLEN-1:0],
          alu_opb:        i_fu_stage.gen_alus[alu].alu_rs_issue_req.operand_b[XLEN-1:0]
        };
      end else begin : gen_alu_traces_rss_no_trace_resreq
        assign rss_alu_traces[alu][rss]    = '{default: '0};
      end
      // verilog_lint: waive-stop line-length
    end
  end

  for (genvar lsu = 0; lsu < NofLsus; lsu++) begin : gen_lsu_traces

    assign lsu_disp_req_trace[lsu] = '{
      valid: lsu_rs_disp_req_valid[lsu] && lsu_rs_disp_req_ready[lsu],
      rs_id: NofAlus + lsu,
      disp_resp:  i_fu_stage.producer_to_string(lsu_rs_disp_rsp[lsu].producer),
      phy_rd:  lsu_rs_disp_reqs[lsu].tag.dest_reg,
      rd_is_fp: lsu_rs_disp_reqs[lsu].tag.dest_reg_is_fp
    };

    for (genvar rss = 0; rss < LsuNofRss; rss++) begin : gen_lsu_traces_rss
      // verilog_lint: waive-start line-length
      if (XFREPO) begin : gen_lsu_traces_rss_trace
        assign rss_lsu_traces[lsu][rss] = '{
          valid:          i_fu_stage.gen_lsus[lsu].lsu_rs_issue_req_valid &&
                          i_fu_stage.gen_lsus[lsu].lsu_rs_issue_req_ready &&
                          (i_fu_stage.gen_lsus[lsu].lsu_rs_issue_req.tag.producer_id.slot_id == rss),
          producer:       i_fu_stage.producer_to_string(
                            i_fu_stage.gen_lsus[lsu].lsu_rs_issue_req.tag.producer_id),
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
      end else begin : gen_lsu_traces_rss_no_trace_resreq
        assign rss_lsu_traces[lsu][rss]    = '{default: '0};
      end
      // verilog_lint: waive-stop line-length
    end
  end

  for (genvar fpu = 0; fpu < NofFpus; fpu++) begin : gen_fpu_traces

    assign fpu_disp_req_trace[fpu] = '{
      valid: fpu_rs_disp_req_valid[fpu] && fpu_rs_disp_req_ready[fpu],
      rs_id: NofAlus + NofLsus + fpu,
      disp_resp:  i_fu_stage.producer_to_string(fpu_rs_disp_rsp[fpu].producer),
      phy_rd:   fpu_rs_disp_reqs[fpu].tag.dest_reg,
      rd_is_fp: fpu_rs_disp_reqs[fpu].tag.dest_reg_is_fp
    };

    for (genvar rss = 0; rss < FpuNofRss; rss++) begin : gen_fpu_traces_rss
      // verilog_lint: waive-start line-length
      if (XFREPO) begin : gen_fpu_traces_rss_trace
        assign rss_fpu_traces[fpu][rss] = '{
          valid:      i_fu_stage.gen_fpus[fpu].fpu_rs_issue_req_valid &&
                      i_fu_stage.gen_fpus[fpu].fpu_rs_issue_req_ready &&
                      (i_fu_stage.gen_fpus[fpu].fpu_rs_issue_req.tag.producer_id.slot_id == rss),
          producer:    i_fu_stage.producer_to_string(
                        i_fu_stage.gen_fpus[fpu].fpu_rs_issue_req.tag.producer_id),
          fpu_opa:     i_fu_stage.gen_fpus[fpu].fpu_rs_issue_req.operand_a,
          fpu_opb:     i_fu_stage.gen_fpus[fpu].fpu_rs_issue_req.operand_b,
          fpu_opc:     i_fu_stage.gen_fpus[fpu].fpu_rs_issue_req.imm,
          fpu_src_fmt: i_fu_stage.gen_fpus[fpu].fpu_rs_issue_req.fpu_fmt_src,
          fpu_dst_fmt: i_fu_stage.gen_fpus[fpu].fpu_rs_issue_req.fpu_fmt_dst,
          // Directly access the FPU because theses signals are decoded in the FPU. This requires
          // that there is no cut between the RSS and the FPU.
          fpu_int_fmt:    i_fu_stage.gen_fpus[fpu].i_fpu.int_fmt
        };
      end else begin : gen_fpu_traces_no_rss
        assign rss_fpu_traces[fpu][rss]    = '{default: '0};
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
    // We can have instructions that don't lead to a response. For those we use the issue handshake as a retirement signal.
    valid:    acc_pvalid_i && acc_pready_o || (acc_qvalid_o && acc_qready_i && (acc_qreq_o.id == '0)), 
    producer: "ACC" // There is no address on the response.
  };

  // Writebacks
  for (genvar alu = 0; alu < NofAlus; alu++) begin: gen_alu_wb_traces
    assign alu_wb_trace[alu] = '{
      valid:        alu_results_valid[alu] && alu_results_ready[alu],
      fu_result:    alu_results[alu].result,
      fu_phy_rd:    alu_results_tag[alu].dest_reg,
      fu_rd_is_fp:  alu_results_tag[alu].dest_reg_is_fp,
      is_branch:    alu_results_tag[alu].is_branch,
      branch_taken: alu_results[alu].compare_res
    };
  end

  for (genvar lsu = 0; lsu < NofLsus; lsu++) begin: gen_lsu_wb_traces
    assign lsu_wb_trace[lsu] = '{
      valid:       lsu_results_valid[lsu] && lsu_results_ready[lsu],
      fu_result:   lsu_results[lsu],
      fu_phy_rd:       lsu_results_tag[lsu].dest_reg,
      fu_rd_is_fp: lsu_results_tag[lsu].dest_reg_is_fp,
      is_branch:    1'b0,
      branch_taken: 1'b0
    };
  end

  for (genvar fpu = 0; fpu < NofFpus; fpu++) begin: gen_fpu_wb_traces
    assign fpu_wb_trace[fpu] = '{
      valid:       fpu_results_valid[fpu] && fpu_results_ready[fpu],
      fu_result:   fpu_results[fpu],
      fu_phy_rd:       fpu_results_tag[fpu].dest_reg,
      fu_rd_is_fp: fpu_results_tag[fpu].dest_reg_is_fp,
      is_branch:    1'b0,
      branch_taken: 1'b0
    };
  end

  assign csr_wb_trace = '{
    valid:       csr_result_valid && csr_result_ready,
    fu_result:   csr_result,
    fu_phy_rd:   csr_result_tag.dest_reg,
    fu_rd_is_fp: csr_result_tag.dest_reg_is_fp,
    is_branch:    1'b0,
    branch_taken: 1'b0
  };

  assign acc_wb_trace  = '{
    valid:       acc_pvalid_i && acc_pready_o,
    fu_result:   acc_result,
    fu_phy_rd:   acc_result_tag.dest_reg,
    fu_rd_is_fp: acc_result_tag.dest_reg_is_fp,
    is_branch:    1'b0,
    branch_taken: 1'b0
  };

  schnova_tracer #(
    .UseFreeList  (UseFreeList),
    .PipeWidth    (PipeWidth),
    .NofAlus      (NofAlus),
    .NofLsus      (NofLsus),
    .NofFpus      (NofFpus),
    .AluNofRss    (AluNofRss),
    .LsuNofRss    (LsuNofRss),
    .FpuNofRss    (FpuNofRss),
    .NofOperandIfs(NofOperandIfs),
    .NofPhysGpr   (NofPhysGpr),
    .NofPhysFpr   (NofPhysFpr),
    .XFREPO       (XFREPO)
  ) i_tracer (
    .clk_i                (clk_i),
    .rst_i                (rst_i),
    .hart_id_i            (hart_id_i),
    .core_trace           (core_trace),
    .si_dispatch_trace    (si_dispatch_trace),
    .rs_dispatch_trace    (rs_dispatch_trace),
    .alu_disp_req_trace   (alu_disp_req_trace),
    .lsu_disp_req_trace   (lsu_disp_req_trace),
    .fpu_disp_req_trace   (fpu_disp_req_trace),
    .alu_trace            (alu_trace),
    .lsu_trace            (lsu_trace),
    .fpu_trace            (fpu_trace),
    .rss_alu_traces       (rss_alu_traces),
    .rss_lsu_traces       (rss_lsu_traces),
    .rss_fpu_traces       (rss_fpu_traces),
    .csr_trace            (csr_trace),
    .acc_trace            (acc_trace),
    .alu_retirements      (alu_retirements),
    .lsu_load_retirements (lsu_load_retirements),
    .lsu_store_retirements(lsu_store_retirements),
    .fpu_retirements      (fpu_retirements),
    .csr_retirement       (csr_retirement),
    .acc_retirement       (acc_retirement),
    .alu_wb_trace         (alu_wb_trace),
    .lsu_wb_trace         (lsu_wb_trace),
    .fpu_wb_trace         (fpu_wb_trace),
    .csr_wb_trace         (csr_wb_trace),
    .acc_wb_trace         (acc_wb_trace)
  );

  // pragma translate_on

  // Assertions
  `ASSERT_INIT(NofAluMismatch, XFREPO || (NofAlus == 1),
    "Too many ALUs, if XFREPO is not enabled only 1 ALU will be used anyways");

  `ASSERT_INIT(NofLsuMismatch, XFREPO || (NofLsus == 1),
    "Too many LSUs, if XFREPO is not enabled only 1 LSU will be used anyways");

  `ASSERT_INIT(NofFpuMismatch, XFREPO || (NofFpus == 1),
    "Too many FPUs, if XFREPO is not enabled only 1 FPU will be used anyways");

  `ASSERT_INIT(NofGprMismatch, XFREPO || (NofPhysGpr == 32),
    "If XFREPO is not enabled, the core only supports 32 gp logical registers");

  `ASSERT_INIT(NofFprMismatch, XFREPO || (NofPhysFpr == 32),
    "If Xfrep is not enabled, the core only supports 32 fp logical registers");

endmodule
