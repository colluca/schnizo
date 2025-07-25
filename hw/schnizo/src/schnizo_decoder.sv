// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: The decoder for the Schnizo Core. Based on CVA6.

`include "../../snitch/src/snitch_pkg.sv"
`include "../../snitch/src/riscv_instr.sv"

module schnizo_decoder import schnizo_pkg::*; import snitch_pkg::*; import riscv_instr::*; #(
  parameter int unsigned XLEN        = 32,
  parameter bit          Xdma        = 0,
  /// Enable F Extension (single).
  parameter bit          RVF         = 1,
  /// Enable D Extension (double).
  parameter bit          RVD         = 0,
  parameter bit          XF16        = 0,
  parameter bit          XF16ALT     = 0,
  parameter bit          XF8         = 0,
  parameter bit          XF8ALT      = 0,
  parameter type         instr_dec_t = logic
) (
  // For assertions only.
  input logic         clk_i,
  input logic         rst_i,

  input  logic [31:0] instr_fetch_data_i,
  input  logic        instr_fetch_data_valid_i,
  output logic        instr_valid_o,
  output logic        instr_illegal_o,
  output instr_dec_t  instr_dec_o
);
  // --------------------
  // Instruction Types
  // --------------------
  typedef struct packed {
    logic [31:25] funct7;
    logic [24:20] rs2;
    logic [19:15] rs1;
    logic [14:12] funct3;
    logic [11:7]  rd;
    logic [6:0]   opcode;
  } rtype_t;

  typedef struct packed {
    logic [31:27] rs3;
    logic [26:25] funct2;
    logic [24:20] rs2;
    logic [19:15] rs1;
    logic [14:12] funct3;
    logic [11:7]  rd;
    logic [6:0]   opcode;
  } r4type_t;

  typedef struct packed {
    logic [31:20] imm;
    logic [19:15] rs1;
    logic [14:12] funct3;
    logic [11:7]  rd;
    logic [6:0]   opcode;
  } itype_t;

  typedef struct packed {
    logic [31:25] imm;
    logic [24:20] rs2;
    logic [19:15] rs1;
    logic [14:12] funct3;
    logic [11:7]  imm0;
    logic [6:0]   opcode;
  } stype_t;

  typedef struct packed {
    logic [31:12] imm;
    logic [11:7]  rd;
    logic [6:0]   opcode;
  } utype_t;

  typedef struct packed {
    logic [31:27] funct5;
    logic [26:25] fmt;
    logic [24:20] rs2;
    logic [19:15] rs1;
    logic [14:12] rm;
    logic [11:7]  rd;
    logic [6:0]   opcode;
  } rftype_t;  // floating-point

  typedef union packed {
    logic [31:0] instr;
    rtype_t      rtype;
    r4type_t     r4type;
    rftype_t     rftype;
    itype_t      itype;
    stype_t      stype;
    utype_t      utype;
  } instruction_t;

  // --------------------
  // Opcodes
  // --------------------
  // RV32/64G listings:
  // Quadrant 0
  localparam logic[6:0] OpcodeLoad =    7'b00_000_11;
  localparam logic[6:0] OpcodeLoadFp =  7'b00_001_11;
  localparam logic[6:0] OpcodeCustom0 = 7'b00_010_11;
  localparam logic[6:0] OpcodeMiscMem = 7'b00_011_11;
  localparam logic[6:0] OpcodeOpImm =   7'b00_100_11;
  localparam logic[6:0] OpcodeAuipc =   7'b00_101_11;
  localparam logic[6:0] OpcodeOpImm32 = 7'b00_110_11;
  // Quadrant 1
  localparam logic[6:0] OpcodeStore =   7'b01_000_11;
  localparam logic[6:0] OpcodeStoreFp = 7'b01_001_11;
  localparam logic[6:0] OpcodeCustom1 = 7'b01_010_11;
  localparam logic[6:0] OpcodeAmo =     7'b01_011_11;
  localparam logic[6:0] OpcodeOpReg =   7'b01_100_11;
  localparam logic[6:0] OpcodeLui =     7'b01_101_11;
  localparam logic[6:0] OpcodeOp32 =    7'b01_110_11;
  // Quadrant 2
  localparam logic[6:0] OpcodeMadd =    7'b10_000_11;
  localparam logic[6:0] OpcodeMsub =    7'b10_001_11;
  localparam logic[6:0] OpcodeNmsub =   7'b10_010_11;
  localparam logic[6:0] OpcodeNmadd =   7'b10_011_11;
  localparam logic[6:0] OpcodeOpFp =    7'b10_100_11;
  localparam logic[6:0] OpcodeVec =     7'b10_101_11;
  localparam logic[6:0] OpcodeCustom2 = 7'b10_110_11;
  // Quadrant 3
  localparam logic[6:0] OpcodeBranch =  7'b11_000_11;
  localparam logic[6:0] OpcodeJalr =    7'b11_001_11;
  localparam logic[6:0] OpcodeRsrvd2 =  7'b11_010_11;
  localparam logic[6:0] OpcodeJal =     7'b11_011_11;
  localparam logic[6:0] OpcodeSystem =  7'b11_100_11;
  localparam logic[6:0] OpcodeRsrvd3 =  7'b11_101_11;
  localparam logic[6:0] OpcodeCustom3 = 7'b11_110_11;

  // --------------------
  // Immediate select
  // --------------------
  typedef enum logic [3:0] {
    NOIMM,
    IIMM,
    SIMM,
    SBIMM,
    UIMM,
    JIMM,
    RS3,
    MUX_RD_RS3
  } imm_select_e;
  imm_select_e imm_select;

  logic [XLEN-1:0] imm_i_type;
  logic [XLEN-1:0] imm_s_type;
  logic [XLEN-1:0] imm_sb_type;
  logic [XLEN-1:0] imm_u_type;
  logic [XLEN-1:0] imm_uj_type;

  // --------------------
  // Decoder
  // --------------------
  // Cast instruction encoding to union struct for simplified decoder
  instruction_t instr;
  assign instr = instruction_t'(instr_fetch_data_i);

  logic illegal_instr;

  assign instr_valid_o = instr_fetch_data_valid_i & ~illegal_instr;
  assign instr_illegal_o = instr_fetch_data_valid_i & illegal_instr;

  always_comb begin
    illegal_instr = 1'b0;
    imm_select = NOIMM;

    instr_dec_o.fu = schnizo_pkg::NONE;
    instr_dec_o.alu_op = schnizo_pkg::AluOpAdd;
    instr_dec_o.lsu_op = schnizo_pkg::LsuOpLoadByte;
    instr_dec_o.csr_op = schnizo_pkg::CsrOpNone;
    // Set the default rd and rs_is_fp to zero such that if there is no write back required
    // we target register x0. x0 is read only and thus we have encoded that we have no write.
    instr_dec_o.rd = '0;
    instr_dec_o.rd_is_fp = 0;
    instr_dec_o.rs1 = '0;
    instr_dec_o.rs1_is_fp = 0;
    instr_dec_o.rs2 = '0;
    instr_dec_o.rs2_is_fp = 0;
    instr_dec_o.use_imm_as_rs3 = 1'b0;
    instr_dec_o.use_pc_as_op_a = 1'b0;
    instr_dec_o.use_rs1addr_as_op_a = 1'b0;
    instr_dec_o.is_branch = 1'b0;
    instr_dec_o.is_jal    = 1'b0;
    instr_dec_o.is_jalr   = 1'b0;
    instr_dec_o.is_fence  = 1'b0;
    instr_dec_o.is_ecall  = 1'b0;
    instr_dec_o.is_ebreak = 1'b0;
    instr_dec_o.is_mret   = 1'b0;
    instr_dec_o.is_sret   = 1'b0;
    instr_dec_o.is_wfi    = 1'b0;

    unique case (instr.rtype.opcode)
      // --------------------------------
      // Reg-Immediate Operations
      // --------------------------------
      OpcodeOpImm: begin
        instr_dec_o.fu = schnizo_pkg::ALU;
        imm_select = IIMM;
        instr_dec_o.rs1 = instr.itype.rs1;
        instr_dec_o.rd = instr.itype.rd;
        unique case (instr.itype.funct3)
          3'b000: instr_dec_o.alu_op = schnizo_pkg::AluOpAdd;  // ADDI
          3'b010: instr_dec_o.alu_op = schnizo_pkg::AluOpSlt;  // SLTI
          3'b011: instr_dec_o.alu_op = schnizo_pkg::AluOpSltu; // SLTIU
          3'b100: instr_dec_o.alu_op = schnizo_pkg::AluOpXor;  // XORI
          3'b110: instr_dec_o.alu_op = schnizo_pkg::AluOpOr;   // ORI
          3'b111: instr_dec_o.alu_op = schnizo_pkg::AluOpAnd;  // ANDI

          3'b001: begin
            instr_dec_o.alu_op = schnizo_pkg::AluOpSll; // SLLI
            if (instr.instr[31:25] != 7'b0) illegal_instr = 1'b1;
          end
          3'b101: begin
            if (instr.instr[31:25] == 7'b0) begin
              instr_dec_o.alu_op = schnizo_pkg::AluOpSrl; // SRLI
            end else if (instr.instr[31:25] == 7'b010_0000) begin
              instr_dec_o.alu_op = schnizo_pkg::AluOpSra; // SRAI
            end else begin
              illegal_instr = 1'b1;
            end
          end
        endcase
      end
      // --------------------------------
      // Integer Reg-Reg Operations
      // --------------------------------
      OpcodeOpReg: begin
        instr_dec_o.fu = schnizo_pkg::ALU; // Change MUX between ALU and MUL if M enabled
        instr_dec_o.rs1 = instr.rtype.rs1;
        instr_dec_o.rs2 = instr.rtype.rs2;
        instr_dec_o.rd  = instr.rtype.rd;

        unique case ({instr.rtype.funct7, instr.rtype.funct3})
          {7'b000_0000, 3'b000} : instr_dec_o.alu_op = schnizo_pkg::AluOpAdd; // Add
          {7'b010_0000, 3'b000} : instr_dec_o.alu_op = schnizo_pkg::AluOpSub; // Sub
          {7'b000_0000, 3'b010} : instr_dec_o.alu_op = schnizo_pkg::AluOpSlt; // Set Lower Than
          {7'b000_0000, 3'b011} : instr_dec_o.alu_op = schnizo_pkg::AluOpSltu;// Set Lower Than Uns.
          {7'b000_0000, 3'b100} : instr_dec_o.alu_op = schnizo_pkg::AluOpXor; // Xor
          {7'b000_0000, 3'b110} : instr_dec_o.alu_op = schnizo_pkg::AluOpOr;  // Or
          {7'b000_0000, 3'b111} : instr_dec_o.alu_op = schnizo_pkg::AluOpAnd; // And
          {7'b000_0000, 3'b001} : instr_dec_o.alu_op = schnizo_pkg::AluOpSll; // Shift Left Logical
          {7'b000_0000, 3'b101} : instr_dec_o.alu_op = schnizo_pkg::AluOpSrl; // Shift Right Logical
          {7'b010_0000, 3'b101} : instr_dec_o.alu_op = schnizo_pkg::AluOpSra; // Shift Right Arithm.
          // // Multiplications
          // {7'b000_0001, 3'b000} : instr_dec_o.alu_op = schnizo_pkg::MUL;
          // {7'b000_0001, 3'b001} : instr_dec_o.alu_op = schnizo_pkg::MULH;
          // {7'b000_0001, 3'b010} : instr_dec_o.alu_op = schnizo_pkg::MULHSU;
          // {7'b000_0001, 3'b011} : instr_dec_o.alu_op = schnizo_pkg::MULHU;
          // {7'b000_0001, 3'b100} : instr_dec_o.alu_op = schnizo_pkg::DIV;
          // {7'b000_0001, 3'b101} : instr_dec_o.alu_op = schnizo_pkg::DIVU;
          // {7'b000_0001, 3'b110} : instr_dec_o.alu_op = schnizo_pkg::REM;
          // {7'b000_0001, 3'b111} : instr_dec_o.alu_op = schnizo_pkg::REMU;
          default: begin
            illegal_instr = 1'b1;
          end
        endcase
      end
      // --------------------------------
      // LSU
      // --------------------------------
      OpcodeStore: begin
        instr_dec_o.fu = schnizo_pkg::STORE;
        imm_select = SIMM;
        instr_dec_o.rs1 = instr.stype.rs1;
        instr_dec_o.rs2 = instr.stype.rs2;
        // determine store size
        unique case (instr.stype.funct3)
          3'b000: instr_dec_o.lsu_op = schnizo_pkg::LsuOpStoreByte; // SB
          3'b001: instr_dec_o.lsu_op = schnizo_pkg::LsuOpStoreHalf; // SH
          3'b010: instr_dec_o.lsu_op = schnizo_pkg::LsuOpStoreWord; // SW
          3'b011: illegal_instr = 1'b1;
          default: illegal_instr = 1'b1;
        endcase
      end
      OpcodeLoad: begin
        instr_dec_o.fu = LOAD;
        imm_select = IIMM;
        instr_dec_o.rs1 = instr.itype.rs1;
        instr_dec_o.rd = instr.itype.rd;
        // determine load size and signed type
        unique case (instr.itype.funct3)
          3'b000: instr_dec_o.lsu_op = schnizo_pkg::LsuOpLoadByte; // LB
          3'b001: instr_dec_o.lsu_op = schnizo_pkg::LsuOpLoadHalf; // LH
          3'b010: instr_dec_o.lsu_op = schnizo_pkg::LsuOpLoadWord; // LW
          3'b100: instr_dec_o.lsu_op = schnizo_pkg::LsuOpLoadByteUnsigned; // LBU
          3'b101: instr_dec_o.lsu_op = schnizo_pkg::LsuOpLoadHalfUnsigned; // LHU
          3'b110,
          3'b011: illegal_instr = 1'b1; // both for RV64I
          default: illegal_instr = 1'b1;
        endcase
      end
      // --------------------------------
      // Floating-Point Load/store
      // --------------------------------
      OpcodeStoreFp: begin // STORE-FP
        instr_dec_o.fu = STORE;
        imm_select = SIMM;
        instr_dec_o.rs1 = instr.stype.rs1;
        instr_dec_o.rs2 = instr.stype.rs2;
        instr_dec_o.rs2_is_fp = 1'b1;
        // determine store size
        unique case (instr.stype.funct3)
          // Only process instruction if corresponding extension is active (static)
          3'b000:
          if (XF8) instr_dec_o.lsu_op = schnizo_pkg::LsuOpFpStoreByte; // FSB
          else illegal_instr = 1'b1;
          3'b001:
          if (XF16 | XF16ALT) instr_dec_o.lsu_op = schnizo_pkg::LsuOpFpStoreHalf; // FSH
          else illegal_instr = 1'b1;
          3'b010:
          if (RVF) instr_dec_o.lsu_op = schnizo_pkg::LsuOpFpStoreWord; // FSW
          else illegal_instr = 1'b1;
          3'b011:
          if (RVD) instr_dec_o.lsu_op = schnizo_pkg::LsuOpFpStoreDouble; // FSD
          else illegal_instr = 1'b1;
          default: illegal_instr = 1'b1;
        endcase
      end
      OpcodeLoadFp: begin // LOAD-FP
        instr_dec_o.fu = LOAD;
        imm_select = IIMM;
        instr_dec_o.rs1 = instr.itype.rs1;
        instr_dec_o.rd = instr.itype.rd;
        instr_dec_o.rd_is_fp = 1'b1;
        // determine load size
        unique case (instr.itype.funct3)
          // Only process instruction if corresponding extension is active (static)
          3'b000:
          if (XF8) instr_dec_o.lsu_op = schnizo_pkg::LsuOpFpLoadByte; // FLB
          else illegal_instr = 1'b1;
          3'b001:
          if (XF16 | XF16ALT) instr_dec_o.lsu_op = schnizo_pkg::LsuOpFpLoadHalf; // FLH
          else illegal_instr = 1'b1;
          3'b010:
          if (RVF) instr_dec_o.lsu_op = schnizo_pkg::LsuOpFpLoadWord; // FLW
          else illegal_instr = 1'b1;
          3'b011:
          if (RVD) instr_dec_o.lsu_op = schnizo_pkg::LsuOpFpLoadDouble; // FLD
          else illegal_instr = 1'b1;
          default: illegal_instr = 1'b1;
        endcase
      end
      // --------------------------------
      // Control Flow Instructions
      // --------------------------------
      OpcodeBranch: begin
        instr_dec_o.fu        = CTRL_FLOW;
        imm_select            = SBIMM;
        instr_dec_o.rs1       = instr.stype.rs1;
        instr_dec_o.rs2       = instr.stype.rs2;

        instr_dec_o.is_branch = 1'b1;

        case (instr.stype.funct3)
          3'b000: instr_dec_o.alu_op = schnizo_pkg::AluOpEq;  // BEQ
          3'b001: instr_dec_o.alu_op = schnizo_pkg::AluOpNeq; // BNE
          3'b100: instr_dec_o.alu_op = schnizo_pkg::AluOpLt;  // BLT
          3'b101: instr_dec_o.alu_op = schnizo_pkg::AluOpGe;  // BGE
          3'b110: instr_dec_o.alu_op = schnizo_pkg::AluOpLtu; // BLTU
          3'b111: instr_dec_o.alu_op = schnizo_pkg::AluOpGeu; // BGEU
          default: begin
            illegal_instr           = 1'b1;
            instr_dec_o.is_branch    = 1'b0;
          end
        endcase
      end
      // Jump and link - JAL
      OpcodeJal: begin
        instr_dec_o.fu             = CTRL_FLOW;
        instr_dec_o.alu_op         = schnizo_pkg::AluOpAdd;
        imm_select                 = JIMM;
        instr_dec_o.rd             = instr.utype.rd;
        instr_dec_o.is_jal         = 1'b1;
        instr_dec_o.use_pc_as_op_a = 1'b1;
      end
      // Jump and link register - JALR
      OpcodeJalr: begin
        instr_dec_o.fu      = CTRL_FLOW;
        instr_dec_o.alu_op  = schnizo_pkg::AluOpAdd;
        instr_dec_o.rs1     = instr.itype.rs1;
        imm_select          = IIMM;
        instr_dec_o.rd      = instr.itype.rd;
        instr_dec_o.is_jalr = 1'b1;
        // invalid jump and link register -> reserved for vector encoding
        if (instr.itype.funct3 != 3'b0) illegal_instr = 1'b1;
      end
      OpcodeAuipc: begin // AUIPC
        instr_dec_o.fu = schnizo_pkg::ALU;
        imm_select = UIMM;
        instr_dec_o.rd = instr.utype.rd;
        instr_dec_o.use_pc_as_op_a = 1'b1;
      end
      OpcodeLui: begin // LUI
        instr_dec_o.fu = schnizo_pkg::ALU;
        imm_select = UIMM;
        instr_dec_o.rd = instr.utype.rd;
      end
      // --------------------------------
      // MISC-MEM
      // --------------------------------
      OpcodeMiscMem: begin
        instr_dec_o.fu = schnizo_pkg::NONE;

        case (instr.stype.funct3)
          3'b000: begin
            instr_dec_o.is_fence = 1'b1;  // FENCE - implemented as NOP
          end
          // 3'b001: begin
          //   // FENCE.I
          // end
          default: illegal_instr = 1'b1;
        endcase
      end
      // --------------------------------
      // SYSTEM
      // --------------------------------
      OpcodeSystem: begin
        instr_dec_o.fu = schnizo_pkg::CSR;
        instr_dec_o.rd = instr.itype.rd;
        instr_dec_o.rs1 = instr.itype.rs1;
        case (instr.itype.funct3)
          3'b000: begin // non CSR related SYSTEM instructions
            unique case (instr.itype.imm)
              12'h000: instr_dec_o.is_ecall  = 1'b1; // ECALL
              12'h001: instr_dec_o.is_ebreak = 1'b1; // EBREAK
              12'h302: instr_dec_o.is_mret   = 1'b1; // MRET
              12'h102: instr_dec_o.is_sret   = 1'b1; // SRET
              12'h105: instr_dec_o.is_wfi    = 1'b1; // WFI
              default: illegal_instr = 1'b1;
            endcase
          end
          // CSR instructions
          3'b001: begin
            // CSRRW: atomically swaps values in the CSR and integer register.
            //        If rd = x0 do not read the CSR / do not cause any read side effects.
            imm_select = IIMM;
            if (instr.itype.rd == '0) instr_dec_o.csr_op = schnizo_pkg::CsrOpWrite;
            else instr_dec_o.csr_op = schnizo_pkg::CsrOpSwap;
          end
          3'b010: begin
            // CSRRS: atomically Read and set Bits in the CSR based on rs1. Write to rd.
            //        If rs1 = x0, then do not write to CSR, just read.
            imm_select = IIMM;
            if (instr.itype.rs1 == '0) instr_dec_o.csr_op = schnizo_pkg::CsrOpRead;
            else instr_dec_o.csr_op = schnizo_pkg::CsrOpSet;
          end
          3'b011: begin
            // CSRRC: atomically Read and clear Bits in the CSR based on rs1. Write to rd.
            //        If rs1 = x0, then do not write to CSR, just read.
            imm_select = IIMM;
            if (instr.itype.rs1 == '0) instr_dec_o.csr_op = schnizo_pkg::CsrOpRead;
            else instr_dec_o.csr_op = schnizo_pkg::CsrOpClear;
          end
          3'b101: begin
            // CSRRWI: atomically read the CSR, write the immediate to the CSR,
            //         and write the old value to rd.
            //         If rd = x0 do not read the CSR / do not cause any read side effects.
            imm_select = IIMM;
            instr_dec_o.use_rs1addr_as_op_a = 1'b1;
            if (instr.itype.rd == '0) instr_dec_o.csr_op = schnizo_pkg::CsrOpWrite;
            else instr_dec_o.csr_op = schnizo_pkg::CsrOpSwap;
          end
          3'b110: begin
            // CSRRSI: atomically read the CSR, set bits based on immediate (rs1 address),
            //         and write the old value to rd. If rs1 = x0, then do not write to CSR,
            //         just read.
            imm_select = IIMM;
            instr_dec_o.use_rs1addr_as_op_a = 1'b1;
            if (instr.itype.rs1 == '0) instr_dec_o.csr_op = schnizo_pkg::CsrOpRead;
            else instr_dec_o.csr_op = schnizo_pkg::CsrOpSet;
          end
          3'b111: begin
            // CSRRCI: autmically read the CSR, clear bits based on immediate (rs1 address),
            //         and write the old value to rd. If rs1 = x0, then do not write to CSR,
            //         just read.
            imm_select = IIMM;
            instr_dec_o.use_rs1addr_as_op_a = 1'b1;
            if (instr.itype.rs1 == '0) instr_dec_o.csr_op = schnizo_pkg::CsrOpRead;
            else instr_dec_o.csr_op = schnizo_pkg::CsrOpClear;
          end
          default: illegal_instr = 1'b1;
        endcase
      end
      default: begin
        illegal_instr = 1'b1;
      end
    endcase
  end

  // --------------------------------
  // Sign extend immediate
  // --------------------------------
  always_comb begin : sign_extend
    imm_i_type = {{XLEN - 12{instr_fetch_data_i[31]}}, instr_fetch_data_i[31:20]};
    imm_s_type = {
      {XLEN - 12{instr_fetch_data_i[31]}}, instr_fetch_data_i[31:25], instr_fetch_data_i[11:7]
    };
    imm_sb_type = {
      {XLEN - 13{instr_fetch_data_i[31]}},
      instr_fetch_data_i[31],
      instr_fetch_data_i[7],
      instr_fetch_data_i[30:25],
      instr_fetch_data_i[11:8],
      1'b0
    };
    imm_u_type = {{XLEN - 32{instr_fetch_data_i[31]}}, instr_fetch_data_i[31:12], 12'b0};
    imm_uj_type = {
      {XLEN - 20{instr_fetch_data_i[31]}},
      instr_fetch_data_i[19:12],
      instr_fetch_data_i[20],
      instr_fetch_data_i[30:21],
      1'b0
    };

    // NOIMM, IIMM, SIMM, SBIMM, UIMM, JIMM, RS3
    // select immediate
    case (imm_select)
      IIMM: begin
        instr_dec_o.imm = imm_i_type;
        instr_dec_o.use_imm_as_op_b = 1'b1;
      end
      SIMM: begin
        instr_dec_o.imm = imm_s_type;
        instr_dec_o.use_imm_as_op_b = 1'b1;
      end
      SBIMM: begin
        instr_dec_o.imm = imm_sb_type;
        instr_dec_o.use_imm_as_op_b = 1'b1;
      end
      UIMM: begin
        instr_dec_o.imm = imm_u_type;
        instr_dec_o.use_imm_as_op_b = 1'b1;
      end
      JIMM: begin
        instr_dec_o.imm = imm_uj_type;
        instr_dec_o.use_imm_as_op_b = 1'b1;
      end
      RS3: begin
        // imm holds address of fp operand rs3
        instr_dec_o.imm = {{XLEN - 5{1'b0}}, instr.r4type.rs3};
        instr_dec_o.use_imm_as_op_b = 1'b0;
      end
      MUX_RD_RS3: begin
        // imm holds address of operand rs3 which is in rd field
        instr_dec_o.imm = {{XLEN - 5{1'b0}}, instr.rtype.rd};
        instr_dec_o.use_imm_as_op_b = 1'b0;
      end
      default: begin
        instr_dec_o.imm = {XLEN{1'b0}};
        instr_dec_o.use_imm_as_op_b = 1'b0;
      end
    endcase
  end

endmodule
