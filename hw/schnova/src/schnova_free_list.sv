// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Stefan Odermatt <soderma@ethz.ch>

// The FIFO free list. Used if a reorder buffer is used
// to reclaim physical registers.
// Can pop PipeWidth physical registers per cycle and push PipeWidth physical registers per cycle.
module schnova_free_list import schnova_pkg::*; #(
  parameter int unsigned PipeWidth   = 1,
  parameter int unsigned NumPhysRegs = 64,
  parameter int unsigned NumArchRegs = 32,
  parameter type         phy_id_t    = logic
) (
  input  logic                         clk_i,
  input  logic                         rst_i,
  // Allocation Interface (Rename)
  input  logic                         pop_i,
  input  logic [$clog2(PipeWidth):0]   pop_count_i,
  output logic                         freelist_ready_o,
  output phy_id_t [PipeWidth-1:0]      allocated_regs_o,
  // Deallocation Interface (Retire)
  input  logic                         push_i,
  input  logic [$clog2(PipeWidth):0]   push_count_i,
  input  phy_id_t [PipeWidth-1:0]      retired_regs_i
);

  localparam int unsigned PhysIdxWidth = $clog2(NumPhysRegs);

  // Pointers and Occupancy
  logic [PhysIdxWidth-1:0] head_ptr, tail_ptr;
  logic [$clog2(NumPhysRegs):0] free_count;
  logic [PipeWidth-1:0][PhysIdxWidth:0] tmp_read_idx;
  logic [PipeWidth-1:0][PhysIdxWidth:0] tmp_write_idx;

  // Pointers and Count update
  logic [$clog2(PipeWidth):0] actual_pop;
  logic [$clog2(PipeWidth):0] actual_push;
  logic [PhysIdxWidth:0]      next_head_ext;
  logic [PhysIdxWidth:0]      next_tail_ext;

  // The actual storage
  phy_id_t [NumPhysRegs-1:0] free_list;

  assign freelist_ready_o = (free_count >= pop_count_i);

  assign actual_pop  = (pop_i && freelist_ready_o) ? pop_count_i : '0;
  assign actual_push = (push_i) ? push_count_i : '0;

  // Pointer look-ahead
  assign next_head_ext = {1'b0, head_ptr} + actual_pop;
  assign next_tail_ext = {1'b0, tail_ptr} + actual_push;

  // Combinational indexing for multi-port access
  always_comb begin
    allocated_regs_o = '0;
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      // Calculate indices with explicit width
      tmp_read_idx[i]  = {1'b0, head_ptr} + PhysIdxWidth'(i);
      tmp_write_idx[i] = {1'b0, tail_ptr} + PhysIdxWidth'(i);

      // Explicit Wrap-around check
      if (tmp_read_idx[i] >= NumPhysRegs[PhysIdxWidth:0]) begin
        tmp_read_idx[i] = tmp_read_idx[i] - NumPhysRegs[PhysIdxWidth:0];
      end
      if (tmp_write_idx[i] >= NumPhysRegs[PhysIdxWidth:0]) begin
        tmp_write_idx[i] = tmp_write_idx[i] - NumPhysRegs[PhysIdxWidth:0];
      end

      // Assign to output
      if (i < pop_count_i) begin
        allocated_regs_o[i] = free_list[tmp_read_idx[i][PhysIdxWidth-1:0]];
      end
    end
  end

  // Sequential Update
  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      head_ptr   <= '0;
      tail_ptr   <= (NumPhysRegs - NumArchRegs);
      free_count <= (NumPhysRegs - NumArchRegs);

      // All registers not mapped to architectural registers are initially free
      for (int unsigned i = 0; i < NumPhysRegs; i++) begin
        if (i < (NumPhysRegs - NumArchRegs)) begin
          free_list[i] <= phy_id_t'(i + NumArchRegs);
        end else begin
          free_list[i] <= '0;
        end
      end
    end else begin
      // Update Head
      if (actual_pop > 0) begin
        if (next_head_ext >= NumPhysRegs[PhysIdxWidth:0]) begin
          head_ptr <= next_head_ext[PhysIdxWidth-1:0] - NumPhysRegs[PhysIdxWidth-1:0];
        end else begin
          head_ptr <= next_head_ext[PhysIdxWidth-1:0];
        end
      end

      // Update Tail and Data
      if (actual_push > 0) begin
        for (int unsigned i = 0; i < PipeWidth; i++) begin
          if (i < actual_push) begin
            free_list[tmp_write_idx[i][PhysIdxWidth-1:0]] <= retired_regs_i[i];
          end
        end

        if (next_tail_ext >= NumPhysRegs[PhysIdxWidth:0]) begin
          tail_ptr <= next_tail_ext[PhysIdxWidth-1:0] - NumPhysRegs[PhysIdxWidth-1:0];
        end else begin
          tail_ptr <= next_tail_ext[PhysIdxWidth-1:0];
        end
      end

      // Occupancy update
      free_count <= free_count + actual_push - actual_pop;
    end
  end

endmodule
