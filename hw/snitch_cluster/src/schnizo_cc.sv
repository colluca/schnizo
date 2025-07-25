// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>

`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"
`include "snitch_vm/typedef.svh"

/// Schnizo Core Complex (CC)
/// Contains the Schnizo Core + FPU + Private Accelerators
module schnizo_cc #(
  /// Address width of the buses
  parameter int unsigned AddrWidth          = 0,
  /// Data width of the buses.
  parameter int unsigned DataWidth          = 0,
  /// Data width of the AXI DMA buses.
  parameter int unsigned DMADataWidth       = 0,
  /// Id width of the AXI DMA bus.
  parameter int unsigned DMAIdWidth         = 0,
  /// User width of the AXI DMA bus.
  parameter int unsigned DMAUserWidth       = 0,
  parameter int unsigned DMANumAxInFlight   = 0,
  parameter int unsigned DMAReqFifoDepth    = 0,
  parameter int unsigned DMANumChannels     = 0,
  /// Data port request type.
  parameter type         dreq_t             = logic,
  /// Data port response type.
  parameter type         drsp_t             = logic,
  /// TCDM Address Width
  parameter int unsigned TCDMAddrWidth      = 0,
  /// Data port request type.
  parameter type         tcdm_req_t         = logic,
  /// Data port response type.
  parameter type         tcdm_rsp_t         = logic,
  /// TCDM User Payload
  parameter type         tcdm_user_t        = logic,
  parameter type         axi_ar_chan_t      = logic,
  parameter type         axi_aw_chan_t      = logic,
  parameter type         axi_req_t          = logic,
  parameter type         axi_rsp_t          = logic,
  parameter type         hive_req_t         = logic,
  parameter type         hive_rsp_t         = logic,
  parameter type         acc_req_t          = logic,
  parameter type         acc_resp_t         = logic,
  parameter type         dma_events_t       = logic,
  parameter fpnew_pkg::fpu_implementation_t FPUImplementation = '0,
  /// Boot address of core.
  parameter logic [31:0] BootAddr           = 32'h0000_1000,
  /// Reduced-register extension
  parameter bit          RVE                = 0,
  /// Enable F and D Extension
  parameter bit          RVF                = 1,
  parameter bit          RVD                = 1,
  parameter bit          XDivSqrt           = 0,
  parameter bit          XF8                = 0,
  parameter bit          XF8ALT             = 0,
  parameter bit          XF16               = 0,
  parameter bit          XF16ALT            = 0,
  parameter bit          XFVEC              = 0,
  parameter bit          XFDOTP             = 0,
  /// Enable Snitch DMA
  parameter bit          Xdma               = 0,
  /// Has `frep` support.
  parameter bit          Xfrep              = 0,
  /// Has `SSR` support.
  parameter bit          Xssr               = 0,
  /// Has Xcopift support.
  parameter bit          Xcopift            = 0,
  /// Has `IPU` support.
  parameter bit          Xipu               = 0,
  /// Has virtual memory support.
  parameter bit          VMSupport          = 0,
  parameter int unsigned NumIntOutstandingLoads = 0,
  parameter int unsigned NumIntOutstandingMem   = 0,
  parameter int unsigned NumFPOutstandingLoads  = 0,
  parameter int unsigned NumFPOutstandingMem    = 0,
  parameter int unsigned NumDTLBEntries         = 0,
  parameter int unsigned NumITLBEntries         = 0,
  parameter int unsigned NumSequencerInstr      = 0,
  parameter int unsigned NumSsrs                = 0,
  parameter int unsigned SsrMuxRespDepth        = 0,
  parameter snitch_ssr_pkg::ssr_cfg_t [NumSsrs-1:0] SsrCfgs = '0,
  parameter logic [NumSsrs-1:0][4:0] SsrRegs                = '0,
  /// Add isochronous clock-domain crossings e.g., make it possible to operate
  /// the core in a slower clock domain.
  parameter bit          IsoCrossing        = 0,
  /// Timing Parameters
  /// Insert Pipeline registers into off-loading path (request)
  parameter bit          RegisterOffloadReq = 0,
  /// Insert Pipeline registers into off-loading path (response)
  parameter bit          RegisterOffloadRsp = 0,
  /// Insert Pipeline registers into data memory path (request)
  parameter bit          RegisterCoreReq    = 0,
  /// Insert Pipeline registers into data memory path (response)
  parameter bit          RegisterCoreRsp    = 0,
  /// Insert Pipeline register into the FPU data path (request)
  parameter bit          RegisterFPUReq     = 0,
  /// Insert Pipeline registers after sequencer
  parameter bit          RegisterSequencer  = 0,
  /// Insert Pipeline registers immediately before FPU datapath
  parameter bit          RegisterFPUIn      = 0,
  /// Insert Pipeline registers immediately after FPU datapath
  parameter bit          RegisterFPUOut     = 0,
  parameter snitch_pma_pkg::snitch_pma_t SnitchPMACfg = '{default: 0},
  /// Consistency Address Queue (CAQ) parameters.
  parameter int unsigned CaqDepth     = 0,
  parameter int unsigned CaqTagWidth  = 0,
  /// Enable debug support.
  parameter bit          DebugSupport = 1,
  /// Optional fixed TCDM alias.
  parameter bit          TCDMAliasEnable = 1'b0,
  parameter logic [AddrWidth-1:0] TCDMAliasStart  = '0,
  /// Derived parameter *Do not override*
  parameter int unsigned TCDMPorts = (NumSsrs > 1 ? NumSsrs : 1),
  parameter type addr_t = logic [AddrWidth-1:0],
  parameter type data_t = logic [DataWidth-1:0]
) (
  input  logic                             clk_i,
  input  logic                             clk_d2_i,
  input  logic                             rst_ni,
  input  logic                             rst_int_ss_ni,
  input  logic                             rst_fp_ss_ni,
  input  logic [31:0]                      hart_id_i,
  input  snitch_pkg::interrupts_t          irq_i,
  output hive_req_t                        hive_req_o,
  input  hive_rsp_t                        hive_rsp_i,
  // Core data ports
  output dreq_t                            data_req_o,
  input  drsp_t                            data_rsp_i,
  // TCDM Streamer Ports
  output tcdm_req_t [TCDMPorts-1:0]        tcdm_req_o,
  input  tcdm_rsp_t [TCDMPorts-1:0]        tcdm_rsp_i,
  // Accelerator Offload port
  // DMA ports
  output axi_req_t    [DMANumChannels-1:0] axi_dma_req_o,
  input  axi_rsp_t    [DMANumChannels-1:0] axi_dma_res_i,
  output logic        [DMANumChannels-1:0] axi_dma_busy_o,
  output dma_events_t [DMANumChannels-1:0] axi_dma_events_o,
  // Core event strobes
  output snitch_pkg::core_events_t         core_events_o,
  input  addr_t                            tcdm_addr_base_i,
  // Cluster HW barrier
  output logic                             barrier_o,
  input  logic                             barrier_i
);

  // FMA architecture is "merged" -> mulexp and macexp instructions are supported
  localparam bit XFauxMerged  = (FPUImplementation.UnitTypes[3] == fpnew_pkg::MERGED);
  localparam bit FPEn = RVF | RVD | XF16 | XF16ALT | XF8 | XF8ALT | XFVEC | XFauxMerged | XFDOTP;
  localparam int unsigned FLEN = RVD     ? 64 : // D ext.
                                 RVF     ? 32 : // F ext.
                                 XF16    ? 16 : // Xf16 ext.
                                 XF16ALT ? 16 : // Xf16alt ext.
                                 XF8     ?  8 :  // Xf8 ext.
                                 XF8ALT  ?  8 :  // Xf8alt ext.
                                            0;             // Unused in case of no FP

  acc_req_t acc_schnizo_req;
  acc_req_t acc_schnizo_demux;
  acc_req_t acc_schnizo_demux_q;
  acc_resp_t acc_demux_schnizo;
  acc_resp_t acc_demux_schnizo_q;
  acc_resp_t dma_resp;

  logic acc_schnizo_demux_qvalid,   acc_schnizo_demux_qready;
  logic acc_schnizo_demux_qvalid_q, acc_schnizo_demux_qready_q;
  logic dma_qvalid, dma_qready;

  logic dma_pvalid, dma_pready;
  logic acc_demux_snitch_valid,   acc_demux_snitch_ready;
  logic acc_demux_snitch_valid_q, acc_demux_snitch_ready_q;

  snitch_pkg::core_events_t schnizo_events;

  // Schnizo Core Memory request
  dreq_t schnizo_dreq_d, schnizo_dreq_q, merged_dreq;
  drsp_t schnizo_drsp_d, schnizo_drsp_q, merged_drsp;

  `SNITCH_VM_TYPEDEF(AddrWidth)

  schnizo #(
    .BootAddr              (BootAddr),
    .AddrWidth             (AddrWidth),
    .DataWidth             (DataWidth),
    .Xdma                  (Xdma),
    .FP_EN                 (FPEn),
    .RVF                   (RVF),
    .RVD                   (RVD),
    .XF16                  (XF16),
    .XF16ALT               (XF16ALT),
    .XF8                   (XF8),
    .XF8ALT                (XF8ALT),
    .XFVEC                 (XFVEC),
    .FLEN                  (FLEN),
    .dreq_t                (dreq_t),
    .drsp_t                (drsp_t),
    .acc_req_t             (acc_req_t),
    .acc_resp_t            (acc_resp_t),
    .NumOutstandingLoads   (NumIntOutstandingLoads), // Use the int value for all LSUs
    .NumOutstandingMem     (NumIntOutstandingMem),
    .SnitchPMACfg          (SnitchPMACfg),
    .CaqDepth              (CaqDepth),
    .CaqTagWidth           (CaqTagWidth),
    .DebugSupport          (DebugSupport),
    .FPUImplementation     (FPUImplementation),
    .RegisterFPUIn         (RegisterFPUIn),
    .RegisterFPUOut        (RegisterFPUOut)
  ) i_schnizo (
    .clk_i           (clk_d2_i), // if necessary operate on half the frequency
    .rst_i           (~rst_ni),
    .hart_id_i,
    .irq_i,
    .flush_i_valid_o (hive_req_o.flush_i_valid),
    .flush_i_ready_i (hive_rsp_i.flush_i_ready),
    .inst_addr_o     (hive_req_o.inst_addr),
    .inst_cacheable_o(hive_req_o.inst_cacheable),
    .inst_data_i     (hive_rsp_i.inst_data),
    .inst_valid_o    (hive_req_o.inst_valid),
    .inst_ready_i    (hive_rsp_i.inst_ready),
    .acc_qreq_o      (acc_schnizo_demux),
    .acc_qvalid_o    (acc_schnizo_demux_qvalid),
    .acc_qready_i    (acc_schnizo_demux_qready),
    .acc_prsp_i      (acc_demux_schnizo),
    .acc_pvalid_i    (acc_demux_snitch_valid),
    .acc_pready_o    (acc_demux_snitch_ready),
    .data_req_o      (schnizo_dreq_d),
    .data_rsp_i      (schnizo_drsp_d),
    .core_events_o   (schnizo_events),
    .barrier_o       (barrier_o),
    .barrier_i       (barrier_i)
  );

  reqrsp_iso #(
    .AddrWidth(AddrWidth),
    .DataWidth(DataWidth),
    .req_t    (dreq_t),
    .rsp_t    (drsp_t),
    .BypassReq(!RegisterCoreReq),
    .BypassRsp(!IsoCrossing && !RegisterCoreRsp)
  ) i_reqrsp_iso (
    .src_clk_i (clk_d2_i),
    .src_rst_ni(rst_ni),
    .src_req_i (schnizo_dreq_d),
    .src_rsp_o (schnizo_drsp_d),
    .dst_clk_i (clk_i),
    .dst_rst_ni(rst_ni),
    .dst_req_o (schnizo_dreq_q),
    .dst_rsp_i (schnizo_drsp_q)
  );

  // Cut off-loading request path
  isochronous_spill_register #(
    .T      (acc_req_t),
    .Bypass (!IsoCrossing && !RegisterOffloadReq)
  ) i_spill_register_acc_demux_req (
    .src_clk_i  (clk_d2_i),
    .src_rst_ni (rst_ni),
    .src_valid_i(acc_schnizo_demux_qvalid),
    .src_ready_o(acc_schnizo_demux_qready),
    .src_data_i (acc_schnizo_demux),
    .dst_clk_i  (clk_i),
    .dst_rst_ni (rst_ni),
    .dst_valid_o(acc_schnizo_demux_qvalid_q),
    .dst_ready_i(acc_schnizo_demux_qready_q),
    .dst_data_o (acc_schnizo_demux_q)
  );

  // Cut off-loading response path
  isochronous_spill_register #(
    .T     (acc_resp_t),
    .Bypass(!IsoCrossing && !RegisterOffloadRsp)
  ) i_spill_register_acc_demux_resp (
    .src_clk_i  (clk_i),
    .src_rst_ni (rst_ni),
    .src_valid_i(acc_demux_snitch_valid_q),
    .src_ready_o(acc_demux_snitch_ready_q),
    .src_data_i (acc_demux_schnizo_q),
    .dst_clk_i  (clk_d2_i),
    .dst_rst_ni (rst_ni),
    .dst_valid_o(acc_demux_snitch_valid),
    .dst_ready_i(acc_demux_snitch_ready),
    .dst_data_o (acc_demux_schnizo)
  );

  // Accelerator Demux Port
  // The new demux with the schnizo enum. We can use it yet.
  // stream_demux #(
  //   .N_OUP(schnizo_pkg::NOF_ACCELERATORS)
  // ) i_stream_demux_offload (
  //   .inp_valid_i(acc_schnizo_demux_qvalid_q),
  //   .inp_ready_o(acc_schnizo_demux_qready_q),
  //   .oup_sel_i  (acc_schnizo_demux_q.addr[$clog2(schnizo_pkg::NOF_ACCELERATORS)-1:0]),
  //   .oup_valid_o({dma_qvalid, hive_req_o.acc_qvalid}),
  //   .oup_ready_i({dma_qready, hive_rsp_i.acc_qready})
  // );
  // TODO: We must use the snitch_pkg::acc_addr_e enum. Otherwise we must adapt the whole cluster.
  logic ssr_qvalid, ipu_qvalid, acc_qvalid; // All signals are unused
  logic ssr_qready, ipu_qready, acc_qready; // All signals are unused
  stream_demux #(
    .N_OUP(5)
  ) i_stream_demux_offload (
    .inp_valid_i(acc_schnizo_demux_qvalid_q),
    .inp_ready_o(acc_schnizo_demux_qready_q),
    .oup_sel_i  (acc_schnizo_demux_q.addr[$clog2(5)-1:0]),
    .oup_valid_o({ssr_qvalid, ipu_qvalid, dma_qvalid, hive_req_o.acc_qvalid, acc_qvalid}),
    .oup_ready_i({ssr_qready, ipu_qready, dma_qready, hive_rsp_i.acc_qready, acc_qready})
  );

  // To shared muldiv
  assign hive_req_o.acc_req = acc_schnizo_demux_q;
  // Internal accelerators (only DMA in this case)
  assign acc_schnizo_req = acc_schnizo_demux_q;

  stream_arbiter #(
    .DATA_T(acc_resp_t),
    .N_INP (schnizo_pkg::NOF_ACCELERATORS)
  ) i_stream_arbiter_offload (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .inp_data_i ({dma_resp,   hive_rsp_i.acc_resp  }),
    .inp_valid_i({dma_pvalid, hive_rsp_i.acc_pvalid}),
    .inp_ready_o({dma_pready, hive_req_o.acc_pready}),
    .oup_data_o (acc_demux_schnizo_q),
    .oup_valid_o(acc_demux_snitch_valid_q),
    .oup_ready_i(acc_demux_snitch_ready_q)
  );

  if (Xdma) begin : gen_dma
    idma_inst64_top #(
      .AxiAddrWidth   (AddrWidth),
      .AxiDataWidth   (DMADataWidth),
      .AxiIdWidth     (DMAIdWidth),
      .AxiUserWidth   (DMAUserWidth),
      .NumAxInFlight  (DMANumAxInFlight),
      .DMAReqFifoDepth(DMAReqFifoDepth),
      .NumChannels    (DMANumChannels),
      .DMATracing     (1),
      .axi_ar_chan_t  (axi_ar_chan_t),
      .axi_aw_chan_t  (axi_aw_chan_t),
      .axi_req_t      (axi_req_t),
      .axi_res_t      (axi_rsp_t),
      .acc_req_t      (acc_req_t),
      .acc_res_t      (acc_resp_t),
      .dma_events_t   (dma_events_t)
    ) i_idma_inst64_top (
      .clk_i,
      .rst_ni,
      .testmode_i     (1'b0),
      .axi_req_o      (axi_dma_req_o),
      .axi_res_i      (axi_dma_res_i),
      .busy_o         (axi_dma_busy_o),
      .acc_req_i      (acc_schnizo_req),
      .acc_req_valid_i(dma_qvalid),
      .acc_req_ready_o(dma_qready),
      .acc_res_o      (dma_resp),
      .acc_res_valid_o(dma_pvalid),
      .acc_res_ready_i(dma_pready),
      .hart_id_i      (hart_id_i),
      .events_o       (axi_dma_events_o)
    );

  // no DMA instanciated
  end else begin : gen_no_dma
    // tie-off unused signals
    assign axi_dma_req_o    = '0;
    assign axi_dma_busy_o   = '0;
    assign dma_qready       = '0;
    assign dma_resp         = '0;
    assign dma_pvalid       = '0;
    assign axi_dma_events_o = '0;
  end

  // pragma translate_off
  snitch_pkg::fpu_trace_port_t fpu_trace;
  snitch_pkg::fpu_sequencer_trace_port_t fpu_sequencer_trace;
  // pragma translate_on

  // gen_no_fpu
  assign merged_dreq = schnizo_dreq_q;
  assign schnizo_drsp_q = merged_drsp;

  // Decide whether to go to SoC or TCDM
  dreq_t data_tcdm_req;
  drsp_t data_tcdm_rsp;
  localparam int unsigned SelectWidth = cf_math_pkg::idx_width(2);
  typedef logic [SelectWidth-1:0] select_t;
  select_t slave_select;
  reqrsp_demux #(
    .NrPorts  (2),
    .req_t    (dreq_t),
    .rsp_t    (drsp_t),
    // TODO(zarubaf): Make a parameter.
    .RespDepth(4)
  ) i_reqrsp_demux (
    .clk_i,
    .rst_ni,
    .slv_select_i(slave_select),
    .slv_req_i   (merged_dreq),
    .slv_rsp_o   (merged_drsp),
    .mst_req_o   ({data_tcdm_req, data_req_o}),
    .mst_rsp_i   ({data_tcdm_rsp, data_rsp_i})
  );

  typedef struct packed {
    int unsigned idx;
    logic [AddrWidth-1:0] base;
    logic [AddrWidth-1:0] mask;
  } reqrsp_rule_t;

  reqrsp_rule_t [TCDMAliasEnable:0] addr_map;
  assign addr_map[0] = '{
    idx: 1,
    base: tcdm_addr_base_i,
    mask: ({AddrWidth{1'b1}} << TCDMAddrWidth)
  };
  if (TCDMAliasEnable) begin : gen_tcdm_alias_rule
    assign addr_map[1] = '{
      idx: 1,
      base: TCDMAliasStart,
      mask: ({AddrWidth{1'b1}} << TCDMAddrWidth)
    };
  end

  addr_decode_napot #(
    .NoIndices(2),
    .NoRules  (1 + TCDMAliasEnable),
    .addr_t   (logic [AddrWidth-1:0]),
    .rule_t   (reqrsp_rule_t)
  ) i_addr_decode_napot (
    .addr_i          (merged_dreq.q.addr),
    .addr_map_i      (addr_map),
    .idx_o           (slave_select),
    .dec_valid_o     (),
    .dec_error_o     (),
    .en_default_idx_i(1'b1),
    .default_idx_i   ('0)
  );

  tcdm_req_t core_tcdm_req;
  tcdm_rsp_t core_tcdm_rsp;

  reqrsp_to_tcdm #(
    .AddrWidth   (AddrWidth),
    .DataWidth   (DataWidth),
    // TODO(zarubaf): Make a parameter.
    .BufDepth    (4),
    .reqrsp_req_t(dreq_t),
    .reqrsp_rsp_t(drsp_t),
    .tcdm_req_t  (tcdm_req_t),
    .tcdm_rsp_t  (tcdm_rsp_t)
  ) i_reqrsp_to_tcdm (
    .clk_i,
    .rst_ni,
    .reqrsp_req_i(data_tcdm_req),
    .reqrsp_rsp_o(data_tcdm_rsp),
    .tcdm_req_o  (core_tcdm_req),
    .tcdm_rsp_i  (core_tcdm_rsp)
  );
  // gen_no_ssrs
  // Connect single TCDM port
  assign tcdm_req_o[0] = core_tcdm_req;
  assign core_tcdm_rsp = tcdm_rsp_i[0];

  // Core events for performance counters
  assign core_events_o.retired_instr = schnizo_events.retired_instr;
  assign core_events_o.retired_load  = schnizo_events.retired_load;
  assign core_events_o.retired_i     = schnizo_events.retired_i;
  assign core_events_o.retired_acc   = schnizo_events.retired_acc;
  // TODO: Rework the FPU core events. It does not exactly match the Snitch values.
  // See schnizo for more details.
  assign core_events_o.issue_fpu         = schnizo_events.issue_fpu;
  assign core_events_o.issue_fpu_seq     = schnizo_events.issue_fpu_seq;
  assign core_events_o.issue_core_to_fpu = schnizo_events.issue_core_to_fpu;

  // --------------------------
  // Tracer
  // --------------------------
  // pragma translate_off
  int f;
  string fn;
  logic [63:0] cycle;
  initial begin
    // We need to schedule the assignment into a safe region, otherwise
    // `hart_id_i` won't have a value assigned at the beginning of the first
    // delta cycle.
`ifndef VERILATOR
    #0;
`endif
    $system("mkdir logs -p");
    $sformat(fn, "logs/trace_hart_%05x.dasm", hart_id_i);
    f = $fopen(fn, "w");
    $display("[Tracer] Logging Hart %d to %s", hart_id_i, fn);
  end

  // verilog_lint: waive-start always-ff-non-blocking
  always_ff @(posedge clk_i) begin
    automatic string trace_entry;
    automatic string extras_str;
    automatic snitch_pkg::snitch_trace_port_t extras_snitch;
    automatic snitch_pkg::fpu_trace_port_t extras_fpu;
    automatic snitch_pkg::fpu_sequencer_trace_port_t extras_fpu_seq_out;

    if (rst_ni) begin
      extras_snitch = '{
        // State
        source:       snitch_pkg::SrcSnitch,
        stall:        i_schnizo.stall,
        exception:    i_schnizo.exception,
        // Decoding
        rs1:          i_schnizo.instr_decoded.rs1,
        rs2:          i_schnizo.instr_decoded.rs2,
        rd:           i_schnizo.instr_decoded.rd,
        is_load:      ~i_schnizo.i_schnizo_res_stat_lsu.is_store,
        is_store:     i_schnizo.i_schnizo_res_stat_lsu.is_store,
        is_branch:    i_schnizo.instr_decoded.is_branch,
        pc_d:         i_schnizo.pc_d,
        // Operands
        opa:          i_schnizo.fu_data.operand_a,
        opb:          i_schnizo.fu_data.operand_b,
        opa_select:   i_schnizo.instr_decoded.use_pc_as_op_a,
        opb_select:   i_schnizo.instr_decoded.use_imm_as_op_b,
        write_rd:     i_schnizo.gpr_we,
        csr_addr:     i_schnizo.inst_data_i[31:20],
        // Pipeline writeback
        writeback:    i_schnizo.gpr_wdata,
        // Load/Store
        gpr_rdata_1:  i_schnizo.gpr_rdata[1],
        ls_size:      i_schnizo.i_schnizo_res_stat_lsu.ls_size,
        ld_result_32: i_schnizo.i_schnizo_res_stat_lsu.lsu_result[31:0],
        lsu_rd:       i_schnizo.i_schnizo_res_stat_lsu.result_tag.dest_reg,
        retire_load:  '0, // i_schnizo.retire_load,
        alu_result:   i_schnizo.alu_result.result,
        // Atomics
        ls_amo:       i_schnizo.i_schnizo_res_stat_lsu.ls_amo, // i_schnizo.ls_amo,
        // Accelerator
        retire_acc:   '0, // i_schnizo.retire_acc,
        acc_pid:      '0, // i_schnizo.acc_prsp_i.id,
        acc_pdata_32: '0, // i_schnizo.acc_prsp_i.data[31:0],
        // FPU offload
        fpu_offload:
          (i_schnizo.acc_qready_i && i_schnizo.acc_qvalid_o && i_schnizo.acc_qreq_o.addr == 0),
        is_seq_insn:  (i_schnizo.inst_data_i inside {riscv_instr::FREP_I, riscv_instr::FREP_O})
      };

      if (FPEn) begin
        extras_fpu = fpu_trace;
        if (Xfrep) begin
          // Addenda to FPU extras iff popping sequencer
          extras_fpu_seq_out = fpu_sequencer_trace;
        end
      end

      cycle++;
      // Trace snitch iff:
      // we are not stalled <==> we have issued and processed an instruction (including offloads)
      // OR we are retiring (issuing a writeback from) a load or fpu instruction
      if (
          !i_schnizo.stall || // ALU and CSR always commit in the dispatch cycle
          (i_schnizo.lsu_valid_gpr & i_schnizo.lsu_ready_gpr) ||
          (i_schnizo.fpu_valid_gpr & i_schnizo.fpu_ready_gpr) ||
          (i_schnizo.lsu_valid_fpr & i_schnizo.lsu_ready_fpr) ||
          (i_schnizo.fpu_valid_fpr & i_schnizo.fpu_ready_fpr)
      ) begin
        $sformat(trace_entry, "%t %1d %8d 0x%h DASM(%h) #; %s\n",
            $time, cycle, i_schnizo.priv_lvl, i_schnizo.pc_q, i_schnizo.inst_data_i,
            // $time, cycle, i_schnizo.priv_lvl_q, i_schnizo.pc_q, i_schnizo.inst_data_i,
            snitch_pkg::print_snitch_trace(extras_snitch));
        $fwrite(f, trace_entry);
      end
      if (FPEn) begin
        // Trace FPU iff:
        // an incoming handshake on the accelerator bus occurs <==> an instruction was issued
        // OR an FPU result is ready to be written back to an FPR register or the bus
        // OR an LSU result is ready to be written back to an FPR register or the bus
        // OR an FPU result, LSU result or bus value is ready to be written back to an FPR register
        if (extras_fpu.acc_q_hs || extras_fpu.fpu_out_hs
        || extras_fpu.lsu_q_hs || extras_fpu.fpr_we) begin
          $sformat(trace_entry, "%t %1d %8d 0x%h DASM(%h) #; %s\n",
              $time, cycle, i_schnizo.priv_lvl, 32'hz, extras_fpu.op_in,
              // $time, cycle, i_schnizo.priv_lvl_q, 32'hz, extras_fpu.op_in,
              snitch_pkg::print_fpu_trace(extras_fpu));
          $fwrite(f, trace_entry);
        end
        // sequencer instructions
        if (Xfrep) begin
          if (extras_fpu_seq_out.cbuf_push) begin
            $sformat(trace_entry, "%t %1d %8d 0x%h DASM(%h) #; %s\n",
                $time, cycle, i_schnizo.priv_lvl, 32'hz, 64'hz,
                // $time, cycle, i_schnizo.priv_lvl_q, 32'hz, 64'hz,
                snitch_pkg::print_fpu_sequencer_trace(extras_fpu_seq_out));
            $fwrite(f, trace_entry);
          end
        end
      end
    end else begin
      cycle = '0;
    end
  end

  final begin
    $fclose(f);
  end
  // verilog_lint: waive-stop always-ff-non-blocking
  // pragma translate_on

  `ASSERT_INIT(BootAddrAligned, BootAddr[1:0] == 2'b00)

endmodule
