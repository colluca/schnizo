// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

/// # Schnizo core-wide constants and types.
/// Fixed constants for a Schnizo core.
// Author: Pascal Etterli <petterli@student.ethz.ch>

package schnizo_pkg;
  //---------------------------
  // Core global constants
  //---------------------------
  parameter int unsigned REG_ADDR_SIZE = 5;

  //---------------------------
  // Types & Enums
  //---------------------------
  // All functional units
  typedef enum logic [3:0] {
    NONE,
    LOAD,
    STORE,
    ALU,
    CTRL_FLOW,
    MULT,
    CSR,
    FPU,
    ACCEL
  } fu_t;

  // Maybe it would be simpler if we only have one big enum for all instructions
  // as having a separate enum for each FU.

  // ALU Operations
  typedef enum logic [3:0] {
    // arithmetic
    AluOpAdd,
    AluOpSub,
    // logical
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
    LsuOpStoreByte,
    LsuOpStoreHalf,
    LsuOpStoreWord,
    LsuOpLoadByte,
    LsuOpLoadByteUnsigned,
    LsuOpLoadHalf,
    LsuOpLoadHalfUnsigned,
    LsuOpLoadWord,
    // Floating Point
    LsuOpFpStoreByte,
    LsuOpFpStoreHalf,
    LsuOpFpStoreWord,
    LsuOpFpStoreDouble,
    LsuOpFpLoadByte,
    LsuOpFpLoadHalf,
    LsuOpFpLoadWord,
    LsuOpFpLoadDouble
  } lsu_op_e;

  typedef enum logic [2:0] {
    CsrOpNone, // for non CSR SYSTEM instructions. (ECALL, EBREAK, WFI, MRET, SRET)
    CsrOpWrite,
    CsrOpSwap,
    CsrOpRead,
    CsrOpSet,
    CsrOpClear
  } csr_op_e;

  // Value size of load/store operations
  typedef enum logic [1:0] {
    Byte = 2'b00,
    HalfWord = 2'b01,
    Word = 2'b10,
    Double = 2'b11
  } ls_size_e;

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
  } interrupts_t;

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
endpackage
