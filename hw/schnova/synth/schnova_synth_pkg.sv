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

    typedef logic [DataWidth-1:0] data_t;
    typedef logic [AddrWidth-1:0] addr_t;
    typedef logic [DataWidth/8-1:0] strb_t;
    typedef logic [CoreUserWidth-1:0] user_t;

    `REQRSP_TYPEDEF_ALL(data, addr_t, data_t, strb_t, user_t)

    typedef struct packed {
        snitch_pkg::acc_addr_e addr;
        logic [5:0]            id;
        logic [31:0]           data_op;
        data_t                 data_arga;
        data_t                 data_argb;
        addr_t                 data_argc;
    } acc_req_t;

    typedef struct packed {
        logic [5:0] id;
        logic       error;
        data_t      data;
    } acc_resp_t;


endpackage
