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
    // Whether all the instructions of the fetch block are dispatched in this cycle
    // only asserted if in superscalar mode
    input  logic                         first_instr_dispatched_i,
    input  logic                         multi_cycle_dispatch_i,
    input  logic      [PipeWidth-1:0]    disp_set_req_valid_i,
    input  disp_req_t [PipeWidth-1:0]    disp_req_i,
    input  phy_id_t   [PipeWidth-1:0]    phy_reg_rd_old_i,
    input  logic      [PipeWidth-1:0]    phy_reg_rd_is_fp_i,
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

    // Local parameters and types
    localparam int unsigned TotalNofRsSlots = (NofAlus * AluNofRss) + (NofLsus * LsuNofRss) + (NofFpus * FpuNofRss);
    localparam int unsigned MaxReferences = 1 + TotalNofRsSlots; // +1 for RAT reference
    localparam int unsigned CntWidth = $clog2(MaxReferences + 1);

    // We can have 2 src operands per instruction + 1 due to the RAT update
    localparam int unsigned GprIncWidth = $clog2(PipeWidth*2+1 + 1);
    // We can have 3 src operands per instruction + 1 due to the RAT update
    localparam int unsigned FprIncWidth = $clog2(PipeWidth*3+1 + 1);
    // We can have a decrement from each reservation station and for each instruction
    localparam int unsigned DecWidth = $clog2(NofAlus+NofLsus+NofFpus + PipeWidth + 1);

    typedef logic [CntWidth-1:0] cnt_t;

    // Storage arrays for the binary counters and allocated registers
    cnt_t [NofPhysGpr-1:0] gpr_counters_q, gpr_counters_d;
    cnt_t [NofPhysFpr-1:0] fpr_counters_q, fpr_counters_d;
    phy_id_t [PipeWidth-1:0] gpr_allocated_q, gpr_allocated_d;
    phy_id_t [PipeWidth-1:0] fpr_allocated_q, fpr_allocated_d;
    phy_id_t [PipeWidth-1:0] allocated_gpr_regs;
    phy_id_t [PipeWidth-1:0] allocated_fpr_regs;

    // Supporting up to PipeWidth increments per cycle
    logic [NofPhysGpr-1:0][GprIncWidth-1:0] gpr_inc;
    logic [NofPhysFpr-1:0][FprIncWidth-1:0] fpr_inc;
    // Total possible simultaneous clears across all reservation stations (RSs)
    logic [NofPhysGpr-1:0][DecWidth-1:0] gpr_dec;
    logic [NofPhysFpr-1:0][DecWidth-1:0] fpr_dec;


    // We have to update the counters for every dispatched instructions to track:
    // 1) The RAT reference, to make sure the logical register is not overwritten
    // in the future to avoid WAW and WAR
    // 2) All the sources that which to consume a current physical register to
    // avoid RAW hazard
    always_comb begin : counter_update
        // Check  every phyiscal register if it needs to update its counter
        for (int unsigned gpr = 0; gpr < NofPhysGpr; gpr++) begin
            gpr_inc[gpr] = '0;
            gpr_dec[gpr] = '0;

            // Generate the decoder structure that perform the counter updates for the GPR
            for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
                if (disp_set_req_valid_i[instr_idx]) begin
                    // Update the reference for the new RAT entry
                    if (!phy_reg_rd_is_fp_i[instr_idx]             &&
                        (disp_req_i[instr_idx].phy_reg_dest != '0) &&
                        (disp_req_i[instr_idx].phy_reg_dest == phy_id_t'(gpr))) begin
                        gpr_inc[gpr] += 1'b1;
                    end
                    // Clear the reference for the old RAT entry
                    if (!phy_reg_rd_is_fp_i[instr_idx]      &&
                        (phy_reg_rd_old_i[instr_idx] != '0) &&
                        (phy_reg_rd_old_i[instr_idx] == phy_id_t'(gpr))) begin
                        gpr_dec[gpr] += 1'b1;
                    end
                    // Update the reference for all the source registers
                    // Note if the operand is not valid at the dispatch request this operand will be fetched from the physical register
                    // otherwise it would be a constant/immediate.
                    if (!disp_req_i[instr_idx].is_op_a_valid       &&
                        !disp_req_i[instr_idx].is_op_a_fp          &&
                        (disp_req_i[instr_idx].phy_reg_op_a != '0) &&
                        (disp_req_i[instr_idx].phy_reg_op_a == phy_id_t'(gpr))) begin
                        gpr_inc[gpr] += 1'b1;
                    end
                    if (!disp_req_i[instr_idx].is_op_b_valid       &&
                        !disp_req_i[instr_idx].is_op_b_fp          &&
                        (disp_req_i[instr_idx].phy_reg_op_b != '0) &&
                        (disp_req_i[instr_idx].phy_reg_op_b == phy_id_t'(gpr))) begin
                        gpr_inc[gpr] += 1'b1;
                    end
                end
            end

            // Decrement the reference counter for every issued instruction from any reservation station
            for (int unsigned alu = 0; alu < NofAlus; alu++) begin
                if (issue_alu_clr_req_valid_i[alu]) begin
                    // There are two potential source operands for an ALU instruction
                    if (!issue_alu_clr_req_i[alu].is_op_a_cnst      &&
                        issue_alu_clr_req_i[alu].phy_reg_op_a != '0 &&
                        issue_alu_clr_req_i[alu].phy_reg_op_a == phy_id_t'(gpr)) begin
                            gpr_dec[gpr] += 1'b1;
                    end
                    if (!issue_alu_clr_req_i[alu].is_op_b_cnst      &&
                        issue_alu_clr_req_i[alu].phy_reg_op_b != '0 &&
                        issue_alu_clr_req_i[alu].phy_reg_op_b == phy_id_t'(gpr)) begin
                            gpr_dec[gpr] += 1'b1;
                    end
                end
            end

            for (int unsigned lsu = 0; lsu < NofLsus; lsu++) begin
                if (issue_lsu_clr_req_valid_i[lsu]) begin
                    // There are two potential source operands for an LSU instruction
                    // OP a always has to target the GPR
                    if (issue_lsu_clr_req_i[lsu].phy_reg_op_a != '0 &&
                        issue_lsu_clr_req_i[lsu].phy_reg_op_a == phy_id_t'(gpr)) begin
                        gpr_dec[gpr] += 1'b1; 
                    end
                    if (!issue_lsu_clr_req_i[lsu].is_op_b_fp &&
                        issue_lsu_clr_req_i[lsu].phy_reg_op_b != '0 &&
                        issue_lsu_clr_req_i[lsu].phy_reg_op_b == phy_id_t'(gpr)) begin
                        gpr_dec[gpr] += 1'b1; 
                    end
                end
            end

            for (int unsigned fpu = 0; fpu < NofFpus; fpu++) begin
                if (issue_fpu_clr_req_valid_i[fpu]) begin
                    // There are three potential source operands for an FPU instruction
                    if (!issue_fpu_clr_req_i[fpu].is_op_a_fp &&
                        issue_fpu_clr_req_i[fpu].phy_reg_op_a != '0 &&
                        issue_fpu_clr_req_i[fpu].phy_reg_op_a == phy_id_t'(gpr)) begin
                        gpr_dec[gpr] += 1'b1; 
                    end
                end
            end
        end

        // Generate the decoder structure that perform the counter updates for the FPR
        for (int unsigned fpr = 0; fpr < NofPhysFpr; fpr++) begin
            fpr_inc[fpr] = '0;
            fpr_dec[fpr] = '0;

            for (int unsigned instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
                if (disp_set_req_valid_i[instr_idx]) begin
                    if (phy_reg_rd_is_fp_i[instr_idx] && (disp_req_i[instr_idx].phy_reg_dest == phy_id_t'(fpr))) begin
                        // Update the reference for the new RAT entry
                        fpr_inc[fpr] += 1'b1;
                    end
                    if (phy_reg_rd_is_fp_i[instr_idx] && (phy_reg_rd_old_i[instr_idx] == phy_id_t'(fpr))) begin
                        // Clear the reference for the old RAT entry
                        fpr_dec[fpr] += 1'b1;
                    end
                    // Update the reference for all the source registers
                    // Note if the operand is not valid at the dispatch request this operand will be fetched from the physical register
                    // otherwise it would be a constant/immediate.
                    if (!disp_req_i[instr_idx].is_op_a_valid && 
                        disp_req_i[instr_idx].is_op_a_fp     && 
                        (disp_req_i[instr_idx].phy_reg_op_a == phy_id_t'(fpr))) begin
                        fpr_inc[fpr] += 1'b1;
                    end
                    if (!disp_req_i[instr_idx].is_op_b_valid &&
                        disp_req_i[instr_idx].is_op_b_fp     &&
                        (disp_req_i[instr_idx].phy_reg_op_b == phy_id_t'(fpr))) begin
                        fpr_inc[fpr] += 1'b1;
                    end
                    if (!disp_req_i[instr_idx].is_op_c_valid &&
                        (disp_req_i[instr_idx].phy_reg_op_c == phy_id_t'(fpr))) begin
                        fpr_inc[fpr] += 1'b1;
                    end
                end
            end

            // Decrement the reference counter for every issued instruction from any reservation station
            for (int unsigned lsu = 0; lsu < NofLsus; lsu++) begin
                if (issue_lsu_clr_req_valid_i[lsu]) begin
                    // There is only one potential source operands for an LSU instruction
                    // that targets the FPR
                    if (issue_lsu_clr_req_i[lsu].is_op_b_fp &&
                        (issue_lsu_clr_req_i[lsu].phy_reg_op_b == phy_id_t'(fpr))) begin
                        fpr_dec[fpr] += 1'b1;
                    end
                end
            end

            for (int unsigned fpu = 0; fpu < NofFpus; fpu++) begin
                // There are three potential source operands for an FPU instruction
                if (issue_fpu_clr_req_valid_i[fpu]) begin
                    if (issue_fpu_clr_req_i[fpu].is_op_a_fp && 
                        (issue_fpu_clr_req_i[fpu].phy_reg_op_a == phy_id_t'(fpr))) begin
                        fpr_dec[fpr] += 1'b1;
                    end
                    // Operand b and c always target the FPR
                    if ((issue_fpu_clr_req_i[fpu].phy_reg_op_b == phy_id_t'(fpr))) begin
                        fpr_dec[fpr] += 1'b1;
                    end
                    if (!issue_fpu_clr_req_i[fpu].is_op_c_cnst &&
                        (issue_fpu_clr_req_i[fpu].phy_reg_op_c == phy_id_t'(fpr))) begin
                        fpr_dec[fpr] += 1'b1;
                    end
                end
            end
        end
    end

    // Counter next state logic
    always_comb begin : next_state_logic
        gpr_allocated_d = gpr_allocated_q;
        fpr_allocated_d = fpr_allocated_q;
        gpr_counters_d = gpr_counters_q;
        fpr_counters_d = fpr_counters_q;

        // Allocated register next state logic
        if (first_instr_dispatched_i) begin
            // If the first instruction was dispatch we have to rember the registers we had allocated in this
            // cycle. Reason being is that in a multicycle dispatch we have to still hold these values
            // so that the rename stage does not change the register map.
            gpr_allocated_d = allocated_gpr_regs;
            fpr_allocated_d = allocated_fpr_regs;
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
            for (int unsigned i = 0; i < PipeWidth; i++) begin
                gpr_allocated_q[i] <= phy_id_t'(i + 32);
                fpr_allocated_q[i] <= phy_id_t'(i + 32);
            end
            // Bootstrap state: Initial architecturally active registers get a reference count of 1
            for (int unsigned i = 0; i < NofPhysGpr; i++) begin
                gpr_counters_q[i] <= (i < 32) ? cnt_t'(1) : '0;
            end
            for (int unsigned i = 0; i < NofPhysFpr; i++) begin
                fpr_counters_q[i] <= (i < 32) ? cnt_t'(1) : '0;
            end
        end else begin
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

    assign allocated_gpr_regs_o = multi_cycle_dispatch_i ? gpr_allocated_q : allocated_gpr_regs;
    assign allocated_fpr_regs_o = multi_cycle_dispatch_i ? fpr_allocated_q : allocated_fpr_regs;

endmodule
