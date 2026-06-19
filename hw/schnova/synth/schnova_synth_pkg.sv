// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "reqrsp_interface/typedef.svh"

package schnova_synth_pkg;

    // schnova_synth relevant declarations
    localparam int unsigned NumIntOutstandingLoads = 4;
    localparam int unsigned NumIntOutstandingMem = 4;
    localparam logic [31:0] BootAddr = 32'h80000000;
    localparam int unsigned MaxIterationsW = 16;

    localparam int unsigned AddrWidth = 48;
    localparam int unsigned DataWidth = 64;
    localparam int unsigned CoreUserWidth = 64;

    localparam integer unsigned FLEN = 64;
    localparam integer unsigned XLEN = 32;

    typedef logic [DataWidth-1:0] data_t;
    typedef logic [AddrWidth-1:0] addr_t;
    typedef logic [DataWidth/8-1:0] strb_t;
    typedef logic [CoreUserWidth-1:0] user_t;

    typedef enum logic [1:0] {
        ALU_RS,
        LSU_RS,
        FPU_RS
    } rs_type_e;

    `REQRSP_TYPEDEF_ALL(data, addr_t, data_t, strb_t, user_t)

    // Res stat specific types
    // Set them to some large value as an upper bound
    localparam integer unsigned MaxNofRss = 128;
    localparam integer unsigned NofFus = 8;

    localparam integer unsigned SlotIdWidth = cf_math_pkg::idx_width(MaxNofRss);
    localparam integer unsigned RsIdWidth  = cf_math_pkg::idx_width(NofFus);

    typedef logic [SlotIdWidth-1:0]   slot_id_t;
    typedef logic [RsIdWidth-1:0] rs_id_t;

    typedef struct packed {
        slot_id_t slot_id; // used to select the slot of the request within the RS
        rs_id_t   rs_id; // used to control the request crossbar
    } producer_id_t;

    localparam int OpLen = (FLEN > XLEN) ? FLEN : XLEN;

    typedef struct packed {
        schnova_pkg::fu_t       fu;
        schnova_pkg::alu_op_e   alu_op;
        schnova_pkg::lsu_op_e   lsu_op;
        schnova_pkg::csr_op_e   csr_op;
        schnova_pkg::fpu_op_e   fpu_op;
        logic [OpLen-1:0]       operand_a;
        logic                   use_operand_a;
        logic [OpLen-1:0]       operand_b;
        logic                   use_operand_b;
        // Imm field: for floating-point fused operations (FMADD, FMSUB, FNMADD, FNMSUB)
        // this field holds the value of the third operand
        logic [OpLen-1:0]       imm;
        logic                   use_imm;
        schnova_pkg::lsu_size_e lsu_size;
        fpnew_pkg::fp_format_e  fpu_fmt_src;
        fpnew_pkg::fp_format_e  fpu_fmt_dst;
        fpnew_pkg::roundmode_e  fpu_rnd_mode;
    } fu_data_t;

    typedef struct packed {
        producer_id_t producer;
    } disp_rsp_t;

    typedef logic [OpLen-1:0] operand_t;

    typedef struct packed {
        schnova_pkg::fu_t                          fu; // 4 bit
        schnova_pkg::alu_op_e                      alu_op; // 5 bit
        schnova_pkg::lsu_op_e                      lsu_op; // 4 bit
        schnova_pkg::csr_op_e                      csr_op; // 3 bit
        schnova_pkg::fpu_op_e                      fpu_op; // 5 bit
        // rd and rs_is_fp must be set to all zero to encoded that there is
        // no write back for this instruction.
        logic [schnova_pkg::RegAddrSize-1:0]       rd;
        logic                         rd_is_fp; // set if rd is a FP register
        logic [schnova_pkg::RegAddrSize-1:0]       rs1;
        logic                         rs1_is_fp; // set if rs1 is a FP register
        logic                         use_rs1;
        logic [schnova_pkg::RegAddrSize-1:0]       rs2;
        logic                         rs2_is_fp; // set if rs2 is a FP register
        logic                         use_rs2;
        // Imm field: for unfinished floating-point fused operations (FMADD, FMSUB, FNMADD, FNMSUB)
        // this field holds the address of the third operand (rs3) from the floating-point regfile
        logic [XLEN-1:0]              imm;
        logic                         use_imm_as_rs3; // set if rs3 is a FP register
        logic                         use_imm;
        schnova_pkg::lsu_size_e                    lsu_size; // The bit width the LSU operates on, 2 bit
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
        logic [schnova_pkg::FrepBodySizeWidth-1:0] frep_bodysize;
        schnova_pkg::frep_mode_e                   frep_mode;
    } instr_dec_t;

    localparam int unsigned RobTagWidth = 5;

    localparam int unsigned PhysRegAddrSize = 6;

    typedef logic [PhysRegAddrSize-1:0] phy_id_t;

    typedef struct packed {
        producer_id_t               producer_id;
        phy_id_t                    dest_reg;
        logic [RobTagWidth-1:0]     rob_tag;
        logic                       dest_reg_is_fp;
        logic                       is_branch;
        logic                       is_jump;
    } instr_tag_t;

    typedef struct packed {
        schnova_pkg::csr_op_e csr_op;
        logic [OpLen-1:0]     operand_a;
        logic [11:0]          imm;
        instr_tag_t           tag;
    } csr_disp_req_t;

    typedef struct packed {
        schnova_pkg::alu_op_e alu_op;
        logic [XLEN-1:0]      operand_a;
        logic [XLEN-1:0]      operand_b;
        instr_tag_t           tag;
    } alu_si_disp_req_t;

    typedef struct packed {
        schnova_pkg::alu_op_e alu_op;
        logic [XLEN-1:0]      operand_a;
        logic [XLEN-1:0]      operand_b;
        instr_tag_t           tag;
        phy_id_t              phy_reg_op_a;
        logic                 is_op_a_cnst;
        phy_id_t              phy_reg_op_b;
        logic                 is_op_b_cnst;
    } alu_rs_disp_req_t;

    typedef struct packed {
        schnova_pkg::lsu_op_e   lsu_op;
        logic [XLEN-1:0]        operand_a; // Can only be an integer value
        logic [OpLen-1:0]       operand_b; // Can be either integer or floating point
        logic [XLEN-1:0]        imm;       // Only ever used as an integer
        schnova_pkg::lsu_size_e lsu_size;
        instr_tag_t             tag;
    } lsu_si_disp_req_t;

    typedef struct packed {
        schnova_pkg::lsu_op_e   lsu_op;
        logic [XLEN-1:0]        imm;       // Only ever used as an integer
        schnova_pkg::lsu_size_e lsu_size;
        instr_tag_t             tag;
        phy_id_t                phy_reg_op_a;
        phy_id_t                phy_reg_op_b;
        logic                   is_op_b_fp;
    } lsu_rs_disp_req_t;

    typedef struct packed {
        schnova_pkg::fpu_op_e   fpu_op;
        logic [OpLen-1:0]       operand_a;
        logic [OpLen-1:0]       operand_b;
        logic [OpLen-1:0]       imm;
        fpnew_pkg::fp_format_e  fpu_fmt_src;
        fpnew_pkg::fp_format_e  fpu_fmt_dst;
        fpnew_pkg::roundmode_e  fpu_rnd_mode;
        instr_tag_t             tag;
    } fpu_si_disp_req_t;

    typedef struct packed {
        schnova_pkg::fpu_op_e   fpu_op;
        logic [OpLen-1:0]       imm;
        fpnew_pkg::fp_format_e  fpu_fmt_src;
        fpnew_pkg::fp_format_e  fpu_fmt_dst;
        fpnew_pkg::roundmode_e  fpu_rnd_mode;
        instr_tag_t             tag;
        phy_id_t                phy_reg_op_a;
        logic                   is_op_a_fp;
        phy_id_t                phy_reg_op_b;
        phy_id_t                phy_reg_op_c;
        logic                   is_op_c_cnst;
    } fpu_rs_disp_req_t;

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

    typedef struct packed {
        phy_id_t phy_reg_rs1;
        phy_id_t phy_reg_rs2;
        phy_id_t phy_reg_rs3;
        phy_id_t phy_reg_rd_new;
        phy_id_t phy_reg_rd_old;
    } reg_map_t;

    typedef struct packed {
        snitch_pkg::acc_addr_e      addr;
        logic [PhysRegAddrSize-1:0] id;
        logic [31:0]                data_op;
        data_t                      data_arga;
        data_t                      data_argb;
        addr_t                      data_argc;
    } acc_req_t;

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

endpackage
