// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

// Author: Stefan Odermatt <soderma@ethz.ch>
// TODO (soderma): Might make sense to use a free list instead of always asking the reservation stations/
// dispatch stage if a slot is available and sending the destination renaming back
// Description: Renaming stage
module schnova_rename import schnizo_pkg::*; #(
  parameter int unsigned PipeWidth   = 1,
  parameter int unsigned RmtNrIntReadPorts = 3,
  parameter int unsigned RmtNrFpReadPorts = 4,
  parameter int unsigned RmtNrWritePorts = 1,
  /// Size of both int and fp register file
  parameter int unsigned PhysRegAddrSize = 6,
  parameter int unsigned RegAddrSize = 5,
  parameter type         instr_dec_t = logic,
  parameter type         phy_id_t = logic,
  parameter type         rename_data_t = logic
) (
  input  logic         clk_i,
  input  logic         rst_i,
  input  logic dispatched_i,
  input  logic dispatch_valid_i,
  input  logic en_superscalar_i,
  // From dispatcher, contains the desination register mappings, that the dispatcher
  // was able to allocate.
  input  instr_dec_t   [PipeWidth-1:0]  instr_dec_i,
  output rename_data_t [PipeWidth-1:0]  rename_info_o
);

  phy_id_t    [PipeWidth-1:0]  dest_map;

  logic       [RmtNrIntReadPorts-1:0][RegAddrSize-1:0] rmt_int_raddr;
  logic       [RmtNrFpReadPorts-1:0][RegAddrSize-1:0]  rmt_fp_raddr;
  phy_id_t [RmtNrIntReadPorts-1:0]                  rmt_int_rdata;
  phy_id_t [RmtNrFpReadPorts-1:0]                   rmt_fp_rdata;

  logic       [RmtNrWritePorts-1:0][RegAddrSize-1:0] rmt_waddr;
  // We have to insert a new mapping in the RTM for every instruction
  phy_id_t    [RmtNrWritePorts-1:0]                  new_mapping_rd;
  logic       [RmtNrWritePorts-1:0]                  rmt_int_we;
  logic       [RmtNrWritePorts-1:0]                  rmt_fp_we;

  phy_id_t [PipeWidth-1:0] mapping_rs1;
  phy_id_t [PipeWidth-1:0] mapping_rs2;
  phy_id_t [PipeWidth-1:0] mapping_rs3;
  phy_id_t [PipeWidth-1:0] mapping_rd;

  // Whether the instruction was already renamed in a previous cycle
  logic [PipeWidth-1:0] is_renamed_d, is_renamed_q;

  // Physical register allocation signals
  logic alloc_pr_hs;
  logic alloc_pr_ready;

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
      if(instr_idx < PipeWidth) begin
        rmt_int_raddr[instr_idx*3+2] = instr_dec_i[instr_idx].rd;
      end
      // Generate float rmt addresses
      rmt_fp_raddr[instr_idx*4] = instr_dec_i[instr_idx].rs1;
      rmt_fp_raddr[instr_idx*4+1] = instr_dec_i[instr_idx].rs2;
      rmt_fp_raddr[instr_idx*4+2] = instr_dec_i[instr_idx].imm[RegAddrSize-1:0];
      if(instr_idx < PipeWidth) begin
        rmt_fp_raddr[instr_idx*4+3] = instr_dec_i[instr_idx].rd;
      end
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
      if(instr_idx < PipeWidth) begin
        mapping_rd[instr_idx] = instr_dec_i[instr_idx].rd_is_fp ?
                                rmt_fp_rdata[instr_idx*4+3]     :
                                rmt_int_rdata[instr_idx*3+2];
      end
    end
  end

  ///////////////////////////
  // Reading the Free List //
  ///////////////////////////

  logic alloc_valid = 1'b0;
  logic [$clog2(PipeWidth):0] alloc_count;

  schnova_free_list #(
    .PipeWidth(PipeWidth),
    .PhysAddrWidth(PhysRegAddrSize),
    .AddrWidth(RegAddrSize),
    .phy_id_t(phy_id_t)
  ) i_free_list (
    .clk_i,
    .rst_i,
    .alloc_valid_i(alloc_valid),
    .alloc_ready_o(alloc_pr_ready),
    .alloc_count_i(alloc_count),
    .alloc_regs_o(dest_map),
    .retire_valid_i(),
    .retire_count_i(),
    .retire_regs_i()
  );

  assign alloc_pr_hs= dispatch_valid_i & alloc_pr_ready;

  ////////////////
  // RMT update //
  ////////////////
  always_comb begin: update_rmt
    rmt_int_we = '0;
    rmt_fp_we = '0;

    for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
      // First we readout the current mapping
      new_mapping_rd[instr_idx] = dest_map[instr_idx];
      rmt_waddr[instr_idx] = instr_dec_i[instr_idx].rd;
      // Only update the RMT if the destination mapping sent by the dispatcher is valid
      // Dispatching will happen in order, because we have to update the renaming in order
      // to not break any dependencies.
      if (alloc_pr_hs && en_superscalar_i) begin
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
      rename_info_o[instr_idx].phy_reg_op_a = mapping_rs1[instr_idx];
      rename_info_o[instr_idx].phy_reg_op_b = mapping_rs2[instr_idx];
      rename_info_o[instr_idx].phy_reg_op_c = mapping_rs3[instr_idx];
      // TODO(soderma): Assign correct values s
      rename_info_o[instr_idx].phy_reg_dest_new = mapping_rd[instr_idx];
      rename_info_o[instr_idx].phy_reg_dest_old = mapping_rd[instr_idx];

      // Check against all older instructions in same bundle
      for (int unsigned older_idx = 0; older_idx < instr_idx; older_idx++) begin
        // -------------------------
        // RS1 dependency forwarding
        // -------------------------
        // Check if rs1 is the same register as the destination register
        if ((instr_dec_i[older_idx].rd == instr_dec_i[instr_idx].rs1) &&
            (instr_dec_i[older_idx].rd_is_fp == instr_dec_i[instr_idx].rs1_is_fp)) begin

            rename_info_o[instr_idx].phy_reg_op_a =  is_renamed_q[older_idx] ?
            // The mapping was alrady stored to the RMT in a previous cycle
                                                      mapping_rd[older_idx]   :
            // The mapping should be forwarded by the dispatcher/functional units
                                                      new_mapping_rd[older_idx];
        end

        // -------------------------
        // RS2 dependency forwarding
        // -------------------------
        // Check if rs2 is the same register as the destination register
        if ((instr_dec_i[older_idx].rd == instr_dec_i[instr_idx].rs2) &&
            (instr_dec_i[older_idx].rd_is_fp == instr_dec_i[instr_idx].rs2_is_fp)) begin

            rename_info_o[instr_idx].phy_reg_op_b =  is_renamed_q[older_idx] ?
            // The mapping was alrady stored to the RMT in a previous cycle
                                                      mapping_rd[older_idx]   :
            // The mapping should be forwarded by the dispatcher/functional units
                                                      new_mapping_rd[older_idx];
        end

        // -------------------------
        // RS3 dependency forwarding (FP only)
        // -------------------------
        // Check if immediate is the same register as the destination register
        if ((instr_dec_i[older_idx].rd == instr_dec_i[instr_idx].imm[RegAddrSize-1:0]) &&
            instr_dec_i[older_idx].rd_is_fp                                            &&
            instr_dec_i[instr_idx].use_imm_as_rs3) begin

            rename_info_o[instr_idx].phy_reg_op_c =  is_renamed_q[older_idx] ?
            // The mapping was alrady stored to the RMT in a previous cycle
                                                      mapping_rd[older_idx]   :
            // The mapping should be forwarded by the dispatcher/functional units
                                                      new_mapping_rd[older_idx];
        end
      end
      // Renaming for an instruction has to strictly happen in order
      // so we have to make sure that renamings are valid only if all
      // older instruction renamings are valid
      if(instr_idx == 0) begin
        // The first instruction does not have to wait on older instructions to complete renaming
        rename_info_o[instr_idx].valid = dispatch_valid_i | is_renamed_q[instr_idx];
      end else begin
        rename_info_o[instr_idx].valid = rename_info_o[instr_idx-1].valid                       ?
                                          dispatch_valid_i | is_renamed_q[instr_idx] :
                                          1'b0;
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
    .ZeroRegZero (1),
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

  // Update the is_renamed register that keeps track of which registers already have been
  // renamed
  `FFAR(is_renamed_q, is_renamed_d, '0, clk_i, rst_i);

  always_comb begin: rename_state_update
    is_renamed_d = is_renamed_q;
    for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
      if(dispatched_i) begin
        // We have to restart renaming in the next cycle in that case
        is_renamed_d[instr_idx] = 1'b0;
      end else if (alloc_pr_hs) begin
        // The destination register was renamed in this cycle
        // hence the renaming can be read out from the RMT in the next cycle
        is_renamed_d[instr_idx] = 1'b1;
      end
    end
  end

endmodule
