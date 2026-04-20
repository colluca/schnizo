// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Vector FU top-level for Schnizo (SIMD-oriented replacement for Spatz).
//
// Ports 0..NofVLSU-1 connect to spatz_vlsu instances (memory ops).
// Ports NofVLSU..NumFuPorts-1 connect to spatz_vfu instances (arithmetic ops).
// One shared spatz_vrf is used. No spatz_controller: each port gets its own
// spatz_decoder and the decoded spatz_req_t is issued directly to VFU/VLSU.
// vl is fixed to N_FU (one full VRF word per instruction, processed in one
// cycle ? packed SIMD with vector-size registers, no multi-word iteration).

module schnizo_vfu import schnizo_pkg::*, schnizo_tracer_pkg::*, spatz_pkg::*; import rvv_pkg::*; #(
  parameter int unsigned NofVLSU    = 1,
  parameter int unsigned NofVFU     = 1,
  parameter int unsigned NumFPUs    = 4,
  parameter int unsigned NumIPUs    = 1,
  parameter fpnew_pkg::fpu_implementation_t FPUImplementation = '0,

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

  output logic [NumFuPorts-1:0] busy_o
);

  ////////////////
  // Parameters //
  ////////////////

  // VRF port layout (must match spatz_vrf's hardcoded enum indices):
  //   Write port 0 = VFU_VD_WD, port 1 = VLSU_VD_WD, port 2 = VSLDU_VD_WD (tied off)
  //   Read  port 0-2 = VFU (vs2,vs1,vd), 3-4 = VLSU (vs2,vd), 5 = VSLDU_VS2_RD (tied off)
  // The +1 on each is the tie-off port for VSLDU; without it the VRF indexes out-of-bounds
  // and produces X on every bank access.
  localparam int unsigned NrWritePorts = NofVFU + NofVLSU + 1;
  localparam int unsigned NrReadPorts  = 3*NofVFU + 2*NofVLSU + 1;

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
  vrf_data_t [NrReadPorts-1:0] vrf_rdata;
  logic      [NrReadPorts-1:0] vrf_rvalid;

  // VSLDU tie-off: drive the unused VSLDU ports to zero so the VRF's
  // hardcoded VSLDU_VD_WD / VSLDU_VS2_RD indices never see X.
  assign vrf_we   [NrWritePorts-1] = '0;
  assign vrf_waddr[NrWritePorts-1] = '0;
  assign vrf_wdata[NrWritePorts-1] = '0;
  assign vrf_wbe  [NrWritePorts-1] = '0;
  assign vrf_re   [NrReadPorts-1]  = '0;
  assign vrf_raddr[NrReadPorts-1]  = '0;

  // Fixed SIMD vtype/vl: always fill the full 256-bit VRF word.
  // vl = VLEN >> (3 + vsew): e8?32, e16?16, e32?8, e64?4.
  // SimdVl (e64 baseline, 4 elements) is only used for the VLSU which ignores vl anyway.
  localparam vlen_t  SimdVl       = vlen_t'(VLEN / ELEN);
  localparam vtype_t DefaultVtype = '{vill: 1'b0, vma: 1'b0, vta: 1'b0,
                                      vsew: MAXEW, vlmul: LMUL_1};

  // Per-port decoder signals (one spatz_decoder per FU port)
  decoder_req_t [NumFuPorts-1:0] dec_req;
  decoder_rsp_t [NumFuPorts-1:0] dec_rsp;

  // Per-VFU request/response signals
  spatz_req_t [NofVFU-1:0] vfu_spatz_req;
  logic       [NofVFU-1:0] vfu_spatz_req_valid;
  logic       [NofVFU-1:0] vfu_spatz_req_ready;
  vfu_rsp_t   [NofVFU-1:0] vfu_rsp;
  logic       [NofVFU-1:0] vfu_rsp_valid;

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

  // One spatz_decoder per FU port. The decoder is purely combinational
  // (decoder_rsp_valid_o = decoder_req_valid_i). vl is overridden to SimdVl
  // (= N_FU, one VRF word) after decode; port index used as instruction ID.
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

    spatz_decoder i_decoder (
      .clk_i               (clk_i                          ),
      .rst_ni              (~rst_i                         ),
      .decoder_req_i       (dec_req[p]                     ),
      .decoder_req_valid_i (issue_req_valid_i[p]           ),
      .decoder_rsp_o       (dec_rsp[p]                     ),
      .decoder_rsp_valid_o (/* = issue_req_valid_i[p] */   ),
      .fpu_rnd_mode_i      (issue_req_i[p].fu_data.fpu_rnd_mode),
      .fpu_fmt_mode_i      ('{src: issue_req_i[p].fu_data.fpu_fmt_src,
                               dst: issue_req_i[p].fu_data.fpu_fmt_dst})
    );
  end : gen_decoder

  /////////
  // VRF //
  /////////

  spatz_vrf #(
    .NrReadPorts (NrReadPorts ),
    .NrWritePorts(NrWritePorts),
    .FpuBufDepth (4           )
  ) i_vrf (
    .clk_i      (clk_i    ),
    .rst_ni     (~rst_i   ),
    .testmode_i ('0       ),
    .waddr_i    (vrf_waddr),
    .wdata_i    (vrf_wdata),
    .we_i       (vrf_we   ),
    .wbe_i      (vrf_wbe  ),
    .wvalid_o   (vrf_wvalid),
    .raddr_i    (vrf_raddr),
    .re_i       (vrf_re   ),
    .rdata_o    (vrf_rdata),
    .rvalid_o   (vrf_rvalid)
  );

  /////////
  // VFU //
  /////////

  for (genvar i = 0; i < NofVFU; i++) begin : gen_vfu
    localparam int unsigned PORT    = NofVLSU + i; // FU port index
    localparam int unsigned WD      = i;           // VRF write port index
    localparam int unsigned RD_BASE = 3*i;         // VRF read port base (vs2, vs1, vd)

    // Detect VCFG (vsetvl/vsetvli/vsetivli): bypass spatz_vfu entirely.
    logic is_vcfg;
    assign is_vcfg = (dec_rsp[PORT].spatz_req.op == VCFG);

    // Track current vsew ? updated on every accepted VCFG, defaults to MAXEW (e64).
    // spatz_decoder leaves spatz_req.vtype.vsew=EW_8 for arithmetic (Spatz controller
    // normally patches this from its CSR; schnizo has no controller, so we do it here).
    vew_e vsew_q;
    always_ff @(posedge clk_i or posedge rst_i) begin
      if (rst_i)
        vsew_q <= MAXEW;
      else if (is_vcfg && issue_req_valid_i[PORT] && result_ready_i[PORT])
        vsew_q <= dec_rsp[PORT].spatz_req.vtype.vsew;
    end

    // Use decoded spatz_req; patch vtype.vsew and vl so the VFU always processes
    // all 256 bits: vl = VLEN >> (3 + vsew).
    always_comb begin
      vfu_spatz_req[i]            = dec_rsp[PORT].spatz_req;
      vfu_spatz_req[i].vtype.vsew = vsew_q;
      vfu_spatz_req[i].vl         = vlen_t'(VLEN >> (3 + vsew_q));
      vfu_spatz_req[i].id         = spatz_id_t'(i);
    end

    // VFU executes speculatively. VCFG bypasses spatz_vfu entirely.
    assign vfu_spatz_req_valid[i]  = issue_req_valid_i[PORT] && !is_vcfg;
    assign issue_req_ready_o[PORT] = is_vcfg ? result_ready_i[PORT] : vfu_spatz_req_ready[i];
    assign busy_o[PORT]            = ~issue_req_ready_o[PORT];

    spatz_vfu #(
      .FPUImplementation(FPUImplementation)
    ) i_vfu (
      .clk_i             (clk_i                           ),
      .rst_ni            (~rst_i                          ),
      .hart_id_i         (32'(i)                          ),
      .spatz_req_i       (vfu_spatz_req[i]                ),
      .spatz_req_valid_i (vfu_spatz_req_valid[i]          ),
      .spatz_req_ready_o (vfu_spatz_req_ready[i]          ),
      .vfu_rsp_valid_o   (vfu_rsp_valid[i]                ),
      .vfu_rsp_ready_i   (result_ready_i[PORT]            ),
      .vfu_rsp_o         (vfu_rsp[i]                      ),
      // VRF write port
      .vrf_waddr_o       (vrf_waddr[WD]                   ),
      .vrf_wdata_o       (vrf_wdata[WD]                   ),
      .vrf_we_o          (vrf_we   [WD]                   ),
      .vrf_wbe_o         (vrf_wbe  [WD]                   ),
      .vrf_wvalid_i      (vrf_wvalid[WD]                  ),
      // VRF read ports [vs2=RD_BASE, vs1=RD_BASE+1, vd=RD_BASE+2]
      .vrf_raddr_o       (vrf_raddr [RD_BASE+2:RD_BASE]   ),
      .vrf_re_o          (vrf_re    [RD_BASE+2:RD_BASE]   ),
      .vrf_rdata_i       (vrf_rdata [RD_BASE+2:RD_BASE]   ),
      .vrf_rvalid_i      (vrf_rvalid[RD_BASE+2:RD_BASE]   ),
      .vrf_id_o          (/* unused without controller */  ),
      .fpu_status_o      (/* unused */                     )
    );

    // VCFG: return vl = VLEN >> (3 + new_vsew) so callers see the correct element count.
    // Arithmetic: gate dest_reg with wb to avoid clobbering scalar GPRs with
    //   vector register addresses (vfu_rsp.rd = vd_addr, not a scalar reg).
    assign result_o[PORT]       = is_vcfg
        ? ELEN'(VLEN >> (3 + dec_rsp[PORT].spatz_req.vtype.vsew))
        : vfu_rsp[i].result;
    assign result_valid_o[PORT] = is_vcfg ? issue_req_valid_i[PORT] : vfu_rsp_valid[i];
    assign tag_o[PORT] = '{
      dest_reg:       is_vcfg ? issue_req_i[PORT].tag.dest_reg :
                      (vfu_rsp[i].wb ? vfu_rsp[i].rd[RegAddrSize-1:0] : '0),
      dest_reg_is_fp: 1'b0,
      is_branch:      1'b0,
      is_jump:        1'b0
    };
  end : gen_vfu

  //////////
  // VLSU //
  //////////

  for (genvar j = 0; j < NofVLSU; j++) begin : gen_vlsu
    localparam int unsigned WD      = NofVFU + j;     // VRF write port index
    localparam int unsigned RD_BASE = 3*NofVFU + 2*j; // VRF read port base (vs2, vd)

    // Use decoded spatz_req, override vl (SIMD fixed length) and id (port index).
    always_comb begin
      vlsu_spatz_req[j]    = dec_rsp[j].spatz_req;
      vlsu_spatz_req[j].vl = SimdVl;
      vlsu_spatz_req[j].id = spatz_id_t'(j);
    end

    // VLSU is non-speculative (memory): gate issue with commit and stall while result pending.
    // Issue handshake and VLSU acceptance use the same condition so they stay in sync.
    logic vlsu_result_valid_q;
    logic vlsu_can_issue;
    assign vlsu_can_issue          = vlsu_spatz_req_ready[j] && issue_commit_i[j] && !vlsu_result_valid_q;
    assign vlsu_spatz_req_valid[j] = issue_req_valid_i[j] && issue_commit_i[j] && !vlsu_result_valid_q;
    assign issue_req_ready_o[j]    = vlsu_can_issue;
    assign busy_o[j]               = ~vlsu_can_issue;

    // Latch the one-shot vlsu_rsp_valid pulse; hold until downstream consumes.
    always_ff @(posedge clk_i or posedge rst_i) begin
      if (rst_i)
        vlsu_result_valid_q <= 1'b0;
      else if (vlsu_rsp_valid[j])
        vlsu_result_valid_q <= 1'b1;
      else if (result_ready_i[j])
        vlsu_result_valid_q <= 1'b0;
    end

    // Tag FIFO: push at issue, pop when downstream consumes the latched result.
    stream_fifo #(
      .T           (instr_tag_t          ),
      .DEPTH       (NrParallelInstructions),
      .FALL_THROUGH(1'b1                 )
    ) i_vlsu_tag_fifo (
      .clk_i     (clk_i                                               ),
      .rst_ni    (~rst_i                                              ),
      .flush_i   (1'b0                                                ),
      .testmode_i(1'b0                                                ),
      .usage_o   (/* unused */                                        ),
      .data_i    (issue_req_i[j].tag                                  ),
      .valid_i   (vlsu_spatz_req_valid[j] && vlsu_spatz_req_ready[j] ),
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
      .spatz_mem_str_finished_o(/* unused */                        )
    );

    // TCDM wiring: VLSU j occupies ports [j*NumMemPorts +: NumMemPorts]
    for (genvar p = 0; p < NumMemPorts; p++) begin : gen_tcdm
      localparam int unsigned TP = j*NumMemPorts + p;
      assign tcdm_req_o[TP]          = spatz_mem_req      [j][p];
      assign tcdm_req_valid_o[TP]    = spatz_mem_req_valid[j][p];
      assign spatz_mem_req_ready[j][p] = tcdm_req_ready_i[TP];
      assign spatz_mem_rsp      [j][p] = tcdm_rsp_i      [TP];
      assign spatz_mem_rsp_valid[j][p] = tcdm_rsp_valid_i[TP];
    end : gen_tcdm

    // VLSU has no scalar result; use latched valid so result_ready_i backpressure works.
    assign result_o[j]       = '0;
    assign result_valid_o[j] = vlsu_result_valid_q;
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
