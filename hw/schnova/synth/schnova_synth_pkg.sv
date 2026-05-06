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

endpackage
