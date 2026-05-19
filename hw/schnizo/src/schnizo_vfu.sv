// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// Vector FU top-level for Schnizo (SIMD-oriented replacement for Spatz).
//
// Ports 0..NofVLSU-1 connect to schnizo_vlsu instances (memory ops).
// Ports NofVLSU..NumFuPorts-1 connect to schnizo_vfu_unit instances.
// Each schnizo_vfu_unit wraps one spatz_vfu and one spatz_vsldu behind a
// single VFU-style interface; slide instructions are routed to the VSLDU
// transparently.
//
// One shared spatz_vrf is used.  No spatz_controller: each port gets its own
// spatz_decoder; the decoded spatz_req_t is issued directly to the units.
// vl is fixed to one full VRF word per instruction (packed SIMD, no
// multi-word iteration).

module schnizo_vfu import schnizo_pkg::*, schnizo_tracer_pkg::*, spatz_pkg::*; import rvv_pkg::*; #(
  parameter int unsigned NofVLSU    = 1,
  parameter int unsigned NofVFU     = 1,
  parameter int unsigned NumFPUs    = 4,
  parameter int unsigned NumIPUs    = 1,
  parameter fpnew_pkg::fpu_implementation_t FPUImplementation = '0,
  // WAR hazard tracking: RS depths needed to size the consumer counters in spatz_vrf
  parameter int unsigned VlsuNofRss = 1,
  parameter int unsigned VfuNofRss  = 1,

  /// Derived parameter *Do not override*
  parameter int unsigned NumMemPorts         = (NumFPUs > NumIPUs) ? NumFPUs : NumIPUs,

  // For VLSU
  parameter int unsigned TCDMPorts  = NofVLSU*NumMemPorts,
  // To schnizo Fu-Blocks
  parameter int unsigned NumFuPorts = NofVLSU + NofVFU,
  // Types not in any imported package ? passed from the instantiating module
  parameter type issue_req_t    = logic,
  parameter type tcdm_req_chan_t = logic,
  parameter type tcdm_rsp_chan_t = logic
) (
  input  logic clk_i,
  input  logic rst_i,

  // pragma translate_off
  output logic trace_o,
  // pragma translate_on

  // FU Block signals
  // Input Handshake
  input  issue_req_t [NumFuPorts-1:0]       issue_req_i,
  input  logic       [NumFuPorts-1:0]       issue_req_valid_i,
  input  logic       [NumFuPorts-1:0]       issue_commit_i,
  output logic       [NumFuPorts-1:0]       issue_req_ready_o,

  // Output signals
  output logic       [NumFuPorts-1:0][ELEN-1:0]  result_o,
  output logic       [NumFuPorts-1:0]            result_valid_o,
  input  logic       [NumFuPorts-1:0]            result_ready_i,
  output instr_tag_t [NumFuPorts-1:0]            tag_o,

  // TCDM Ports
  output tcdm_req_chan_t [TCDMPorts-1:0] tcdm_req_o,
  output logic           [TCDMPorts-1:0] tcdm_req_valid_o,
  input  logic           [TCDMPorts-1:0] tcdm_req_ready_i,
  input  tcdm_rsp_chan_t [TCDMPorts-1:0] tcdm_rsp_i,
  input  logic           [TCDMPorts-1:0] tcdm_rsp_valid_i,

  output logic [NumFuPorts-1:0] busy_o,

  // Loop state for WAR hazard tracking (LEP write gating in spatz_vrf)
  input  loop_state_e          loop_state_i
);

  ////////////////
  // Parameters //
  ////////////////

  // VRF port layout (must match spatz_vrf's hardcoded enum indices):
  //
  //   Write ports: [NofVFU-1:0]           = VFU_VD_WD  (one per unit)
  //                [NofVFU+NofVLSU-1:NofVFU] = VLSU_VD_WD (one per VLSU)
  //                [2*NofVFU+NofVLSU-1:NofVFU+NofVLSU] = VSLDU_VD_WD (one per unit)
  //
  //   Read ports:  [3*NofVFU-1:0]              = VFU (vs2,vs1,vd per unit)
  //                [3*NofVFU+2*NofVLSU-1:3*NofVFU] = VLSU (vs2,vd per VLSU)
  //                [4*NofVFU+2*NofVLSU-1:3*NofVFU+2*NofVLSU] = VSLDU (vs2 per unit)
  //
  // For NofVFU=1, NofVLSU=1: NrWritePorts=3, NrReadPorts=6 ? matches
  // spatz_pkg hardcoded enums exactly.

  localparam int unsigned NrWritePorts = 2*NofVFU + NofVLSU;
  localparam int unsigned NrReadPorts  = 4*NofVFU + 2*NofVLSU;

  /////////////
  // Signals //
  /////////////

  // VRF write ports
  vrf_addr_t [NrWritePorts-1:0] vrf_waddr;
  vrf_data_t [NrWritePorts-1:0] vrf_wdata;
  logic      [NrWritePorts-1:0] vrf_we;
  vrf_be_t   [NrWritePorts-1:0] vrf_wbe;
  logic      [NrWritePorts-1:0] vrf_wvalid;

  // VRF read ports
  vrf_addr_t [NrReadPorts-1:0] vrf_raddr;
  logic      [NrReadPorts-1:0] vrf_re;
  logic      [NrReadPorts-1:0] vrf_re_first;
  vrf_data_t [NrReadPorts-1:0] vrf_rdata;
  logic      [NrReadPorts-1:0] vrf_rvalid;

  // Fixed SIMD vtype/vl: always fill the full 256-bit VRF word.
  // vl = VLEN >> (3 + vsew): e8?32, e16?16, e32?8, e64?4.
  // SimdVl (e64 baseline, 4 elements) is only used for the VLSU which ignores vl anyway.
  localparam vlen_t  SimdVl       = vlen_t'(VLEN / ELEN);
  localparam vtype_t DefaultVtype = '{vill: 1'b0, vma: 1'b0, vta: 1'b0,
                                      vsew: MAXEW, vlmul: LMUL_1};

  // Per-port decoder signals (one spatz_decoder per FU port)
  decoder_req_t [NumFuPorts-1:0] dec_req;
  decoder_rsp_t [NumFuPorts-1:0] dec_rsp;

  // Per-VLSU request/response signals
  spatz_req_t [NofVLSU-1:0] vlsu_spatz_req;
  logic       [NofVLSU-1:0] vlsu_spatz_req_valid;
  logic       [NofVLSU-1:0] vlsu_spatz_req_ready;
  vlsu_rsp_t  [NofVLSU-1:0] vlsu_rsp;
  logic       [NofVLSU-1:0] vlsu_rsp_valid;

  // Per-VLSU tag FIFOs (VLSU has no scalar rd in its response)
  instr_tag_t [NofVLSU-1:0] vlsu_tag_out;
  logic       [NofVLSU-1:0] vlsu_tag_valid;

  // VLSU memory channels ? NumMemPorts ports per VLSU instance
  tcdm_req_chan_t [NofVLSU-1:0][NumMemPorts-1:0] spatz_mem_req;
  logic           [NofVLSU-1:0][NumMemPorts-1:0] spatz_mem_req_valid;
  logic           [NofVLSU-1:0][NumMemPorts-1:0] spatz_mem_req_ready;
  tcdm_rsp_chan_t [NofVLSU-1:0][NumMemPorts-1:0] spatz_mem_rsp;
  logic           [NofVLSU-1:0][NumMemPorts-1:0] spatz_mem_rsp_valid;

  //////////////
  // Decoders //
  //////////////

  // One spatz_decoder per FU port.  The decoder is purely combinational
  // (decoder_rsp_valid_o = decoder_req_valid_i).  vl is overridden to SimdVl
  // after decode; port index used as instruction ID.
  for (genvar p = 0; p < NumFuPorts; p++) begin : gen_decoder
    assign dec_req[p] = '{
      rd:        {1'b0, issue_req_i[p].tag.dest_reg},
      instr:     issue_req_i[p].fu_data.raw_instr,
      rs1:       elen_t'(issue_req_i[p].fu_data.operand_a),
      rs1_valid: issue_req_i[p].fu_data.use_operand_a,
      rs2:       elen_t'(issue_req_i[p].fu_data.operand_b),
      rs2_valid: issue_req_i[p].fu_data.use_operand_b,
      rsd:       '0,
      rsd_valid: 1'b0,
      vtype:     DefaultVtype
    };

    // Intermediate signal to avoid assignment-pattern-in-port-connection (VER-721).
    fpnew_pkg::fmt_mode_t fpu_fmt_mode_p;
    assign fpu_fmt_mode_p.src = issue_req_i[p].fu_data.fpu_fmt_src;
    assign fpu_fmt_mode_p.dst = issue_req_i[p].fu_data.fpu_fmt_dst;

    // VLSU ports [0..NofVLSU-1]: decode only memory (LSU) operations.
    // VFU/VSLDU ports [NofVLSU..NumFuPorts-1]: decode vector arithmetic and
    // slide operations; decode_vlsu is disabled so LSU opcodes are treated as
    // illegal, preventing accidental misrouting.
    if (p < NofVLSU) begin : gen_vlsu_decoder
      spatz_decoder #(
        .decode_vfu  (1'b0),
        .decode_vsldu(1'b0),
        .decode_vlsu (1'b1)
      ) i_decoder (
        .clk_i               (clk_i                          ),
        .rst_ni              (~rst_i                         ),
        .decoder_req_i       (dec_req[p]                     ),
        .decoder_req_valid_i (issue_req_valid_i[p]           ),
        .decoder_rsp_o       (dec_rsp[p]                     ),
        .decoder_rsp_valid_o (/* = issue_req_valid_i[p] */   ),
        .fpu_rnd_mode_i      (issue_req_i[p].fu_data.fpu_rnd_mode),
        .fpu_fmt_mode_i      (fpu_fmt_mode_p                 )
      );
    end : gen_vlsu_decoder
    else begin : gen_vfu_decoder
      spatz_decoder #(
        .decode_vfu  (1'b1),
        .decode_vsldu(1'b1),
        .decode_vlsu (1'b0)
      ) i_decoder (
        .clk_i               (clk_i                          ),
        .rst_ni              (~rst_i                         ),
        .decoder_req_i       (dec_req[p]                     ),
        .decoder_req_valid_i (issue_req_valid_i[p]           ),
        .decoder_rsp_o       (dec_rsp[p]                     ),
        .decoder_rsp_valid_o (/* = issue_req_valid_i[p] */   ),
        .fpu_rnd_mode_i      (issue_req_i[p].fu_data.fpu_rnd_mode),
        .fpu_fmt_mode_i      (fpu_fmt_mode_p                 )
      );
    end : gen_vfu_decoder
  end : gen_decoder

  /////////
  // VRF //
  /////////

  spatz_vrf #(
    .NrReadPorts  (NrReadPorts ),
    .NrWritePorts (NrWritePorts),
    .FpuBufDepth  (4           ),
    .NofVLSU      (NofVLSU     ),
    .NofVFU       (NofVFU      ),
    .VlsuNofRss   (VlsuNofRss  ),
    .VfuNofRss    (VfuNofRss   ),
    .SIMD         (1           )
  ) i_vrf (
    .clk_i         (clk_i        ),
    .rst_ni        (~rst_i       ),
    .testmode_i    ('0           ),
    .waddr_i       (vrf_waddr    ),
    .wdata_i       (vrf_wdata    ),
    .we_i          (vrf_we       ),
    .wbe_i         (vrf_wbe      ),
    .wvalid_o      (vrf_wvalid   ),
    .loop_state_i  (loop_state_i ),
    .raddr_i       (vrf_raddr    ),
    .re_i          (vrf_re       ),
    .re_first_i    (vrf_re_first ),
    .rdata_o       (vrf_rdata    ),
    .rvalid_o      (vrf_rvalid   )
  );

  ///////////
  // Units //
  ///////////

  // Each arithmetic FU port is served by a schnizo_vfu_unit ? a wrapper that
  // contains one spatz_vfu and one spatz_vsldu.  Slide instructions are
  // routed internally to the VSLDU; from here the unit looks identical to a
  // plain spatz_vfu.
  //
  // VCFG (vsetvl*) bypasses the unit entirely: the new vl is computed
  // combinatorially and the instruction completes in a single cycle.

  for (genvar i = 0; i < NofVFU; i++) begin : gen_vfu
    localparam int unsigned PORT    = NofVLSU + i;
    // VFU write port index (VFU_VD_WD)
    localparam int unsigned WD      = i;
    // VSLDU write port index (VSLDU_VD_WD)
    localparam int unsigned WD_SLD  = NofVFU + NofVLSU + i;
    // VFU read port base ? covers vs2, vs1, vd (3 consecutive ports)
    localparam int unsigned RD_BASE = 3*i;
    // VSLDU read port index (VSLDU_VS2_RD)
    localparam int unsigned RD_SLD  = 3*NofVFU + 2*NofVLSU + i;

    // Detect VCFG (vsetvl/vsetvli/vsetivli): bypass the unit entirely.
    logic is_vcfg;
    assign is_vcfg = (dec_rsp[PORT].spatz_req.op == VCFG);

    // Forward declaration: defined with the response FIFO below; needed here
    // to gate the vsew update against an in-flight VFU result.
    logic rsp_fifo_valid;

    // Track the current vsew, updated on every accepted VCFG.
    // spatz_decoder defaults to EW_8; schnizo patches it to the last seen vsew.
    vew_e vsew_q;
    `FFLAR(vsew_q, dec_rsp[PORT].spatz_req.vtype.vsew,
           is_vcfg && issue_req_valid_i[PORT] && result_ready_i[PORT] && !rsp_fifo_valid,
           MAXEW, clk_i, rst_i)

    // Patch vsew and vl into the request before forwarding to the unit.
    // For widening instructions (vwmul etc.) the destination EEW is 2×SEW,
    // so halve vl to keep the result within one 256-bit VRF word.
    spatz_req_t unit_req;
    always_comb begin
      unit_req            = dec_rsp[PORT].spatz_req;
      unit_req.vtype.vsew = vsew_q;
      if (dec_rsp[PORT].spatz_req.op_arith.widen_vs1 || dec_rsp[PORT].spatz_req.op_arith.widen_vs2) begin
        unit_req.vl = vlen_t'(VLEN >> (4 + vsew_q));
      end
      else begin
        unit_req.vl = vlen_t'(VLEN >> (3 + vsew_q));
      end
      unit_req.id = spatz_id_t'(i);
    end

    logic    unit_req_ready;
    logic    unit_rsp_valid;
    vfu_rsp_t unit_rsp;

    // Response FIFO: decouples spatz_vfu's one-shot result pulse from the
    // downstream valid-ready handshake.  Without this, scalar instructions
    // (vmv.x.s) deadlock: spatz_vfu won't accept a scalar instruction unless
    // vfu_rsp_ready_i=1 (spatz_vfu.sv line ~140/454), but vfu_rsp_ready_i
    // was tied to result_ready_i which is only 1 after spatz_gpr_valid fires,
    // which requires the instruction to have already completed.
    // Fix: vfu_rsp_ready_i = rsp_fifo_push_ready (FIFO has room), which is 1
    // initially.  The FIFO holds the result until the writeback path consumes it.
    vfu_rsp_t rsp_fifo_out;
    logic     rsp_fifo_push_ready;

    stream_fifo #(
      .T           (vfu_rsp_t   ),
      .DEPTH       (VFUBufDepth ),
      .FALL_THROUGH(1'b1        )
    ) i_rsp_fifo (
      .clk_i     (clk_i                 ),
      .rst_ni    (~rst_i                ),
      .flush_i   (1'b0                  ),
      .testmode_i(1'b0                  ),
      .usage_o   (/* unused */          ),
      .data_i    (unit_rsp              ),
      .valid_i   (unit_rsp_valid        ),
      .ready_o   (rsp_fifo_push_ready   ),
      .data_o    (rsp_fifo_out          ),
      .valid_o   (rsp_fifo_valid        ),
      .ready_i   (result_ready_i[PORT]  )
    );

    logic [$clog2(VFUBufDepth)-1:0] vfu_tag_usage;

    assign issue_req_ready_o[PORT] = is_vcfg ? (result_ready_i[PORT] && !rsp_fifo_valid) : unit_req_ready;
    assign busy_o[PORT]            = ~issue_req_ready_o[PORT] || (vfu_tag_usage != '0);

    logic vfu_req_first;
    schnizo_vfu_unit #(
      .FPUImplementation(FPUImplementation)
    ) i_unit (
      .clk_i             (clk_i                                              ),
      .rst_ni            (~rst_i                                             ),
      .hart_id_i         (32'(i)                                             ),
      .spatz_req_i       (unit_req                                           ),
      .spatz_req_valid_i (issue_req_valid_i[PORT] && !is_vcfg               ),
      .spatz_req_ready_o (unit_req_ready                                     ),
      .vfu_rsp_valid_o   (unit_rsp_valid                                     ),
      .vfu_rsp_ready_i   (rsp_fifo_push_ready                               ),
      .vfu_rsp_o         (unit_rsp                                           ),
      // Write: [0]=VFU_VD_WD, [1]=VSLDU_VD_WD (non-contiguous in vrf_waddr)
      .vrf_waddr_o       ({vrf_waddr[WD_SLD], vrf_waddr[WD]}                ),
      .vrf_wdata_o       ({vrf_wdata[WD_SLD], vrf_wdata[WD]}                ),
      .vrf_we_o          ({vrf_we   [WD_SLD], vrf_we   [WD]}                ),
      .vrf_wbe_o         ({vrf_wbe  [WD_SLD], vrf_wbe  [WD]}                ),
      .vrf_wvalid_i      ({vrf_wvalid[WD_SLD], vrf_wvalid[WD]}              ),
      // Read: [2:0]=VFU (vs2/vs1/vd), [3]=VSLDU_VS2_RD
      .vrf_raddr_o       ({vrf_raddr[RD_SLD], vrf_raddr[RD_BASE+2:RD_BASE]} ),
      .vrf_re_o          ({vrf_re   [RD_SLD], vrf_re   [RD_BASE+2:RD_BASE]} ),
      .vrf_rdata_i       ({vrf_rdata[RD_SLD], vrf_rdata[RD_BASE+2:RD_BASE]} ),
      .vrf_rvalid_i      ({vrf_rvalid[RD_SLD], vrf_rvalid[RD_BASE+2:RD_BASE]}),
      .fpu_status_o      (/* unused */                                       ),
      .vfu_req_first_o   (vfu_req_first                                      )
    );

    // VFU re_first: spatz_vfu pulses this on the first cycle re_o goes high
    // for each new instruction (running_q not yet set), eliminating the
    // off-by-one that the old dispatch-latched version had with FALL_THROUGH=1.
    assign vrf_re_first[RD_BASE+2:RD_BASE] = {3{vfu_req_first}};

    // VSLDU re_first: spill_register has 1-cycle latency then one more cycle
    // before running_q enables re_o, so firing one cycle after dispatch accept
    // is still correct (re_i is 0 at that point ? last_read is harmless).
    logic vfu_dispatch_q;
    `FFAR(vfu_dispatch_q, issue_req_valid_i[PORT] && unit_req_ready && !is_vcfg, 1'b0, clk_i, rst_i)
    assign vrf_re_first[RD_SLD] = vfu_dispatch_q;

    // VCFG: return new vl computed from the decoded vtype.
    // Arithmetic/slide: result comes from the response FIFO.
    // VFU result takes priority: if rsp_fifo has a result pending, present it
    // before accepting/completing any incoming VCFG (see tag_o and
    // issue_req_ready_o).  Without this, a VCFG dispatched during vfmin writeback
    // overwrites tag_o with the VCFG tag, leaving the scoreboard entry for the
    // VFU instruction permanently set and stalling the core.
    assign result_o[PORT]       = (is_vcfg && !rsp_fifo_valid)
                                  ? ELEN'(VLEN >> (3 + dec_rsp[PORT].spatz_req.vtype.vsew))
                                  : rsp_fifo_out.result;
    assign result_valid_o[PORT] = rsp_fifo_valid || (is_vcfg && issue_req_valid_i[PORT]);

    // Tag FIFO: one entry per instruction accepted into the VFU's internal FIFO.
    // A single latch would be corrupted when a second instruction is dispatched
    // before the first result fires (spatz_vfu has VFUBufDepth=6 slots).
    // Shared between VFU and VSLDU: mutual exclusion ensures at most one VSLDU
    // is ever in-flight, so depth = VFUBufDepth covers both.
    // Pop is synchronized with the response FIFO: both drain together.
    instr_tag_t vfu_tag_out;
    stream_fifo #(
      .T           (instr_tag_t ),
      .DEPTH       (VFUBufDepth ),
      .FALL_THROUGH(1'b1        )
    ) i_vfu_tag_fifo (
      .clk_i     (clk_i                                               ),
      .rst_ni    (~rst_i                                              ),
      .flush_i   (1'b0                                                ),
      .testmode_i(1'b0                                                ),
      .usage_o   (vfu_tag_usage                                       ),
      .data_i    (issue_req_i[PORT].tag                               ),
      .valid_i   (!is_vcfg && issue_req_valid_i[PORT]
                           && issue_req_ready_o[PORT]                ),
      .ready_o   (/* depth >= VFUBufDepth, never stalls */            ),
      .data_o    (vfu_tag_out                                         ),
      .valid_o   (/* trusted: matches rsp_fifo occupancy */           ),
      .ready_i   (rsp_fifo_valid && result_ready_i[PORT]             )
    );
    assign tag_o[PORT] = rsp_fifo_valid ? vfu_tag_out : issue_req_i[PORT].tag;
  end : gen_vfu

  //////////
  // VLSU //
  //////////

  for (genvar j = 0; j < NofVLSU; j++) begin : gen_vlsu
    localparam int unsigned WD      = NofVFU + j;      // VRF write port (VLSU_VD_WD)
    localparam int unsigned RD_BASE = 3*NofVFU + 2*j;  // VRF read port base (vs2, vd)

    // Use decoded spatz_req, override vl (SIMD fixed length) and id (port index).
    always_comb begin
      vlsu_spatz_req[j]    = dec_rsp[j].spatz_req;
      vlsu_spatz_req[j].vl = SimdVl;
      vlsu_spatz_req[j].id = spatz_id_t'(j);
    end

    // VLSU is non-speculative (memory): gate issue with commit and stall while result pending.
    logic vlsu_result_valid_q;
    logic vlsu_pending_is_load_q;
    logic vlsu_can_issue;
    logic vlsu_unit_busy;  // from schnizo_vlsu.busy_o (state_q != IDLE)
    assign vlsu_can_issue          = vlsu_spatz_req_ready[j] && issue_commit_i[j] && !vlsu_result_valid_q;
    assign vlsu_spatz_req_valid[j] = issue_req_valid_i[j] && issue_commit_i[j] && !vlsu_result_valid_q;
    assign issue_req_ready_o[j]    = vlsu_can_issue;
    // busy_o: VLSU state machine is non-IDLE OR load result not yet consumed by RS.
    // vlsu_result_valid_q covers the window between VLSU returning to IDLE and the
    // RS consuming the load result, preventing premature lcp_finished assertion.
    // Fast stores never leave IDLE (vlsu_unit_busy stays 0); vlsu_result_valid_q
    // pulses for one cycle to cover their completion window.
    logic [$clog2(NrParallelInstructions)-1:0] vlsu_tag_usage;
    assign busy_o[j]               = vlsu_unit_busy || vlsu_result_valid_q || (vlsu_tag_usage != '0);

    // Track whether the issued instruction was a load.
    // Stores are retired at issue (retire_at_issue=true) so they must not generate
    // a result_valid pulse back to the RS ? that would underflow issue_in_flight_q.
    `FFLAR(vlsu_pending_is_load_q, vlsu_spatz_req[j].op_mem.is_load,
           vlsu_spatz_req_valid[j] && vlsu_spatz_req_ready[j], 1'b0, clk_i, rst_i)

    // Latch the one-shot vlsu_rsp_valid pulse; hold until downstream consumes.
    // For stores, self-clear next cycle (no result_ready_i will ever fire for them).
    `FFLAR(vlsu_result_valid_q, vlsu_rsp_valid[j],
           vlsu_rsp_valid[j] || (vlsu_pending_is_load_q ? result_ready_i[j] : 1'b1),
           1'b0, clk_i, rst_i)

    // Tag FIFO: push at issue for loads only; stores don't generate an RS result.
    stream_fifo #(
      .T           (instr_tag_t          ),
      .DEPTH       (NrParallelInstructions),
      .FALL_THROUGH(1'b1                 )
    ) i_vlsu_tag_fifo (
      .clk_i     (clk_i                                               ),
      .rst_ni    (~rst_i                                              ),
      .flush_i   (1'b0                                                ),
      .testmode_i(1'b0                                                ),
      .usage_o   (vlsu_tag_usage                                      ),
      .data_i    (issue_req_i[j].tag                                  ),
      .valid_i   (vlsu_spatz_req_valid[j] && vlsu_spatz_req_ready[j] &&
                  vlsu_spatz_req[j].op_mem.is_load                   ),
      .ready_o   (/* FIFO depth >= single-slot RS depth */            ),
      .data_o    (vlsu_tag_out[j]                                     ),
      .valid_o   (vlsu_tag_valid[j]                                   ),
      .ready_i   (result_ready_i[j] && vlsu_result_valid_q           )
    );

    schnizo_vlsu #(
      .NrMemPorts        (NumMemPorts    ),
      .NrOutstandingLoads(8             ),
      .spatz_mem_req_t   (tcdm_req_chan_t),
      .spatz_mem_rsp_t   (tcdm_rsp_chan_t)
    ) i_vlsu (
      .clk_i                   (clk_i                              ),
      .rst_ni                  (~rst_i                             ),
      .spatz_req_i             (vlsu_spatz_req[j]                  ),
      .spatz_req_valid_i       (vlsu_spatz_req_valid[j]            ),
      .spatz_req_ready_o       (vlsu_spatz_req_ready[j]            ),
      .vlsu_rsp_valid_o        (vlsu_rsp_valid[j]                  ),
      .vlsu_rsp_o              (vlsu_rsp[j]                        ),
      // VRF write port
      .vrf_waddr_o             (vrf_waddr[WD]                      ),
      .vrf_wdata_o             (vrf_wdata[WD]                      ),
      .vrf_we_o                (vrf_we   [WD]                      ),
      .vrf_wbe_o               (vrf_wbe  [WD]                      ),
      .vrf_wvalid_i            (vrf_wvalid[WD]                     ),
      // VRF read ports [vs2=RD_BASE, vd=RD_BASE+1]
      .vrf_id_o                (/* unused without controller */    ),
      .vrf_raddr_o             (vrf_raddr [RD_BASE+1:RD_BASE]      ),
      .vrf_re_o                (vrf_re    [RD_BASE+1:RD_BASE]      ),
      .vrf_rdata_i             (vrf_rdata [RD_BASE+1:RD_BASE]      ),
      .vrf_rvalid_i            (vrf_rvalid[RD_BASE+1:RD_BASE]      ),
      // Memory interface (NumMemPorts ports per VLSU)
      .spatz_mem_req_o         (spatz_mem_req      [j]             ),
      .spatz_mem_req_valid_o   (spatz_mem_req_valid[j]             ),
      .spatz_mem_req_ready_i   (spatz_mem_req_ready[j]             ),
      .spatz_mem_rsp_i         (spatz_mem_rsp      [j]             ),
      .spatz_mem_rsp_valid_i   (spatz_mem_rsp_valid[j]             ),
      .spatz_mem_finished_o    (/* unused */                        ),
      .spatz_mem_str_finished_o(/* unused */                        ),
      .busy_o                  (vlsu_unit_busy                      )
    );

    // re_first for VLSU read ports: VLSU reads start on the same cycle as dispatch.
    assign vrf_re_first[RD_BASE+1:RD_BASE] = {2{vlsu_spatz_req_valid[j] && vlsu_spatz_req_ready[j]}};

    // TCDM wiring: VLSU j occupies ports [j*NumMemPorts +: NumMemPorts]
    for (genvar p = 0; p < NumMemPorts; p++) begin : gen_tcdm
      localparam int unsigned TP = j*NumMemPorts + p;
      assign tcdm_req_o[TP]              = spatz_mem_req      [j][p];
      assign tcdm_req_valid_o[TP]        = spatz_mem_req_valid[j][p];
      assign spatz_mem_req_ready[j][p]   = tcdm_req_ready_i[TP];
      assign spatz_mem_rsp      [j][p]   = tcdm_rsp_i      [TP];
      assign spatz_mem_rsp_valid[j][p]   = tcdm_rsp_valid_i[TP];
    end : gen_tcdm

    // VLSU has no scalar result; only forward result to RS for loads.
    assign result_o[j]       = '0;
    assign result_valid_o[j] = vlsu_result_valid_q && vlsu_pending_is_load_q;
    assign tag_o[j]          = vlsu_tag_out[j];
  end : gen_vlsu

  // pragma translate_off
  assign trace_o = 1'b0;
  // pragma translate_on

  ////////////////
  // Assertions //
  ////////////////

  if (spatz_pkg::N_IPU == 0)
    $error("[schnizo_vfu] Spatz requires at least one IPU");

  if (NofVFU == 0)
    $error("[schnizo_vfu] NofVFU must be > 0");

  if (NofVLSU == 0)
    $error("[schnizo_vfu] NofVLSU must be > 0");

  if (spatz_pkg::VLEN != 2**$clog2(spatz_pkg::VLEN))
    $error("[schnizo_vfu] VLEN must be a power of two");

endmodule
