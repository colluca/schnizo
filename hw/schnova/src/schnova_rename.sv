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
  parameter type         instr_dec_t = logic,
  parameter type         rmt_entry_t = logic,
  parameter type         rename_data_t = logic,
  parameter type         rmt_clear_req_t = logic
) (
  input  logic         clk_i,
  input  logic         rst_i,
  // From controller, the rename state should be cleared once we have an exception
  // to start from a clean slate
  input  logic flush_i,
  input  logic all_instr_dispatched_i,
  // From dispatcher, contains the desination register mappings, that the dispatcher
  // was able to allocate.
  input  rmt_entry_t   [PipeWidth-1:0]  dest_map_i,
  input  instr_dec_t   [PipeWidth-1:0]  instr_dec_i,
  output rename_data_t [PipeWidth-1:0]  rename_info_o,
  // From writeback
  input rmt_clear_req_t [PipeWidth-1:0] rmt_clear_req_i
);

  // We have to read out a mapping for every source operand and potentially
  // the destination operand if it takes multiple cycles except for the last destination operand
  // since we only have to track/forward dependencies in this current instruction block
  // Integer instructons have 2 source + 1 destination register
  localparam int unsigned RmtNrIntReadPorts = 2*PipeWidth + 1*PipeWidth - 1;
  // Float instructions have 3 source + 1 destination register
  localparam int unsigned RmtNrFpReadPorts = 3*PipeWidth + 1*PipeWidth - 1;
  // We have to write the new mapping for every destination register
  localparam int unsigned RmtNrWritePorts = 1*PipeWidth;
  // We have to potentially clear a mappy for every instruction each cycle
  localparam int unsigned RmtNrClearPorts = 1*PipeWidth;

  logic       [RmtNrIntReadPorts-1:0][RegAddrSize-1:0] rmt_int_raddr;
  logic       [RmtNrFpReadPorts-1:0][RegAddrSize-1:0]  rmt_fp_raddr;
  rmt_entry_t [RmtNrIntReadPorts-1:0]                  rmt_int_rdata;
  rmt_entry_t [RmtNrFpReadPorts-1:0]                   rmt_fp_rdata;

  logic       [RmtNrWritePorts-1:0][RegAddrSize-1:0] rmt_waddr;
  // We have to insert a new mapping in the RTM for every instruction
  rmt_entry_t [RmtNrWritePorts-1:0]                  new_mapping_rd;
  logic       [RmtNrWritePorts-1:0]                  rmt_int_we;
  logic       [RmtNrWritePorts-1:0]                  rmt_fp_we;

  logic       [RmtNrClearPorts-1:0][RegAddrSize-1:0] rmt_caddr;
  rmt_entry_t [RmtNrClearPorts-1:0]                  rmt_cdata;
  logic       [RmtNrClearPorts-1:0]                  rmt_int_clear;
  logic       [RmtNrClearPorts-1:0]                  rmt_fp_clear;

  rmt_entry_t [PipeWidth-1:0] mapping_rs1;
  rmt_entry_t [PipeWidth-1:0] mapping_rs2;
  rmt_entry_t [PipeWidth-1:0] mapping_rs3;
  rmt_entry_t [PipeWidth-2:0] mapping_rd;

  // Whether the instruction was already renamed in a previous cycle
  logic [PipeWidth-2:0] is_renamed_d, is_renamed_q;

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

      // Read out mapping for rs3
      mapping_rs3[instr_idx] =  instr_dec_i[instr_idx].use_imm_as_rs3 ?
                                rmt_fp_rdata[instr_idx*4+2]           :
                                no_mapping;
      // Read out mapping of rd
      if(instr_idx < PipeWidth) begin
        mapping_rd[instr_idx] = instr_dec_i[instr_idx].rd_is_fp ?
                                rmt_fp_rdata[instr_idx*4+3]     :
                                rmt_int_rdata[instr_idx*3+2];
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
      // First we readout the current mapping
      new_mapping_rd[instr_idx] = '{
        producer: dest_map_i[instr_idx].producer,
        valid:    1'b1
      };
      rmt_waddr[instr_idx] = instr_dec_i[instr_idx].rd;
      // Only update the RMT if the destination mapping sent by the dispatcher is valid
      // Dispatching will happen in order, because we have to update the renaming in order
      // to not break any dependencies.
      if (dest_map_i[instr_idx].valid) begin
        rmt_fp_we[instr_idx] = instr_dec_i[instr_idx].rd_is_fp;
        rmt_int_we[instr_idx] = ~instr_dec_i[instr_idx].rd_is_fp;
      end
    end
  end

  ///////////////
  // RMT clear //
  ///////////////
  always_comb begin: clear_rmt
    rmt_int_clear = '0;
    rmt_fp_clear    = '0;
    for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
      rmt_caddr[instr_idx] = rmt_clear_req_i[instr_idx].dest_reg;
      rmt_cdata[instr_idx] = rmt_clear_req_i[instr_idx].producer_dest;
      // We have to send a clear request to the RMT if it is a valid clear request
      if (rmt_clear_req_i[instr_idx].valid) begin
        rmt_fp_clear[instr_idx] = rmt_clear_req_i[instr_idx].dest_reg_is_fp;
        rmt_int_clear[instr_idx] = ~rmt_clear_req_i[instr_idx].dest_reg_is_fp;
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
    .NrReadPorts (RmtNrIntReadPorts),
    .NrWritePorts(RmtNrWritePorts),
    .NrClearPorts(RmtNrClearPorts),
    .ZeroRegZero (1),
    .AddrWidth   (RegAddrSize),
    .rmt_entry_t (rmt_entry_t)
  ) i_int_rmt  (
    // clock and reset
    .clk_i,
    .rst_ni (~rst_i),
    .flush_i(flush_i),
    // read port
    .raddr_i(rmt_int_raddr),
    .rdata_o(rmt_int_rdata),
    // write port
    .waddr_i(rmt_waddr),
    .wdata_i(new_mapping_rd),
    .we_i   (rmt_int_we),
    // clear port
    .caddr_i(rmt_caddr),
    .cdata_i(rmt_cdata),
    .clear_i(rmt_int_clear)
  );

  schnova_rmt #(
    .NrReadPorts (RmtNrFpReadPorts),
    .NrWritePorts(RmtNrWritePorts),
    .NrClearPorts(RmtNrClearPorts),
    .ZeroRegZero (1),
    .AddrWidth   (RegAddrSize),
    .rmt_entry_t (rmt_entry_t)
  ) i_fp_rmt  (
    // clock and reset
    .clk_i,
    .rst_ni (~rst_i),
    .flush_i(flush_i),
    // read port
    .raddr_i(rmt_fp_raddr),
    .rdata_o(rmt_fp_rdata),
    // write port
    .waddr_i(rmt_waddr),
    .wdata_i(new_mapping_rd),
    .we_i   (rmt_fp_we),
    // clear port
    .caddr_i(rmt_caddr),
    .cdata_i(rmt_cdata),
    .clear_i(rmt_fp_clear)
  );

  // Update the is_renamed register that keeps track of which registers already have been
  // renamed
  `FFAR(is_renamed_q, is_renamed_d, '0, clk_i, rst_i);

  always_comb begin: rename_state_update
    is_renamed_d = is_renamed_q;
    for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
      if(flush_i | all_instr_dispatched_i) begin
        // We have to restart renaming in the next cycle in that case
        is_renamed_d[instr_idx] = 1'b0;
      end else if (dest_map_i[instr_idx].valid) begin
        // The destination register was renamed in this cycle
        // hence the renaming can be read out from the RMT in the next cycle
        is_renamed_d[instr_idx] = 1'b1;
      end
    end
  end
endmodule
