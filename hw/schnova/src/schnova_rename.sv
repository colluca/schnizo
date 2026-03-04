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
  /// Size of both int and fp register file
  parameter int unsigned RegAddrSize = 5,
  parameter int unsigned RmtNrIntReadPorts = 3*PipeWidth,
  parameter int unsigned RmtNrIntWritePorts = 1*PipeWidth,
  parameter int unsigned RmtNrFpReadPorts = 4*PipeWidth,
  parameter int unsigned RmtNrFpWritePorts = 1*PipeWidth,
  parameter type         instr_dec_t = logic,
  parameter type         rmt_entry_t = logic,
  parameter type         rename_data_t = logic
) (
  input  logic         clk_i,
  input  logic         rst_i,
  // From controller, whether all the instructions in the current fetch block
  // where dispatched successfully
  input  logic all_instr_dispatched_i;
  // From dispatcher, contains the desination register mappings, that the dispatcher
  // was able to allocate.
  input  rmt_entry_t   [PipeWidth-1:0]  dest_map_i,
  input  instr_dec_t   [PipeWidth-1:0]  instr_dec_i,
  output rename_data_t [PipeWidth-1:0]  rename_info_o
);
  logic [RmtNrIntReadPorts-1:0][RegAddrSize-1:0] rmt_int_raddr;
  logic [RmtNrFpReadPorts-1:0][RegAddrSize-1:0]  rmt_fp_raddr;
  rmt_entry_t [RmtNrIntReadPorts-1:0]            rmt_int_rdata;
  rmt_entry_t [RmtNrFpReadPorts-1:0]             rmt_fp_rdata;
  rmt_entry_t [RmtNrIntWritePorts-1:0]           rmt_int_we;
  rmt_entry_t [RmtNrFpWritePorts-1:0]            rmt_fp_we;

  rmt_entry_t [PipeWidth-1:0] mapping_rs1;
  rmt_entry_t [PipeWidth-1:0] mapping_rs2;
  rmt_entry_t [PipeWidth-1:0] mapping_rs3;
  rmt_entry_t [PipeWidth-1:0] mapping_rd;

  // Since Pipewidth = NrFpWritePorts we can directly use this
  // to update the RMTs as the write data.
  rmt_entry_t [PipeWidth-1:0] new_mapping_rd;

  // Whether the instruction was already renamed in a previous cycle
  logic is_renamed_d, is_renamed_q;

  rmt_entry_t no_mapping;
  assign no_mapping = '{
    producer:    '0,
    valid: 1'b0
  };

  /////////////////
  // RMT readout //
  /////////////////

  // First we have to readout the current mappings for all the
  // source registers
  always_comb begin: read_register_mapping
    for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
      // Generate integer register source index
      rmt_int_raddr[instr_idx*2] = instr_dec_i[instr_idx].rs1;
      rmt_int_raddr[instr_idx*2+1] = instr_dec_i[instr_idx].rs2;
      // Generate float register source index
      rmt_fp_raddr[instr_idx*3] = instr_dec_i[instr_idx].rs1;
      rmt_fp_raddr[instr_idx*3+1] = instr_dec_i[instr_idx].rs2;
      rmt_fp_raddr[instr_idx*3+2] = instr_dec_i[instr_idx].imm[RegAddrSize-1:0];
      // Read out mapping for rs1
      mapping_rs1[instr_idx] =  instr_dec_i[instr_idx].rs1_is_fp ?
                                rmt_fp_rdata[instr_idx*3]        :
                                rmt_int_rdata[instr_idx*2];

      // Read out mapping for rs2
      mapping_rs2[instr_idx] =  instr_dec_i[instr_idx].rs2_is_fp ?
                                rmt_fp_rdata[instr_idx*3+1]      :
                                rmt_int_rdata[instr_idx*2+1];

      // Read out mapping for rs3
      mapping_rs3[instr_idx] =  instr_dec_i[instr_idx].use_imm_as_rs3 ?
                                rmt_fp_rdata[instr_idx*3+2]           :
                                no_mapping;
    end
  end

  ////////////////
  // RMT update //
  ////////////////
  always_comb begin: update_rmt
    rmt_int_we = '0;
    rmt_fp_we = '0;
    for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
      // First we readout the current mapping
      new_mapping_rd[instr_idx] = '{
        producer: dest_map_i[instr_idx].producer,
        valid:    1'b1
      };
      // Only update the RMT if the destination mapping sent by the dispatcher is valid
      // Dispatching will happen in order, because we have to update the renaming in order
      // to not break any dependencies.
      if (dest_map_i[instr_idx].valid) begin
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
      rename_info_o[instr_idx].producer_op_a = mapping_rs1[instr_idx];
      rename_info_o[instr_idx].producer_op_b = mapping_rs2[instr_idx];
      rename_info_o[instr_idx].producer_op_c = mapping_rs3[instr_idx];

      // Check against all older instructions in same bundle
      for (int unsigned older_idx = 0; older_idx < instr_idx; older_idx++) begin
        // -------------------------
        // RS1 dependency forwarding
        // -------------------------
        // Check if rs1 is the same register as the destination register
        if ((instr_dec_i[older_idx].rd == instr_dec_i[instr_idx].rs1) &&
            (instr_dec_i[older_idx].rd_is_fp == instr_dec_i[instr_idx].rs1_is_fp)) begin

            rename_info_o[instr_idx].producer_op_a =  is_renamed_q[older_idx] ?
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

            rename_info_o[instr_idx].producer_op_b =  is_renamed_q[older_idx] ?
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

            rename_info_o[instr_idx].producer_op_c =  is_renamed_q[older_idx] ?
            // The mapping was alrady stored to the RMT in a previous cycle
                                                      mapping_rd[older_idx]   :
            // The mapping should be forwarded by the dispatcher/functional units
                                                      new_mapping_rd[older_idx];
        end
      end
    end
  end

  ////////////////////////////
  // Renaming valid masking //
  ////////////////////////////
  // Renaming for an instruction has to strictly happen in order
  // so we have to make sure that renamings are valid only if all
  // older instruction renamings are valid
  always_comb begin: rename_valid_masking
    for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
      if(instr_idx == 0) begin
        // The first instruction does not have to wait on older instructions to complete renaming
        rename_info_o[instr_idx].valid = dest_map_i[instr_idx].valid | is_renamed_q[instr_idx];
      end else begin
        rename_info_o[instr_idx].valid = rename_info_o[instr_idx-1].valid                       ?
                                          dest_map_i[instr_idx].valid | is_renamed_q[instr_idx] :
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
    .rmt_entry_t (rmt_entry_t),
    .NrReadPorts (RmtNrIntReadPorts),
    .NrWritePorts(RmtNrIntWritePorts),
    .ZeroRegZero (1),
    .AddrWidth   (RegAddrSize)
  ) i_int_rmt (
    .clk_i,
    .rst_ni (~rst_i),
    .raddr_i(rmt_int_raddr),
    .rdata_o(rmt_int_rdata),
    .waddr_i(gpr_waddr),
    .wdata_i(gpr_wdata),
    .we_i   (gpr_we)
  );

  schnova_rmt #(
    .rmt_entry_t  (rmt_entry_t),
    .NrReadPorts  (RmtNrFpReadPorts),
    .NrWritePorts (RmtNrFpWritePorts),
    .ZeroRegZero  (0),
    .AddrWidth    (RegAddrSize)
  ) i_fp_rmt (
    .clk_i,
    .rst_ni (~rst_i),
    .raddr_i(rmt_fp_raddr),
    .rdata_o(rmt_fp_rdata),
    .waddr_i(fpr_waddr),
    .wdata_i(fpr_wdata),
    .we_i   (fpr_we)
  );

  // Update the is_renamed register that keeps track of which registers already have been
  // renamed
  `FFAR(is_renamed_q, is_renamed_d, '0, clk_i, rst_i);

  always_comb begin: rename_state_update
    is_renamed_d = is_renamed_q;
    for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
      if(all_instr_dispatched_i) begin
        // We have to restart renaming in the next cycle in that case
        is_renamed_d[instr_idx] = 1'b0;
      end else if (dest_map_i[instr_idx].valid) begin
        // The destination register was renamed in this cycle
        // hence the renaming can be read out from the RMT in the next cycle
        is_renamed_d[instr_idx] = 1'b1;
      end
    end
  end

  ////////////////
  // Assertions //
  //////////// ///

  // This module assumes that NrIntWritePorts == PipeWidth == NrFpWritePorts
  `ASSERT_INIT(CheckRenameTypeDim, (NrIntWritePorts == PipeWidth) && (NrFpWritePorts == PipeWidth))

endmodule
