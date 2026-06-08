// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Combined VFU + VSLDU execution unit for Schnizo.
//
// Wraps one spatz_vfu (arithmetic/FP) and one spatz_vsldu (slide) so that
// the pair presents a single spatz_vfu-compatible request/response interface.
// Slide instructions (ex_unit == SLD) are routed to the VSLDU; all others go
// to the VFU.  The two sub-units are mutually exclusive: a dispatch to either
// side is blocked while the other is in-flight.
//
// VRF port layout (indices relative to this module's arrays):
//   Write [0] = VFU  (VFU_VD_WD)
//   Write [1] = VSLDU (VSLDU_VD_WD)
//   Read  [2:0] = VFU  (vs2=0, vs1=1, vd=2)
//   Read  [3]   = VSLDU (VSLDU_VS2_RD)

`include "common_cells/registers.svh"

module schnizo_vfu_unit import spatz_pkg::*, rvv_pkg::*, fpnew_pkg::*; #(
  parameter fpu_implementation_t FPUImplementation = fpu_implementation_t'(0)
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic [31:0]      hart_id_i,

  // Unified request - accepts VFU ops and SLD (slide) ops
  input  spatz_req_t       spatz_req_i,
  input  logic             spatz_req_valid_i,
  output logic             spatz_req_ready_o,

  // VFU-style response (VSLDU ops produce no scalar writeback; wb=0, result='0)
  output logic             vfu_rsp_valid_o,
  input  logic             vfu_rsp_ready_i,
  output vfu_rsp_t         vfu_rsp_o,

  // VRF write ports: [0]=VFU, [1]=VSLDU
  output vrf_addr_t  [1:0] vrf_waddr_o,
  output vrf_data_t  [1:0] vrf_wdata_o,
  output logic       [1:0] vrf_we_o,
  output vrf_be_t    [1:0] vrf_wbe_o,
  input  logic       [1:0] vrf_wvalid_i,

  // VRF read ports: [2:0]=VFU (vs2/vs1/vd), [3]=VSLDU (vs2)
  output vrf_addr_t  [3:0] vrf_raddr_o,
  output logic       [3:0] vrf_re_o,
  input  vrf_data_t  [3:0] vrf_rdata_i,
  input  logic       [3:0] vrf_rvalid_i,

  output status_t          fpu_status_o,
  output logic             vfu_req_first_o
);

  // Route SLD ops to VSLDU, everything else to VFU.
  logic is_sld;
  assign is_sld = (spatz_req_i.ex_unit == SLD);

  // ---- Internal VFU signals ----
  logic    vfu_req_valid, vfu_req_ready;
  logic    vfu_rsp_valid;
  vfu_rsp_t vfu_rsp;

  // ---- Internal VSLDU signals ----
  logic     vsldu_req_valid, vsldu_req_ready;
  logic     vsldu_rsp_valid;
  vsldu_rsp_t vsldu_rsp;

  // Latch the one-shot VSLDU response until the downstream consumer acknowledges.
  logic vsldu_result_valid_q;

  // ---- Mutual exclusion ----
  // Each side is blocked while the other is busy or has a pending result.
  logic vfu_busy, vsldu_busy;
  assign vfu_busy   = ~vfu_req_ready;
  assign vsldu_busy = ~vsldu_req_ready || vsldu_result_valid_q;

  assign vfu_req_valid   = spatz_req_valid_i && !is_sld && !vsldu_busy;
  assign vsldu_req_valid = spatz_req_valid_i &&  is_sld && !vfu_busy && !vsldu_result_valid_q;

  assign spatz_req_ready_o = is_sld ? (vsldu_req_ready && !vfu_busy && !vsldu_result_valid_q)
                                    : (vfu_req_ready   && !vsldu_busy);

  // ---- VSLDU result latch ----
  // spatz_vsldu pulses vsldu_rsp_valid_o once with no ready handshake.
  // Hold the valid until the downstream path fires vfu_rsp_ready_i.
  logic vsldu_result_valid_d;
  always_comb begin : proc_vsldu_result_valid_d
    vsldu_result_valid_d = vsldu_result_valid_q;
    if (vsldu_rsp_valid)      vsldu_result_valid_d = 1'b1;
    else if (vfu_rsp_ready_i) vsldu_result_valid_d = 1'b0;
  end
  `FF(vsldu_result_valid_q, vsldu_result_valid_d, 1'b0, clk_i, rst_ni)

  // ---- Response mux ----
  assign vfu_rsp_valid_o = vsldu_result_valid_q | vfu_rsp_valid;

  always_comb begin
    vfu_rsp_o = vfu_rsp;
    if (vsldu_result_valid_q) begin
      vfu_rsp_o.result = '0;
      vfu_rsp_o.wb     = 1'b0;
    end
  end

  // ---- spatz_vfu ----
  spatz_vfu #(
    .FPUImplementation(FPUImplementation)
  ) i_vfu (
    .clk_i             (clk_i             ),
    .rst_ni            (rst_ni            ),
    .hart_id_i         (hart_id_i         ),
    .spatz_req_i       (spatz_req_i       ),
    .spatz_req_valid_i (vfu_req_valid     ),
    .spatz_req_ready_o (vfu_req_ready     ),
    .spatz_req_first_o (vfu_req_first_o   ),
    .vfu_rsp_valid_o   (vfu_rsp_valid     ),
    .vfu_rsp_ready_i   (vfu_rsp_ready_i   ),
    .vfu_rsp_o         (vfu_rsp           ),
    .vrf_waddr_o       (vrf_waddr_o[0]    ),
    .vrf_wdata_o       (vrf_wdata_o[0]    ),
    .vrf_we_o          (vrf_we_o[0]       ),
    .vrf_wbe_o         (vrf_wbe_o[0]      ),
    .vrf_wvalid_i      (vrf_wvalid_i[0]   ),
    .vrf_id_o          (/* unused */      ),
    .vrf_raddr_o       (vrf_raddr_o[2:0]  ),
    .vrf_re_o          (vrf_re_o[2:0]     ),
    .vrf_rdata_i       (vrf_rdata_i[2:0]  ),
    .vrf_rvalid_i      (vrf_rvalid_i[2:0] ),
    .fpu_status_o      (fpu_status_o      )
  );

  // ---- spatz_vsldu ----
  spatz_vsldu #(
    .SIMD              (1'b1              )
  ) i_vsldu (
    .clk_i             (clk_i             ),
    .rst_ni            (rst_ni            ),
    .spatz_req_i       (spatz_req_i       ),
    .spatz_req_valid_i (vsldu_req_valid   ),
    .spatz_req_ready_o (vsldu_req_ready   ),
    .vsldu_rsp_valid_o (vsldu_rsp_valid   ),
    .vsldu_rsp_o       (vsldu_rsp         ),
    .vrf_waddr_o       (vrf_waddr_o[1]    ),
    .vrf_wdata_o       (vrf_wdata_o[1]    ),
    .vrf_we_o          (vrf_we_o[1]       ),
    .vrf_wbe_o         (vrf_wbe_o[1]      ),
    .vrf_wvalid_i      (vrf_wvalid_i[1]   ),
    .vrf_id_o          (/* unused */      ),
    .vrf_raddr_o       (vrf_raddr_o[3]    ),
    .vrf_re_o          (vrf_re_o[3]       ),
    .vrf_rdata_i       (vrf_rdata_i[3]    ),
    .vrf_rvalid_i      (vrf_rvalid_i[3]   )
  );

endmodule : schnizo_vfu_unit
