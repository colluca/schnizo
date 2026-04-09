// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Note: The physical register size has to be a power of two, for the math to work

// Author: Stefan Odermatt <soderma@ethz.ch>
module schnova_free_list import schnova_pkg::*; #(
  parameter int unsigned PipeWidth   = 1,
  parameter int unsigned PhysAddrWidth = 6,
  parameter int unsigned AddrWidth = 5,
  parameter type         phy_id_t = logic
) (
  input  logic         clk_i,
  input  logic         rst_i,
  // Allocation Interface (Rename Stage)
  input logic pop_i,
  output logic freelist_ready_o,
  input logic [$clog2(PipeWidth):0] pop_count_i,
  output phy_id_t [PipeWidth-1:0]  allocated_regs_o,
  // Deallocation Interface (Retire/Commit Stage)
  input logic push_i,
  input logic [$clog2(PipeWidth):0] push_count_i,
  input phy_id_t [PipeWidth-1:0] retired_regs_i
);
  // Connections and registers
  localparam int unsigned NumPhysRegs  = 2**PhysAddrWidth;
  localparam int unsigned NumRegs  = 2**AddrWidth;

  phy_id_t [NumPhysRegs-1:0] free_list;
  logic [PhysAddrWidth:0] head_ptr_raw, tail_ptr_raw; // Extra bit for wrap-around/full detection
  logic [PhysAddrWidth-1:0] head_ptr, tail_ptr; // Extra bit for wrap-around/full detection

  // Calculate the current number of free physical registers
  logic [$clog2(NumPhysRegs):0] free_count;

  assign free_count = tail_ptr_raw - head_ptr_raw;
  assign freelist_ready_o = (free_count >= pop_count_i);

  assign head_ptr = head_ptr_raw[PhysAddrWidth-1:0];
  assign tail_ptr = tail_ptr_raw[PhysAddrWidth-1:0];

  // Allocation, we pop free entries from the free list
  always_comb begin
    allocated_regs_o = '0;
    for (int i = 0; i < PipeWidth; i++) begin
      if (i < pop_count_i) begin
        allocated_regs_o[i] = free_list[(head_ptr+i)%NumPhysRegs];
      end
    end
  end

  // Sequential updates, that includes pointer calculations and retirements
  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      head_ptr_raw <= '0;
      // At the beginning all architectural registers are mapped
      // that means 32 registers are mapped
      tail_ptr_raw <= NumPhysRegs - NumRegs;
      for (int unsigned i = 0; i < NumPhysRegs; i++) begin
        if (i < (NumPhysRegs-NumRegs)) begin
          free_list[i] <= phy_id_t'(i + 32);
        end else begin
          free_list[i] <= '0;
        end
      end
    end else begin
      // Update the head pointer on allocation
      if(pop_i && freelist_ready_o) begin
        head_ptr_raw <= head_ptr_raw + pop_count_i;
      end

      // Update tail on retirement
      if (push_i) begin
        for (int i = 0; i < PipeWidth; i++) begin
          if (i < push_count_i) begin
            free_list[(tail_ptr+i)%NumPhysRegs] <= retired_regs_i[i];
          end
        end
        tail_ptr_raw <= tail_ptr_raw + push_count_i;
      end
      end
  end

endmodule
