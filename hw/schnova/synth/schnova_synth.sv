// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnova_synth #(
	parameter bit          XFREPI				= 1'b1,
	parameter bit          XFREPO				= 1'b1,
	parameter int unsigned NofAlus              = 3,
	parameter int unsigned NofLsus              = 3,
	parameter int unsigned NofFpus              = 1,
	parameter int unsigned NofAluBufEntries     = 1,
	parameter int unsigned NofLsuBufEntries     = 1,
	parameter int unsigned NofFpuBufEntries     = 1,
	parameter int unsigned AluNofRss            = 4,
	parameter int unsigned LsuNofRss            = 4,
	parameter int unsigned FpuNofRss            = 4,
  parameter int unsigned ICacheFetchDataWidth = 32,
  parameter int unsigned NofPhysGpr           = 6,
	parameter int unsigned NofPhysFpr           = 6,
	parameter int unsigned NofRobEntries        = 32,
	parameter bit          UseFreeList          = 1,
	parameter bit          MulInAlu0            = 1'b1,
	localparam int unsigned PhysRegAddrSize = $clog2((NofPhysFpr > NofPhysGpr) ? NofPhysFpr : NofPhysGpr),
	localparam type 	   acc_req_t            = struct packed {
        snitch_pkg::acc_addr_e      addr;
        logic [PhysRegAddrSize-1:0] id;
        logic [31:0]                data_op;
        schnova_synth_pkg::data_t   data_arga;
        schnova_synth_pkg::data_t   data_argb;
        schnova_synth_pkg::addr_t   data_argc;
    },
    localparam type        acc_resp_t          = struct packed {
        logic [PhysRegAddrSize-1:0] id;
        logic       				error;
        schnova_synth_pkg::data_t   data;
    }
) (
	input  logic                                       clk_i,
	input  logic                                       rst_ni,
	input  logic [31:0]                                hart_id_i,
	input  snitch_pkg::interrupts_t                    irq_i,
	output logic                                       flush_i_valid_o,
	input  logic                                       flush_i_ready_i,
	output schnizo_synth_pkg::addr_t                   inst_addr_o,
	output logic                                       inst_cacheable_o,
	input  logic [ICacheFetchDataWidth-1:0]            inst_data_i,
	output logic                                       inst_valid_o,
	input  logic                                       inst_ready_i,
	output acc_req_t                				   acc_qreq_o,
	output logic                                       acc_qvalid_o,
	input  logic                                       acc_qready_i,
	input  acc_resp_t               				   acc_prsp_i,
	input  logic                                       acc_pvalid_i,
	output logic                                       acc_pready_o,
	output schnizo_synth_pkg::data_req_t [NofLsus-1:0] data_req_o,
	input  schnizo_synth_pkg::data_rsp_t [NofLsus-1:0] data_rsp_i,
	output snitch_pkg::core_events_t                   core_events_o,
	output logic                                       barrier_o,
	input  logic                                       barrier_i
);

	schnova #(
		.BootAddr(schnova_synth_pkg::BootAddr),
		.AddrWidth(schnova_synth_pkg::AddrWidth),
		.DataWidth(schnova_synth_pkg::DataWidth),
		.XFREPI(XFREPI),
		.XFREPO(XFREPO),
		.Xdma(0),
		.RVF(1),
		.RVD(1),
		.XF16(0),
		.XF16ALT(0),
		.XF8(0),
		.XF8ALT(0),
		.XFVEC(0),
		.FLEN(schnova_synth_pkg::FLEN),
    	.ICacheFetchDataWidth  (ICacheFetchDataWidth),
		.dreq_t(schnova_synth_pkg::data_req_t),
		.drsp_t(schnova_synth_pkg::data_rsp_t),
		.acc_req_t(acc_req_t),
		.acc_resp_t(acc_resp_t),
		.NofAlus(NofAlus),
		.NofLsus(NofLsus),
		.NofFpus(NofFpus),
 		.NofAluBufEntries(NofAluBufEntries),
 		.NofLsuBufEntries(NofLsuBufEntries),
 		.NofFpuBufEntries(NofFpuBufEntries),
		.AluNofRss(AluNofRss),
		.LsuNofRss(LsuNofRss),
		.FpuNofRss(FpuNofRss),
		.MulInAlu0(MulInAlu0),
		.NumOutstandingLoads(schnova_synth_pkg::NumIntOutstandingLoads),
		.NumOutstandingMem(schnova_synth_pkg::NumIntOutstandingMem),
		.NofPhysGpr(NofPhysGpr),
		.NofPhysFpr(NofPhysFpr),
    	.PhysRegAddrSize(PhysRegAddrSize),
    	.NofRobEntries(NofRobEntries),
		.UseFreeList(UseFreeList),
		.SnitchPMACfg(snitch_cluster_pkg::SnitchPMACfg),
		.CaqDepth(8),
		.CaqTagWidth(16),
		.DebugSupport(0),
		.FPUImplementation(snitch_cluster_pkg::FPUImplementation[0]),
		.RegisterFPUIn(0),
		.RegisterFPUOut(0)
	) i_schnova (
		.clk_i,
		.rst_i(!rst_ni),
		.hart_id_i,
		.irq_i,
		.flush_i_valid_o,
		.flush_i_ready_i,
		.inst_addr_o,
		.inst_cacheable_o,
		.inst_data_i,
		.inst_valid_o,
		.inst_ready_i,
		.acc_qreq_o,
		.acc_qvalid_o,
		.acc_qready_i,
		.acc_prsp_i,
		.acc_pvalid_i,
		.acc_pready_o,
		.data_req_o,
		.data_rsp_i,
		.core_events_o,
		.barrier_o,
		.barrier_i
	);

endmodule