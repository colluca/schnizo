// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Stefan Odermatt <soderma@ethz.ch>
module schnova_refcount import schnova_pkg::*; #(
    parameter int unsigned PipeWidth    = 1,
    parameter int unsigned NofPhysGpr   = 64,
    parameter int unsigned NofPhysFpr   = 64,
    parameter int unsigned NofAlus      = 1,
    parameter int unsigned AluNofRss    = 3,
    parameter int unsigned NofLsus      = 1,
    parameter int unsigned LsuNofRss    = 3,
    parameter int unsigned NofFpus      = 1,
    parameter int unsigned FpuNofRss    = 2,
    parameter type         phy_id_t     = logic,
    parameter type         disp_req_t   = logic,
    parameter type         refcnt_req_t = logic
) (
    input  logic                         clk_i,
    input  logic                         rst_i,
    // Dispatcher Interface (Set new reference for RAT)
    input  logic                         instr_exec_commit_superscalar_i,
    input  logic      [PipeWidth-1:0]    instr_valid_i,
    input  logic                         dispatched_i,
    input  disp_req_t [PipeWidth-1:0]    disp_req_i,
    input  phy_id_t   [PipeWidth-1:0]    phy_reg_rd_old_i,
    // Issue Inteface (Clear / Overwrite entries)
    input  logic        [NofAlus-1:0]    issue_alu_clr_req_valid_i,
    input  refcnt_req_t [NofAlus-1:0]    issue_alu_clr_req_i,
    input  logic        [NofLsus-1:0]    issue_lsu_clr_req_valid_i,
    input  refcnt_req_t [NofLsus-1:0]    issue_lsu_clr_req_i,
    input  logic        [NofFpus-1:0]    issue_fpu_clr_req_valid_i,
    input  refcnt_req_t [NofFpus-1:0]    issue_fpu_clr_req_i,
    // Allocation interface
    input  logic [$clog2(PipeWidth):0]   rename_gpr_count_i,
    input  logic [$clog2(PipeWidth):0]   rename_fpr_count_i,
    output phy_id_t [PipeWidth-1:0]      allocated_gpr_regs_o,
    output phy_id_t [PipeWidth-1:0]      allocated_fpr_regs_o,
    output logic                         phy_reg_alloc_ready_o
);

    // GPR Max References: 1 (RAT) + ALU(2/slot) + LSU(2/slot) + FPU(1/slot)
    localparam int unsigned GprMaxReferences = 1 
                                             + (NofAlus * AluNofRss * 2) 
                                             + (NofLsus * LsuNofRss * 2) 
                                             + (NofFpus * FpuNofRss * 1);
                                             
    // FPR Max References: 1 (RAT) + LSU(1/slot) + FPU(3/slot)
    localparam int unsigned FprMaxReferences = 1 
                                             + (NofLsus * LsuNofRss * 1) 
                                             + (NofFpus * FpuNofRss * 3);

    localparam int unsigned GprCntWidth = $clog2(GprMaxReferences + 1);
    localparam int unsigned FprCntWidth = $clog2(FprMaxReferences + 1);

    // We can have 2 src operands per instruction + 1 due to the RAT update
    localparam int unsigned NofGprIncSrcs = PipeWidth*3;
    // We can have 2 src operands per ALU and LSU, 1 for FPU and 1 for the old RAT entry
    localparam int unsigned NofGprDecSrcs = PipeWidth + (NofAlus*2) + (NofLsus*2) + NofFpus;

    // FPR has 3 src operands per instruction + 1 RAT update
    localparam int unsigned NofFprIncSrcs = PipeWidth*4;
    // FPR decrements: old RAT entry (Pipe), LSU op_b (1), FPU op_a/b/c (3)
    localparam int unsigned NofFprDecSrcs = PipeWidth + NofLsus + (NofFpus*3);


    typedef logic [GprCntWidth-1:0] gpr_cnt_t;
    typedef logic [FprCntWidth-1:0] fpr_cnt_t;

    localparam int unsigned GprIncWidth = $clog2(NofGprIncSrcs + 1);
    localparam int unsigned GprDecWidth = $clog2(NofGprDecSrcs + 1);
    localparam int unsigned FprIncWidth = $clog2(NofFprIncSrcs + 1);
    localparam int unsigned FprDecWidth = $clog2(NofFprDecSrcs + 1);

    // GPR One-Hot arrays
    logic [NofPhysGpr-1:0][PipeWidth-1:0] gpr_disp_rd_oh;
    logic [NofPhysGpr-1:0][PipeWidth-1:0] gpr_disp_rd_old_oh;
    logic [NofPhysGpr-1:0][PipeWidth-1:0] gpr_disp_rs1_oh;
    logic [NofPhysGpr-1:0][PipeWidth-1:0] gpr_disp_rs2_oh;
    logic [NofPhysGpr-1:0][NofAlus-1:0]   gpr_issue_alu_rs1_oh;
    logic [NofPhysGpr-1:0][NofAlus-1:0]   gpr_issue_alu_rs2_oh;
    logic [NofPhysGpr-1:0][NofLsus-1:0]   gpr_issue_lsu_rs1_oh;
    logic [NofPhysGpr-1:0][NofLsus-1:0]   gpr_issue_lsu_rs2_oh;
    logic [NofPhysGpr-1:0][NofFpus-1:0]   gpr_issue_fpu_rs1_oh;

    // FPR One-Hot arrays
    logic [NofPhysFpr-1:0][PipeWidth-1:0] fpr_disp_rd_oh;
    logic [NofPhysFpr-1:0][PipeWidth-1:0] fpr_disp_rd_old_oh;
    logic [NofPhysFpr-1:0][PipeWidth-1:0] fpr_disp_rs1_oh;
    logic [NofPhysFpr-1:0][PipeWidth-1:0] fpr_disp_rs2_oh;
    logic [NofPhysFpr-1:0][PipeWidth-1:0] fpr_disp_rs3_oh;
    logic [NofPhysFpr-1:0][NofLsus-1:0]   fpr_issue_lsu_rs2_oh;
    logic [NofPhysFpr-1:0][NofFpus-1:0]   fpr_issue_fpu_rs1_oh;
    logic [NofPhysFpr-1:0][NofFpus-1:0]   fpr_issue_fpu_rs2_oh;
    logic [NofPhysFpr-1:0][NofFpus-1:0]   fpr_issue_fpu_rs3_oh;

    // Flat vectors for the compressor trees
    logic [NofPhysGpr-1:0][NofGprIncSrcs-1:0] gpr_inc_vec;
    logic [NofPhysGpr-1:0][NofGprDecSrcs-1:0] gpr_dec_vec;
    logic [NofPhysFpr-1:0][NofFprIncSrcs-1:0] fpr_inc_vec;
    logic [NofPhysFpr-1:0][NofFprDecSrcs-1:0] fpr_dec_vec;


    // Storage arrays for the binary counters and allocated registers
    gpr_cnt_t [NofPhysGpr-1:0] gpr_counters_q, gpr_counters_d;
    fpr_cnt_t [NofPhysFpr-1:0] fpr_counters_q, fpr_counters_d;
    phy_id_t [PipeWidth-1:0] gpr_allocated_q, gpr_allocated_d;
    phy_id_t [PipeWidth-1:0] fpr_allocated_q, fpr_allocated_d;
    phy_id_t [PipeWidth-1:0] allocated_gpr_regs;
    phy_id_t [PipeWidth-1:0] allocated_fpr_regs;

    logic dispatch_started_d, dispatch_started_q;

    // Supporting up to PipeWidth increments per cycle
    logic [NofPhysGpr-1:0][GprIncWidth-1:0] gpr_inc;
    logic [NofPhysFpr-1:0][FprIncWidth-1:0] fpr_inc;
    // Total possible simultaneous clears across all reservation stations (RSs)
    logic [NofPhysGpr-1:0][GprDecWidth-1:0] gpr_dec;
    logic [NofPhysFpr-1:0][FprDecWidth-1:0] fpr_dec;


    // We have to update the counters for every dispatched instructions to track:
    // 1) The RAT reference, to make sure the logical register is not overwritten
    // in the future to avoid WAW and WAR
    // 2) All the sources that which to consume a current physical register to
    // avoid RAW hazard
    always_comb begin : counter_update
        // Default assignment
        gpr_disp_rd_oh = '0;
        gpr_disp_rd_old_oh = '0;
        gpr_disp_rs1_oh = '0;
        gpr_disp_rs2_oh = '0;
        gpr_issue_alu_rs1_oh = '0;
        gpr_issue_alu_rs2_oh = '0;
        gpr_issue_lsu_rs1_oh = '0;
        gpr_issue_lsu_rs2_oh = '0;
        gpr_issue_fpu_rs1_oh = '0;

        fpr_disp_rd_oh = '0;
        fpr_disp_rd_old_oh = '0;
        fpr_disp_rs1_oh = '0;
        fpr_disp_rs2_oh = '0;
        fpr_disp_rs3_oh = '0;
        fpr_issue_lsu_rs2_oh = '0;
        fpr_issue_fpu_rs1_oh = '0;
        fpr_issue_fpu_rs2_oh = '0;
        fpr_issue_fpu_rs3_oh = '0;

        // Generate the onehot encoding for the dispatch reference updates
        for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
            if (instr_exec_commit_superscalar_i && instr_valid_i[instr_idx] && !dispatch_started_q) begin
                // GPR dispatch updates
                // Update the reference for the new RAT entry if destination is GPR
                if (!disp_req_i[instr_idx].tag.dest_reg_is_fp) begin
                    if (disp_req_i[instr_idx].tag.dest_reg != '0) begin
                        gpr_disp_rd_oh[disp_req_i[instr_idx].tag.dest_reg][instr_idx] = 1'b1;
                    end
                    if (phy_reg_rd_old_i[instr_idx] != '0) begin
                        gpr_disp_rd_old_oh[phy_reg_rd_old_i[instr_idx]][instr_idx] = 1'b1;
                    end
                end
                // Update the source register references for GPR sources
                if (!disp_req_i[instr_idx].is_op_a_valid       &&
                    !disp_req_i[instr_idx].is_op_a_fp          &&
                    (disp_req_i[instr_idx].phy_reg_op_a != '0)) begin
                    gpr_disp_rs1_oh[disp_req_i[instr_idx].phy_reg_op_a][instr_idx] = 1'b1;
                end
                if (!disp_req_i[instr_idx].is_op_b_valid       &&
                    !disp_req_i[instr_idx].is_op_b_fp          &&
                    (disp_req_i[instr_idx].phy_reg_op_b != '0)) begin
                    gpr_disp_rs2_oh[disp_req_i[instr_idx].phy_reg_op_b][instr_idx] = 1'b1;
                end

                // Update the reference for the new RAT entry if destination is FPR
                if (disp_req_i[instr_idx].tag.dest_reg_is_fp) begin
                    fpr_disp_rd_oh[disp_req_i[instr_idx].tag.dest_reg][instr_idx] = 1'b1;
                    fpr_disp_rd_old_oh[phy_reg_rd_old_i[instr_idx]][instr_idx] = 1'b1;
                end
                // Update the source register references for FPR sources
                if (disp_req_i[instr_idx].is_op_a_fp) begin
                    fpr_disp_rs1_oh[disp_req_i[instr_idx].phy_reg_op_a][instr_idx] = 1'b1;
                end
                if (disp_req_i[instr_idx].is_op_b_fp) begin
                    fpr_disp_rs2_oh[disp_req_i[instr_idx].phy_reg_op_b][instr_idx] = 1'b1;
                end
                if (!disp_req_i[instr_idx].is_op_c_valid) begin
                    fpr_disp_rs3_oh[disp_req_i[instr_idx].phy_reg_op_c][instr_idx] = 1'b1;
                end                
            end
        end

        // Geneate the onehot encoding for the issue reference updates
        for (int unsigned alu = 0; alu < NofAlus; alu++) begin
            if (issue_alu_clr_req_valid_i[alu]) begin
                if (!issue_alu_clr_req_i[alu].is_op_a_cnst && 
                    issue_alu_clr_req_i[alu].phy_reg_op_a != '0) begin
                    gpr_issue_alu_rs1_oh[issue_alu_clr_req_i[alu].phy_reg_op_a][alu] = 1'b1;
                end
                if (!issue_alu_clr_req_i[alu].is_op_b_cnst &&
                    issue_alu_clr_req_i[alu].phy_reg_op_b != '0) begin
                    gpr_issue_alu_rs2_oh[issue_alu_clr_req_i[alu].phy_reg_op_b][alu] = 1'b1;
                end
            end
        end

        for (int unsigned lsu = 0; lsu < NofLsus; lsu++) begin
            if (issue_lsu_clr_req_valid_i[lsu]) begin
                // GPRs
                if (issue_lsu_clr_req_i[lsu].phy_reg_op_a != '0) begin
                    gpr_issue_lsu_rs1_oh[issue_lsu_clr_req_i[lsu].phy_reg_op_a][lsu] = 1'b1;
                end
                if (!issue_lsu_clr_req_i[lsu].is_op_b_fp &&
                    issue_lsu_clr_req_i[lsu].phy_reg_op_b != '0) begin
                    gpr_issue_lsu_rs2_oh[issue_lsu_clr_req_i[lsu].phy_reg_op_b][lsu] = 1'b1;
                end
                // FPRs
                if (issue_lsu_clr_req_i[lsu].is_op_b_fp) begin
                    // There is only one potential source operands for an LSU instruction
                    // that targets the FPR
                    fpr_issue_lsu_rs2_oh[issue_lsu_clr_req_i[lsu].phy_reg_op_b][lsu] = 1'b1;
                end
            end
        end

        for (int unsigned fpu = 0; fpu < NofFpus; fpu++) begin
            if (issue_fpu_clr_req_valid_i[fpu]) begin
                // GPR
                if (!issue_fpu_clr_req_i[fpu].is_op_a_fp &&
                    issue_fpu_clr_req_i[fpu].phy_reg_op_a != '0) begin
                    gpr_issue_fpu_rs1_oh[issue_fpu_clr_req_i[fpu].phy_reg_op_a][fpu] = 1'b1;
                end
                // FPR
                if (issue_fpu_clr_req_i[fpu].is_op_a_fp) begin
                    fpr_issue_fpu_rs1_oh[issue_fpu_clr_req_i[fpu].phy_reg_op_a][fpu] = 1'b1;
                end
                // op_b always FPR
                fpr_issue_fpu_rs2_oh[issue_fpu_clr_req_i[fpu].phy_reg_op_b][fpu] = 1'b1; 
                
                if (!issue_fpu_clr_req_i[fpu].is_op_c_cnst) begin
                    fpr_issue_fpu_rs3_oh[issue_fpu_clr_req_i[fpu].phy_reg_op_c][fpu] = 1'b1;
                end
            end
        end

        // POPCOUNT / COMPRESSOR TREES
        for (int unsigned gpr = 0; gpr < NofPhysGpr; gpr++) begin
            // Concatenate all 1-bit wires into flat arrays
            gpr_inc_vec[gpr] = {gpr_disp_rd_oh[gpr], gpr_disp_rs1_oh[gpr], gpr_disp_rs2_oh[gpr]};
            gpr_dec_vec[gpr] = {gpr_disp_rd_old_oh[gpr], gpr_issue_alu_rs1_oh[gpr], 
                                gpr_issue_alu_rs2_oh[gpr], gpr_issue_lsu_rs1_oh[gpr], 
                                gpr_issue_lsu_rs2_oh[gpr], gpr_issue_fpu_rs1_oh[gpr]};

            // Compressor trees (synthesizer automatically implements wallace trees for these loops)
            gpr_inc[gpr] = '0;
            for (int i = 0; i < NofGprIncSrcs; i++) begin
                gpr_inc[gpr] += GprIncWidth'(gpr_inc_vec[gpr][i]);
            end

            gpr_dec[gpr] = '0;
            for (int i = 0; i < NofGprDecSrcs; i++) begin
                gpr_dec[gpr] += GprDecWidth'(gpr_dec_vec[gpr][i]);
            end
        end

        for (int unsigned fpr = 0; fpr < NofPhysFpr; fpr++) begin
            // Concatenate FPR wires
            fpr_inc_vec[fpr] = {fpr_disp_rd_oh[fpr], fpr_disp_rs1_oh[fpr], 
                                fpr_disp_rs2_oh[fpr], fpr_disp_rs3_oh[fpr]};
            fpr_dec_vec[fpr] = {fpr_disp_rd_old_oh[fpr], fpr_issue_lsu_rs2_oh[fpr], 
                                fpr_issue_fpu_rs1_oh[fpr], fpr_issue_fpu_rs2_oh[fpr], 
                                fpr_issue_fpu_rs3_oh[fpr]};

            fpr_inc[fpr] = '0;
            for (int i = 0; i < NofFprIncSrcs; i++) begin
                fpr_inc[fpr] += FprIncWidth'(fpr_inc_vec[fpr][i]);
            end

            fpr_dec[fpr] = '0;
            for (int i = 0; i < NofFprDecSrcs; i++) begin
                fpr_dec[fpr] += FprDecWidth'(fpr_dec_vec[fpr][i]);
            end
        end
    end


    // Counter next state logic
    always_comb begin : next_state_logic
        gpr_allocated_d = gpr_allocated_q;
        fpr_allocated_d = fpr_allocated_q;
        gpr_counters_d = gpr_counters_q;
        fpr_counters_d = fpr_counters_q;
        dispatch_started_d = dispatch_started_q;

        // Allocated register next state logic
        if (instr_exec_commit_superscalar_i && !dispatch_started_q) begin
            dispatch_started_d = 1'b1;
            // If the first instruction was dispatched we have to remember the registers we had allocated in this
            // cycle. Reason being is that in a multicycle dispatch we have to still hold these values
            // so that the rename stage does not change the register map.
            gpr_allocated_d = allocated_gpr_regs;
            fpr_allocated_d = allocated_fpr_regs;
        end

        if (dispatched_i) begin
            dispatch_started_d = 1'b0;
        end

        // Counter next state logic
        // Apply the net delta changes via parallel multi-bit arithmetic
        for (int unsigned i = 0; i < NofPhysGpr; i++) begin
            gpr_counters_d[i] = gpr_counters_q[i] + gpr_inc[i] - gpr_dec[i];
        end

        for (int unsigned i = 0; i < NofPhysFpr; i++) begin
            fpr_counters_d[i] = fpr_counters_q[i] + fpr_inc[i] - fpr_dec[i];
        end

    end

    always_ff @(posedge clk_i or posedge rst_i) begin : state_holding_element
        if (rst_i) begin
            dispatch_started_q <= 1'b0;
            for (int unsigned i = 0; i < PipeWidth; i++) begin
                gpr_allocated_q[i] <= phy_id_t'(i + 32);
                fpr_allocated_q[i] <= phy_id_t'(i + 32);
            end
            // Bootstrap state: Initial architecturally active registers get a reference count of 1
            for (int unsigned i = 0; i < NofPhysGpr; i++) begin
                gpr_counters_q[i] <= (i < 32) ? gpr_cnt_t'(1) : '0;
            end
            for (int unsigned i = 0; i < NofPhysFpr; i++) begin
                fpr_counters_q[i] <= (i < 32) ? fpr_cnt_t'(1) : '0;
            end
        end else begin
            dispatch_started_q <= dispatch_started_d;
            gpr_allocated_q <= gpr_allocated_d;
            fpr_allocated_q <= fpr_allocated_d;
            gpr_counters_q <= gpr_counters_d;
            fpr_counters_q <= fpr_counters_d;
        end
    end

    // Free vector calculation and allocation ready signaling
    // The free vector contains a bit for every physical register
    // This bit is set when the counter of the physical register is zero (no active references to it)
    logic [NofPhysGpr-1:0] gpr_free_vector;
    logic [NofPhysFpr-1:0] fpr_free_vector;
    logic [$clog2(NofPhysGpr+1)-1:0] gpr_free_count;
    logic [$clog2(NofPhysFpr+1)-1:0] fpr_free_count;
    logic phy_gpr_alloc_ready, phy_fpr_alloc_ready;

    always_comb begin : free_vector_calc
        for (int unsigned i = 0; i < NofPhysGpr; i++) begin
            gpr_free_vector[i] = (gpr_counters_q[i] == '0);
        end
        for (int unsigned i = 0; i < NofPhysFpr; i++) begin
            fpr_free_vector[i] = (fpr_counters_q[i] == '0);
        end
    end

    popcount #(
        .INPUT_WIDTH(NofPhysGpr)
    ) i_gpr_free_count (
        .data_i(gpr_free_vector),
        .popcount_o(gpr_free_count)
    );

    popcount #(
        .INPUT_WIDTH(NofPhysFpr)
    ) i_fpr_free_count (
        .data_i(fpr_free_vector),
        .popcount_o(fpr_free_count)
    );

    assign phy_gpr_alloc_ready = gpr_free_count >= rename_gpr_count_i;
    assign phy_fpr_alloc_ready = fpr_free_count >= rename_fpr_count_i;

    assign phy_reg_alloc_ready_o = phy_gpr_alloc_ready && phy_fpr_alloc_ready;

    // Allocation based on priority encoder
    logic [NofPhysGpr-1:0] gpr_mask;
    logic [NofPhysFpr-1:0] fpr_mask;

    logic [PipeWidth-1:0] found_gpr_reg, found_fpr_reg;
    always_comb begin : priority_encoder
        // Default assignments
        gpr_mask = gpr_free_vector;
        fpr_mask = fpr_free_vector;
        // No valid register is assigned
        allocated_gpr_regs = '0;
        allocated_fpr_regs = '0;
        found_gpr_reg = '0;
        found_fpr_reg = '0;

        // Allocate GPRs
        for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
            if ((gpr_mask != '0) && (instr_idx < rename_gpr_count_i)) begin
                for (int unsigned gpr = 0; gpr < NofPhysGpr; gpr++) begin
                    if (gpr_mask[gpr] && !found_gpr_reg[instr_idx]) begin
                        // Found the first free register
                        allocated_gpr_regs[instr_idx] = phy_id_t'(gpr);
                        // Mask this register so that other instruction will not take it
                        gpr_mask[gpr]             = 1'b0; 
                        // Signal that we already have free register for this instruction
                        found_gpr_reg[instr_idx] = 1'b1;
                    end
                end
            end

            if ((fpr_mask != '0) && (instr_idx < rename_fpr_count_i)) begin
                for (int unsigned reg_idx = 0; reg_idx < NofPhysFpr; reg_idx++) begin
                    if (fpr_mask[reg_idx]  && !found_fpr_reg[instr_idx]) begin
                        // Found the first free register
                        allocated_fpr_regs[instr_idx] = phy_id_t'(reg_idx);
                        // Mask this register so that other instruction will not take it
                        fpr_mask[reg_idx]             = 1'b0;
                        // Signal that we already have free register for this instruction
                        found_fpr_reg[instr_idx] = 1'b1;
                    end
                end
            end
        end
    end

    assign allocated_gpr_regs_o = dispatch_started_q ? gpr_allocated_q : allocated_gpr_regs;
    assign allocated_fpr_regs_o = dispatch_started_q ? fpr_allocated_q : allocated_fpr_regs;

endmodule
