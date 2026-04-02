// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

// Author: Stefan Odermatt <soderma@ethz.ch>
// Description: Renaming stage
module schnova_rename import schnova_pkg::*; #(
  parameter int unsigned PipeWidth   = 1,
  parameter int unsigned RmtNrIntReadPorts = 3,
  parameter int unsigned RmtNrFpReadPorts = 4,
  parameter int unsigned RmtNrWritePorts = 1,
  /// Size of both int and fp register file
  parameter int unsigned PhysRegAddrSize = 6,
  parameter int unsigned RegAddrSize = 5,
  parameter type         instr_dec_t = logic,
  parameter type         phy_id_t = logic,
  parameter type         reg_map_t = logic
) (
  input  logic         clk_i,
  input  logic         rst_i,
  input  instr_dec_t   [PipeWidth-1:0]  instr_dec_i,
  input  logic [PipeWidth-1:0]         instr_rename_gpr_valid_i,
  input  logic [$clog2(PipeWidth):0]   instr_rename_gpr_count_i,
  input  logic [PipeWidth-1:0]         instr_rename_fpr_valid_i,
  input  logic [$clog2(PipeWidth):0]   instr_rename_fpr_count_i,
  input  logic dispatched_i,
  input  logic en_superscalar_i,
  // From dispatcher, contains the desination register mappings, that the dispatcher
  // was able to allocate.
  output reg_map_t [PipeWidth-1:0]  reg_map_o,
  // To controller
  output logic freelist_ready_o,
  // From ROB
  input logic freelist_push_i,
  input [$clog2(PipeWidth):0] freelist_gpr_push_count_i,
  input phy_id_t [PipeWidth-1:0] retired_gpr_regs_i,
  input [$clog2(PipeWidth):0] freelist_fpr_push_count_i,
  input phy_id_t [PipeWidth-1:0] retired_fpr_regs_i
);

  logic       [RmtNrIntReadPorts-1:0][RegAddrSize-1:0] rmt_int_raddr;
  logic       [RmtNrFpReadPorts-1:0][RegAddrSize-1:0]  rmt_fp_raddr;
  phy_id_t [RmtNrIntReadPorts-1:0]                  rmt_int_rdata;
  phy_id_t [RmtNrFpReadPorts-1:0]                   rmt_fp_rdata;

  logic       [RmtNrWritePorts-1:0][RegAddrSize-1:0] rmt_waddr;
  // We have to insert a new mapping in the RTM for every instruction
  phy_id_t    [PipeWidth-1:0]                        allocated_gpr_regs;
  phy_id_t    [PipeWidth-1:0]                        allocated_fpr_regs;
  phy_id_t    [RmtNrWritePorts-1:0]                  new_mapping_rd;
  logic       [RmtNrWritePorts-1:0]                  rmt_int_we;
  logic       [RmtNrWritePorts-1:0]                  rmt_fp_we;

  logic [$clog2(PipeWidth):0] alloc_gpr_idx;
  logic [$clog2(PipeWidth):0] alloc_fpr_idx;

  phy_id_t [PipeWidth-1:0] mapping_rs1;
  phy_id_t [PipeWidth-1:0] mapping_rs2;
  phy_id_t [PipeWidth-1:0] mapping_rs3;
  phy_id_t [PipeWidth-1:0] mapping_rd;

  // Physical register allocation signals
  logic pop_freelist;
  logic freelist_gpr_ready;
  logic freelist_fpr_ready;

  /////////////////
  // RMT readout //
  /////////////////

  // First we have to readout the current mappings for all the
  // source registers
  always_comb begin: read_src_map
    for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
      // Generate integer rmt addresses
      rmt_int_raddr[instr_idx*3] = instr_dec_i[instr_idx].rs1;
      rmt_int_raddr[instr_idx*3+1] = instr_dec_i[instr_idx].rs2;
      rmt_int_raddr[instr_idx*3+2] = instr_dec_i[instr_idx].rd;

      // Generate float rmt addresses
      rmt_fp_raddr[instr_idx*4] = instr_dec_i[instr_idx].rs1;
      rmt_fp_raddr[instr_idx*4+1] = instr_dec_i[instr_idx].rs2;
      rmt_fp_raddr[instr_idx*4+2] = instr_dec_i[instr_idx].imm[RegAddrSize-1:0];
      rmt_fp_raddr[instr_idx*4+3] = instr_dec_i[instr_idx].rd;

      // Read out mapping for rs1
      mapping_rs1[instr_idx] =  instr_dec_i[instr_idx].rs1_is_fp ?
                                rmt_fp_rdata[instr_idx*4]        :
                                rmt_int_rdata[instr_idx*3];

      // Read out mapping for rs2
      mapping_rs2[instr_idx] =  instr_dec_i[instr_idx].rs2_is_fp ?
                                rmt_fp_rdata[instr_idx*4+1]      :
                                rmt_int_rdata[instr_idx*3+1];

      // Read out mapping for rs3, this can only ever be a floating point register
      mapping_rs3[instr_idx] =  rmt_fp_rdata[instr_idx*4+2];
      // Read out mapping of rd
      mapping_rd[instr_idx] = instr_dec_i[instr_idx].rd_is_fp ?
                              rmt_fp_rdata[instr_idx*4+3]     :
                              rmt_int_rdata[instr_idx*3+2];

    end
  end

  ///////////////////////////
  // Reading the Free List //
  ///////////////////////////

  // We pop physical registers from the free list
  // once we have sucessfully dispatched instructions
  // and are in the scalar execution mode.
  assign pop_freelist = dispatched_i & en_superscalar_i;

  schnova_free_list #(
    .PipeWidth(PipeWidth),
    .PhysAddrWidth(PhysRegAddrSize),
    .AddrWidth(RegAddrSize),
    .phy_id_t(phy_id_t)
  ) i_gpr_free_list (
    .clk_i,
    .rst_i,
    .pop_i(pop_freelist),
    .freelist_ready_o(freelist_gpr_ready),
    .pop_count_i(instr_rename_gpr_count_i),
    .allocated_regs_o(allocated_gpr_regs),
    .push_i(freelist_push_i),
    .push_count_i(freelist_gpr_push_count_i),
    .retired_regs_i(retired_gpr_regs_i)
  );

  schnova_free_list #(
    .PipeWidth(PipeWidth),
    .PhysAddrWidth(PhysRegAddrSize),
    .AddrWidth(RegAddrSize),
    .phy_id_t(phy_id_t)
  ) i_fpr_free_list (
    .clk_i,
    .rst_i,
    .pop_i(pop_freelist),
    .freelist_ready_o(freelist_fpr_ready),
    .pop_count_i(instr_rename_fpr_count_i),
    .allocated_regs_o(allocated_fpr_regs),
    .push_i(freelist_push_i),
    .push_count_i(freelist_fpr_push_count_i),
    .retired_regs_i(retired_fpr_regs_i)
  );

  assign freelist_ready_o = freelist_fpr_ready & freelist_gpr_ready;

  // Mapping the physical registers to the instructions that need renaming
  always_comb begin: map_phys_regs
    // No renaming is performed per default
    new_mapping_rd = '0;

    alloc_gpr_idx = '0;
    alloc_fpr_idx = '0;
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      if(instr_rename_gpr_valid_i[i]) begin
        new_mapping_rd[i] = allocated_gpr_regs[alloc_gpr_idx];
        // Increment to the next allocated registers
        alloc_gpr_idx = alloc_gpr_idx + 1;
      end else if (instr_rename_fpr_valid_i[i]) begin
        new_mapping_rd[i] = allocated_fpr_regs[alloc_fpr_idx];
        // Increment to the next allocated registers
        alloc_fpr_idx = alloc_fpr_idx + 1;
      end
    end
  end

  ////////////////
  // RMT update //
  ////////////////
  always_comb begin: update_rmt
    rmt_int_we = '0;
    rmt_fp_we = '0;

    for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
      rmt_waddr[instr_idx] = instr_dec_i[instr_idx].rd;
      // We update the RMT once, the instructions were successfully dispatched
      // and we are in superscalar mode, were we actually rename
      if (dispatched_i && en_superscalar_i) begin
        rmt_fp_we[instr_idx] = instr_dec_i[instr_idx].rd_is_fp;
        rmt_int_we[instr_idx] = ~instr_dec_i[instr_idx].rd_is_fp;
      end
    end
  end

  //////////////////////////////////////////////
  // Propagate inter instruction dependencies //
  //////////////////////////////////////////////

  always_comb begin: track_inter_instr_dep
    for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
      // Default: mappings already come from RMT read stage
      reg_map_o[instr_idx].phy_reg_rs1 = mapping_rs1[instr_idx];
      reg_map_o[instr_idx].phy_reg_rs2 = mapping_rs2[instr_idx];
      reg_map_o[instr_idx].phy_reg_rs3 = mapping_rs3[instr_idx];
      reg_map_o[instr_idx].phy_reg_rd_old = mapping_rd[instr_idx];
      reg_map_o[instr_idx].phy_reg_rd_new = new_mapping_rd[instr_idx];

      // We only do renaming in superscalar mode, hence only then do we have to forward
      // these renamings.
      if (en_superscalar_i) begin
        // Check against all older instructions in same bundle
        for (int unsigned older_idx = 0; older_idx < instr_idx; older_idx++) begin
          // -------------------------
          // RS1 dependency forwarding
          // -------------------------
          // Check if rs1 is the same register as the destination register
          if ((instr_dec_i[older_idx].rd == instr_dec_i[instr_idx].rs1) &&
              (instr_dec_i[older_idx].rd_is_fp == instr_dec_i[instr_idx].rs1_is_fp)) begin
              // Forward the renaming of the destination register
              reg_map_o[instr_idx].phy_reg_rs1 =  new_mapping_rd[older_idx];
          end

          // -------------------------
          // RS2 dependency forwarding
          // -------------------------
          // Check if rs2 is the same register as the destination register
          if ((instr_dec_i[older_idx].rd == instr_dec_i[instr_idx].rs2) &&
              (instr_dec_i[older_idx].rd_is_fp == instr_dec_i[instr_idx].rs2_is_fp)) begin
              // Forward the renaming of the destination register
              reg_map_o[instr_idx].phy_reg_rs2 =  new_mapping_rd[older_idx];
          end

          // -------------------------
          // RS3 dependency forwarding (FP only)
          // -------------------------
          // Check if immediate is the same register as the destination register
          if ((instr_dec_i[older_idx].rd == instr_dec_i[instr_idx].imm[RegAddrSize-1:0]) &&
              instr_dec_i[older_idx].rd_is_fp                                            &&
              instr_dec_i[instr_idx].use_imm_as_rs3) begin
              // Forward the renaming of the destination register
              reg_map_o[instr_idx].phy_reg_rs3 =  new_mapping_rd[older_idx];
          end

          // -------------------------
          // RD dependency forwarding (write after write)
          // -------------------------
          if ((instr_dec_i[older_idx].rd == instr_dec_i[instr_idx].rd) &&
              (instr_dec_i[older_idx].rd_is_fp == instr_dec_i[instr_idx].rd_is_fp)) begin
              // Forward the renaming of the destination register
              reg_map_o[instr_idx].phy_reg_rd_old =  new_mapping_rd[older_idx];
          end

        end
      end
    end
  end

  //////////////////////////////////
  // Register Mapping Table (RMT) //
  //////////////////////////////////

  // There is a RMT for the integer and floating point register file
  // Each entry contains the current renaming (which RSS will produce)
  // this register value, if it is a valid entry. Otherwise the RF
  // is up to date, and the source operand can be read out from the RF.

  schnova_rmt #(
    .NrReadPorts (RmtNrIntReadPorts),
    .NrWritePorts(RmtNrWritePorts),
    .ZeroRegZero (1),
    .AddrWidth   (RegAddrSize),
    .phy_id_t (phy_id_t)
  ) i_int_rmt  (
    // clock and reset
    .clk_i,
    .rst_ni (~rst_i),
    // read port
    .raddr_i(rmt_int_raddr),
    .rdata_o(rmt_int_rdata),
    // write port
    .waddr_i(rmt_waddr),
    .wdata_i(new_mapping_rd),
    .we_i   (rmt_int_we)
  );

  schnova_rmt #(
    .NrReadPorts (RmtNrFpReadPorts),
    .NrWritePorts(RmtNrWritePorts),
    .ZeroRegZero (0),
    .AddrWidth   (RegAddrSize),
    .phy_id_t (phy_id_t)
  ) i_fp_rmt  (
    // clock and reset
    .clk_i,
    .rst_ni (~rst_i),
    // read port
    .raddr_i(rmt_fp_raddr),
    .rdata_o(rmt_fp_rdata),
    // write port
    .waddr_i(rmt_waddr),
    .wdata_i(new_mapping_rd),
    .we_i   (rmt_fp_we)
  );

endmodule
