// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Schnizo core-wide constants and types.
package schnizo_pkg;
  //---------------------------
  // Core global constants
  //---------------------------
  localparam int unsigned RegAddrSize = 5;

  //---------------------------
  // Types & Enums
  //---------------------------
  // All functional units
  typedef enum logic [3:0] {
    NONE,
    LOAD,
    STORE,
    ALU,
    MUL,
    CTRL_FLOW,
    MULDIV, // shared muldiv unit from hive
    CSR,
    FPU,
    DMA,
    SPATZ
  } fu_t;

  // Accelerators available in the Schnizo Cluster / Hive.
  // This enum can currently not be used as we still use the snitch_cluster and hive.
  // Keep parameter in sync!
  localparam int unsigned NumAccelerators = 2;
  // typedef enum logic [31:0] {
  //   SHARED_MULDIV = 0,
  //   DMA_SS = 1
  // } acc_addr_e;

  // Maybe it would be simpler if we only have one big enum for all instructions
  // as having a separate enum for each FU.

  // ALU Operations
  typedef enum logic [4:0] {
    // Arithmetic
    AluOpAdd,
    AluOpSub,
    AluOpMul,
    AluOpMulh,
    AluOpMulhu,
    AluOpMulhsu,
    // Logical
    AluOpXor,
    AluOpOr,
    AluOpAnd,
    // Set less than
    AluOpSlt,
    AluOpSltu,
    // Shifting
    AluOpSll,
    AluOpSrl,
    AluOpSra,
    // Branch
    AluOpEq,
    AluOpNeq,
    AluOpLt,
    AluOpLtu,
    AluOpGe,
    AluOpGeu
  } alu_op_e;

  // LSU Operations
  typedef enum logic [3:0] {
    LsuOpStore,
    LsuOpLoad,
    LsuOpLoadUnsigned,
    // Floating point
    LsuOpFpStore,
    LsuOpFpLoad,
    // Atomic
    LsuOpAmoLr,
    LsuOpAmoSc,
    LsuOpAmoSwap,
    LsuOpAmoAdd,
    LsuOpAmoXor,
    LsuOpAmoAnd,
    LsuOpAmoOr,
    LsuOpAmoMin,
    LsuOpAmoMax,
    LsuOpAmoMinU,
    LsuOpAmoMaxU
  } lsu_op_e;

  // Value size of load/store operations
  typedef enum logic [1:0] {
    Byte = 2'b00,
    HalfWord = 2'b01,
    Word = 2'b10,
    Double = 2'b11
  } lsu_size_e;

  typedef enum logic [2:0] {
    CsrOpNone, // for non CSR SYSTEM instructions. (ECALL, EBREAK, WFI, MRET, SRET)
    CsrOpWrite,
    CsrOpSwap,
    CsrOpRead,
    CsrOpSet,
    CsrOpClear
  } csr_op_e;

  typedef enum logic [4:0] {
    FpuOpFadd,
    FpuOpFsub,
    FpuOpFmadd,
    FpuOpFmsub,
    FpuOpFnmsub,
    FpuOpFnmadd,
    FpuOpFmul,
    FpuOpFdiv,
    FpuOpFsqrt,
    FpuOpFsgnj,
    FpuOpFsgnjSignExt,
    FpuOpFminmax,
    FpuOpF2I,
    FpuOpF2Iunsigned,
    FpuOpI2F,
    FpuOpI2Funsigned,
    FpuOpF2F,
    FpuOpFcmp,
    FpuOpFclassify
  } fpu_op_e;

  /// Async interrupts of the core.
  typedef struct packed {
    /// Debug request
    logic debug;
    /// Machine external interrupt pending
    logic meip;
    /// Machine external timer interrupt pending
    logic mtip;
    /// Machine external software interrupt pending
    logic msip;
    /// Machine cluster-local interrupt pending
    logic mcip;
    /// Machine external accelerator interrupt pending
    logic mxip;
  } interrupts_t;

  typedef struct packed {
    logic [RegAddrSize-1:0] dest_reg;
    logic                   dest_reg_is_fp;
    logic                   is_branch;
    logic                   is_jump;
  } instr_tag_t;

  // ---------------------------
  // Privilege Spec
  // ---------------------------
  // RISCV privilege levels
  typedef enum logic [1:0] {
    PrivLvlM = 2'b11,
    PrivLvlS = 2'b01,
    PrivLvlU = 2'b00
  } priv_lvl_t;

  // ---------------------------
  // FREP CSR
  // ---------------------------
  // TODO(colluca): double check these
  localparam logic [11:0] CsrFrepState = 12'h7c3;  // replaces Snitch's CSR_SC
  localparam logic [11:0] CsrFrepConfig = 12'h7c6;  // replaces Snitch's CSR_COPIFT

  // ---------------------------
  // Remains from Snitch for unused inputs
  // ---------------------------
  // Virtual Memory
  localparam int unsigned PageShift = 12;
  /// Size in bits of the virtual address segments
  localparam int unsigned VpnSize = 10;

  /// Virtual Address Definition
  typedef struct packed {
    /// Virtual Page Number 1
    logic [31:32-VpnSize] vpn1;
    /// Virtual Page Number 0
    logic [PageShift+VpnSize-1:PageShift] vpn0;
  } va_t;

  // ---------------------------
  // FREP control
  // ---------------------------
  // FREP execution mode selection
  typedef enum logic {
    FrepModeHwLoop      = 1'b0,  // Use hardware loop mode only
    FrepModeSuperscalar = 1'b1   // Allow superscalar (LCP/LEP) mode
  } frep_mode_e;

  // The Bodysize and max iterations depend on the instruction encoding.
  localparam int unsigned FrepBodySizeWidth = 12;
  localparam int unsigned FrepMaxItersWidth = 32+1; // +1 bit to convert Snitch FREP iters

  typedef enum logic [2:0] {
    LoopRegular, // regular execution
    LoopHwLoop,  // regular hw loop execution
    LoopLcp1,    // loop construction phase 1
    LoopLcp2,    // loop construction phase 2
    LoopLep      // loop execution phase
  } loop_state_e;

  // Memory consistency mode during FREP loop. See CSR for more details.
  typedef enum logic [2:0] {
    FrepMemNoConsistency      = 3'b000,
    FrepMemSerialized         = 3'b001
    // FrepMemSeparateStreams = 3'b010
  } frep_mem_cons_mode_e;

  // ---------------------------
  // Tracer
  // ---------------------------
  // pragma translate_off
  function automatic string priv_lvl_tostring(priv_lvl_t priv_lvl);
    string level;
    unique case (priv_lvl)
      PrivLvlM: level = "M"; // ensure all strings have the same length
      PrivLvlS: level = "S";
      PrivLvlU: level = "U";
      default:  level = "?";
    endcase
    return level;
  endfunction

  function automatic string loop_state_tostring(loop_state_e loop_state);
    string state;
    unique case (loop_state)
      LoopRegular: state = "REG";
      LoopHwLoop:  state = "HWL";
      LoopLcp1:    state = "LCP1";
      LoopLcp2:    state = "LCP2";
      LoopLep:     state = "LEP";
      default:     state = "???";
    endcase
    return state;
  endfunction

  function automatic string fu_to_string(fu_t fu);
    string name;
    unique case (fu)
      schnizo_pkg::NONE:      name = "NONE";
      schnizo_pkg::LOAD,
      schnizo_pkg::STORE:     name = "LSU";
      schnizo_pkg::ALU,
      schnizo_pkg::MUL,
      schnizo_pkg::CTRL_FLOW: name = "ALU";
      schnizo_pkg::CSR:       name = "CSR";
      schnizo_pkg::FPU:       name = "FPU";
      schnizo_pkg::MULDIV:    name = "MULDIV"; // shared muldiv unit from hive
      schnizo_pkg::DMA:       name = "DMA";
      schnizo_pkg::SPATZ:     name = "SPATZ";
      default:                name = "???";
    endcase
    return name;
  endfunction
  // pragma translate_on
endpackage
