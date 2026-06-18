// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// pragma translate_off

// Schnizo core tracer.
module schnova_tracer import schnova_pkg::*, schnova_tracer_pkg::*; #(
  parameter bit UseFreeList = 1,
  parameter int unsigned PipeWidth  = 1,
  parameter int unsigned NofAlus    = 3,
  parameter int unsigned NofLsus    = 1,
  parameter int unsigned NofFpus    = 1,
  parameter int unsigned AluNofRss  = 3,
  parameter int unsigned LsuNofRss  = 2,
  parameter int unsigned FpuNofRss  = 4,
  parameter int unsigned NofOperandIfs = 1,
  parameter bit          EnableAllocTrace = 1,
  parameter int unsigned NofPhysGpr = 64,
  parameter int unsigned NofPhysFpr = 64,
  parameter bit          XFREPO     = 1
) (
  input  logic clk_i,
  input  logic rst_i,
  input  logic [31:0] hart_id_i,
  input  core_trace_t             core_trace,
  input  dispatch_trace_t         si_dispatch_trace,
  input  dispatch_trace_t         rs_dispatch_trace[PipeWidth],
  input  disp_req_trace_t         alu_disp_req_trace[NofAlus],
  input  disp_req_trace_t         lsu_disp_req_trace[NofLsus],
  input  disp_req_trace_t         fpu_disp_req_trace[NofFpus],
  input  issue_alu_trace_t        alu_trace [NofAlus],
  input  issue_lsu_trace_t        lsu_trace [NofLsus],
  input  issue_fpu_trace_t        fpu_trace [NofFpus],
  input  issue_alu_trace_t        rss_alu_traces [NofAlus][AluNofRss],
  input  issue_lsu_trace_t        rss_lsu_traces [NofLsus][LsuNofRss],
  input  issue_fpu_trace_t        rss_fpu_traces [NofFpus][FpuNofRss],
  input  issue_csr_trace_t        csr_trace,
  input  issue_acc_trace_t        acc_trace,
  input  retire_fu_trace_t        alu_retirements [NofAlus],
  input  retire_fu_trace_t        lsu_load_retirements [NofLsus],
  input  retire_fu_trace_t        lsu_store_retirements [NofLsus],
  input  retire_fu_trace_t        fpu_retirements [NofFpus],
  input  retire_fu_trace_t        csr_retirement,
  input  retire_fu_trace_t        acc_retirement,
  input  wb_fu_trace_t            alu_wb_trace [NofAlus],
  input  wb_fu_trace_t            lsu_wb_trace [NofLsus],
  input  wb_fu_trace_t            fpu_wb_trace [NofFpus],
  input  wb_fu_trace_t            csr_wb_trace,
  input  wb_fu_trace_t            acc_wb_trace
);

  // The tracer first extracts all signals of interest and groups them by functional unit.
  // It also distinguishs between signal groups for regular and FREP exection.
  // The second part then emits a trace entry if the current signal group is valid (active).
  // The signal group validity depends on the handshake as well as the core state.
  // We start with result requests then issuing events and end with the writeback events.
  // This helps to order the events for postprocessing.

  int file_id;
  string file_name;
  logic [63:0] cycle;
  initial begin
    // We need to schedule the assignment into a safe region, otherwise
    // `hart_id_i` won't have a value assigned at the beginning of the first
    // delta cycle.
`ifndef VERILATOR
    #0;
`endif // VERILATOR
    $system("mkdir logs -p");
    $sformat(file_name, "logs/sz_trace_hart_%05x.dasm", hart_id_i);
    file_id = $fopen(file_name, "w");
    $display("[Tracer] Logging Hart %d to %s", hart_id_i, file_name);
  end

  // During LCP the dispatch & trace generation is at least one cycle apart. For the LSU it can
  // even take longer (until the memory accepted the request).
  // If there is a dispatch during LCP, push the details into a queue for each FU.
  // When the FU issues, pop from the queue and generate the trace.
  typedef struct {
    string header;
    dispatch_trace_t dispatch_trace;
  } dispatch_detail_t;

  localparam integer unsigned NofFus = NofAlus + NofLsus + NofFpus;

  integer unsigned max_nof_allocated_rss [NofFus];
  integer unsigned cur_nof_allocated_rss [NofFus];
  integer unsigned max_nof_allocated_rob_entries;
  integer unsigned cur_nof_allocated_rob_entries;
  integer unsigned max_nof_allocated_gpr;
  integer unsigned cur_nof_allocated_gpr;
  integer unsigned max_nof_allocated_fpr;
  integer unsigned cur_nof_allocated_fpr;


  // Shadow Queues to mirror the dispatch hardware buffers
  dispatch_detail_t alu_shadow_q[$];
  dispatch_detail_t lsu_shadow_q[$];
  dispatch_detail_t fpu_shadow_q[$];
  dispatch_detail_t dispatch_queue[NofFus][$];

  // verilog_lint: waive-start always-ff-non-blocking
  always_ff @(posedge clk_i) begin
    string trace_header;
    string dispatch_event;
    string alu_dispatch_event[NofAlus];
    string lsu_dispatch_event[NofLsus];
    string fpu_dispatch_event[NofFpus];
    dispatch_detail_t details[PipeWidth];
    dispatch_detail_t alu_disp_req_details[NofAlus];
    dispatch_detail_t lsu_disp_req_details[NofLsus];
    dispatch_detail_t fpu_disp_req_details[NofFpus];
    dispatch_detail_t alu_dep_details[NofAlus];
    dispatch_detail_t lsu_dep_details[NofLsus];
    dispatch_detail_t fpu_dep_details[NofFpus];

    if (~rst_i) begin
      cycle++;

      // Always generate the core trace. This trace serves as the basis of the trace event.
      // This trace is extended with the details of the active FU.
      trace_header = format_trace_header($time, cycle, core_trace);

      for (int unsigned i = 0; i < PipeWidth; i++) begin
        details[i] = '{
          header: trace_header,
          dispatch_trace: rs_dispatch_trace[i]
        };

        if (rs_dispatch_trace[i].valid && (core_trace.loop_state inside {LoopDep})) begin
          unique case (i_dispatcher.instr_dec_i[i].fu)
            schnova_pkg::MUL,
            schnova_pkg::CTRL_FLOW,
            schnova_pkg::ALU:       alu_shadow_q.push_back(details[i]);
            schnova_pkg::LOAD,
            schnova_pkg::STORE:     lsu_shadow_q.push_back(details[i]);
            schnova_pkg::FPU:       fpu_shadow_q.push_back(details[i]);
          endcase
        end
      end

      for (int unsigned alu = 0; alu < NofAlus; alu++) begin
        if (alu_disp_req_trace[alu].valid && (core_trace.loop_state inside {LoopDep})) begin
          alu_disp_req_details[alu] = alu_shadow_q.pop_front();
          alu_disp_req_details[alu].dispatch_trace.disp_resp = alu_disp_req_trace[alu].disp_resp;
          dispatch_queue[alu_disp_req_trace[alu].rs_id].push_back(alu_disp_req_details[alu]);
        end
      end

      for (int unsigned lsu = 0; lsu < NofLsus; lsu++) begin
        if (lsu_disp_req_trace[lsu].valid && (core_trace.loop_state inside {LoopDep})) begin
          lsu_disp_req_details[lsu] = lsu_shadow_q.pop_front();
          lsu_disp_req_details[lsu].dispatch_trace.disp_resp = lsu_disp_req_trace[lsu].disp_resp;
          dispatch_queue[lsu_disp_req_trace[lsu].rs_id].push_back(lsu_disp_req_details[lsu]);
        end
      end

      for (int unsigned fpu = 0; fpu < NofFpus; fpu++) begin
        if (fpu_disp_req_trace[fpu].valid && (core_trace.loop_state inside {LoopDep})) begin
          fpu_disp_req_details[fpu] = fpu_shadow_q.pop_front();
          fpu_disp_req_details[fpu].dispatch_trace.disp_resp = fpu_disp_req_trace[fpu].disp_resp;
          dispatch_queue[fpu_disp_req_trace[fpu].rs_id].push_back(fpu_disp_req_details[fpu]);
        end
      end

      // Trace events are active depending on CPU states.
      if (!(core_trace.loop_state inside {LoopDep})) begin
        // Format the single dispatch event and append all single issue requests. There should
        // only be one active single issue request. The format functions return "" if the trace is
        // not valid. Therefore, we can combine the formatting functions into one chain.
        // The naked dispatch_event contains the None FU dispatches (currently only for FREP).
        dispatch_event = format_dispatch_extras(si_dispatch_trace);

        for (int alu = 0; alu < NofAlus; alu++) begin
          dispatch_event = $sformatf("%s%s", dispatch_event, format_alu_trace(alu_trace[alu]));
        end
        for (int lsu = 0; lsu < NofLsus; lsu++) begin
          dispatch_event = $sformatf("%s%s", dispatch_event, format_lsu_trace(lsu_trace[lsu]));
        end
        for (int fpu = 0; fpu < NofFpus; fpu++) begin
          dispatch_event = $sformatf("%s%s", dispatch_event, format_fpu_trace(fpu_trace[fpu]));
        end
        dispatch_event = $sformatf("%s%s", dispatch_event, format_csr_trace(csr_trace));
        dispatch_event = $sformatf("%s%s", dispatch_event, format_acc_trace(acc_trace));

        write_trace_event(file_id, trace_header, "dispatch", dispatch_event, si_dispatch_trace.valid);
      end else begin
        // Format the single dispatch event but capture the producer by taking RSS issue trace.
        // There should also be one FU issue request active. Invalid traces are formated as "".
          for (int alu = 0; alu < NofAlus; alu++) begin
            for (int rss = 0; rss < AluNofRss; rss++) begin
              if (rss_alu_traces[alu][rss].valid) begin
                alu_dep_details[alu] = dispatch_queue[alu].pop_front();
                alu_dispatch_event[alu] = format_dispatch_extras(alu_dep_details[alu].dispatch_trace);
                alu_dispatch_event[alu] = $sformatf("%s%s", alu_dispatch_event[alu],
                                          format_alu_trace(rss_alu_traces[alu][rss]));
                write_trace_event(file_id, alu_dep_details[alu].header, "dispatch",
                                  alu_dispatch_event[alu], alu_dep_details[alu].dispatch_trace.valid);
              end
            end
          end

          for (int lsu = 0; lsu < NofLsus; lsu++) begin
            for (int rss = 0; rss < LsuNofRss; rss++) begin
              if (rss_lsu_traces[lsu][rss].valid) begin
                lsu_dep_details[lsu] = dispatch_queue[NofAlus + lsu].pop_front();
                lsu_dispatch_event[lsu] = format_dispatch_extras(lsu_dep_details[lsu].dispatch_trace);

                lsu_dispatch_event[lsu] = $sformatf("%s%s", lsu_dispatch_event[lsu],
                                          format_lsu_trace(rss_lsu_traces[lsu][rss]));
                write_trace_event(file_id, lsu_dep_details[lsu].header, "dispatch",
                                  lsu_dispatch_event[lsu], lsu_dep_details[lsu].dispatch_trace.valid);
              end
            end
          end

          for (int fpu = 0; fpu < NofFpus; fpu++) begin
            for (int rss = 0; rss < FpuNofRss; rss++) begin
              if (rss_fpu_traces[fpu][rss].valid) begin
                fpu_dep_details[fpu] = dispatch_queue[NofAlus + NofLsus + fpu].pop_front();
                fpu_dispatch_event[fpu] = format_dispatch_extras(fpu_dep_details[fpu].dispatch_trace);

                fpu_dispatch_event[fpu] = $sformatf("%s%s", fpu_dispatch_event[fpu],
                                          format_fpu_trace(rss_fpu_traces[fpu][rss]));
                write_trace_event(file_id, fpu_dep_details[fpu].header, "dispatch",
                                  fpu_dispatch_event[fpu], fpu_dep_details[fpu].dispatch_trace.valid);
              end
            end
          end

        // CSR and ACC instructions are not supported in FREP but can still execute (fallback in
        // hw loop mode). These are not cut and thus dispatch immediately.
        dispatch_event = format_dispatch_extras(si_dispatch_trace);
        dispatch_event = $sformatf("%s%s", dispatch_event, format_csr_trace(csr_trace));
        dispatch_event = $sformatf("%s%s", dispatch_event, format_acc_trace(acc_trace));

        write_trace_event(file_id, trace_header, "dispatch", dispatch_event,
                          si_dispatch_trace.valid && (csr_trace.valid || acc_trace.valid));
      end
      // Writeback events - We must consider all writebacks at all times.
      for (int alu = 0; alu < NofAlus; alu++) begin
        write_trace_event(file_id, trace_header, "writeback",
                          format_wb_fu_trace(alu_wb_trace[alu], "ALU"),
                          alu_wb_trace[alu].valid);
      end
      for (int lsu = 0; lsu < NofLsus; lsu++) begin
        write_trace_event(file_id, trace_header, "writeback",
                          format_wb_fu_trace(lsu_wb_trace[lsu], "LSU"),
                          lsu_wb_trace[lsu].valid);
      end
      for (int fpu = 0; fpu < NofFpus; fpu++) begin
        write_trace_event(file_id, trace_header, "writeback",
                          format_wb_fu_trace(fpu_wb_trace[fpu], "FPU"),
                          fpu_wb_trace[fpu].valid);
      end
      write_trace_event(file_id, trace_header, "writeback",
                        format_wb_fu_trace(csr_wb_trace, "CSR"),
                        csr_wb_trace.valid);
      write_trace_event(file_id, trace_header, "writeback",
                        format_wb_fu_trace(acc_wb_trace, "ACC"),
                        acc_wb_trace.valid);

      // Retirement events - Always active to complete any issue.
      for (int alu = 0; alu < NofAlus; alu++) begin
        write_trace_event(file_id, trace_header, "retirement",
                          format_fu_retire_trace(alu_retirements[alu], 1'b0),
                          alu_retirements[alu].valid);
      end
      for (int lsu = 0; lsu < NofLsus; lsu++) begin
        write_trace_event(file_id, trace_header, "retirement",
                          format_fu_retire_trace(lsu_load_retirements[lsu], 1'b1),
                          lsu_load_retirements[lsu].valid);
        write_trace_event(file_id, trace_header, "retirement",
                          format_fu_retire_trace(lsu_store_retirements[lsu], 1'b0),
                          lsu_store_retirements[lsu].valid);
      end
      for (int fpu = 0; fpu < NofFpus; fpu++) begin
        write_trace_event(file_id, trace_header, "retirement",
                          format_fu_retire_trace(fpu_retirements[fpu], 1'b0),
                          fpu_retirements[fpu].valid);
      end
      write_trace_event(file_id, trace_header, "retirement",
                        format_fu_retire_trace(csr_retirement, 1'b0),
                        csr_retirement.valid);
      write_trace_event(file_id, trace_header, "retirement",
                        format_fu_retire_trace(acc_retirement, 1'b0),
                        acc_retirement.valid);


      if (EnableAllocTrace) begin
        // Check the allocation counter of the reservation station slots
        for (int alu = 0; alu < NofAlus; alu++) begin
          if (max_nof_allocated_rss[alu] < cur_nof_allocated_rss[alu]) begin
            max_nof_allocated_rss[alu] = cur_nof_allocated_rss[alu];
          end
        end

        for (int lsu = 0; lsu < NofLsus; lsu++) begin
          if (max_nof_allocated_rss[lsu+NofAlus] < cur_nof_allocated_rss[lsu+NofAlus]) begin
            max_nof_allocated_rss[lsu+NofAlus] = cur_nof_allocated_rss[lsu+NofAlus];
          end
        end

        for (int fpu = 0; fpu < NofFpus; fpu++) begin
          if (max_nof_allocated_rss[fpu+NofAlus+NofLsus] < cur_nof_allocated_rss[fpu+NofAlus+NofLsus]) begin
            max_nof_allocated_rss[fpu+NofAlus+NofLsus] = cur_nof_allocated_rss[fpu+NofAlus+NofLsus];
          end
        end

        // check the rob allocation entry
        if (max_nof_allocated_rob_entries < cur_nof_allocated_rob_entries) begin
          max_nof_allocated_rob_entries = cur_nof_allocated_rob_entries;
        end
        // Check the free list counters
        if (max_nof_allocated_gpr < cur_nof_allocated_gpr) begin
          max_nof_allocated_gpr = cur_nof_allocated_gpr;
        end

        if (max_nof_allocated_fpr < cur_nof_allocated_fpr) begin
          max_nof_allocated_fpr = cur_nof_allocated_fpr;
        end
      end
    end else begin
      cycle = '0;
      max_nof_allocated_rss = '{ default: '0};
      max_nof_allocated_rob_entries = '0;
      max_nof_allocated_fpr = '0;
      max_nof_allocated_gpr = '0;
      alu_shadow_q.delete();
      lsu_shadow_q.delete();
      fpu_shadow_q.delete();
    end
  end

  if (XFREPO) begin
    // verilog_lint: waive-start line-length
    for (genvar alu = 0; alu < NofAlus; alu++) begin: gen_cur_alu_rss_alloc
      assign cur_nof_allocated_rss[alu] = i_fu_stage.gen_alus[alu].gen_rs.i_res_stat.num_allocated_rss_q;
    end
    for (genvar lsu = 0; lsu < NofLsus; lsu++) begin: gen_cur_lsu_rss_alloc
      assign cur_nof_allocated_rss[NofAlus+lsu] = i_fu_stage.gen_lsus[lsu].gen_rs.i_res_stat.num_allocated_rss_q;
    end
    for (genvar fpu = 0; fpu < NofFpus; fpu++) begin: gen_cur_fpu_rss_alloc
      assign cur_nof_allocated_rss[NofAlus+NofLsus+fpu] = i_fu_stage.gen_fpus[fpu].gen_rs.i_res_stat.num_allocated_rss_q;
    end
    // verilog_lint: waive-stop line-length
    if (UseFreeList) begin
      assign cur_nof_allocated_rob_entries = gen_phys_reg_manage.gen_freelist_reg_manage.i_rob.allocated_entries;
      assign cur_nof_allocated_gpr = NofPhysGpr - gen_phys_reg_manage.gen_freelist_reg_manage.i_gpr_free_list.free_count;
      assign cur_nof_allocated_fpr = NofPhysFpr - gen_phys_reg_manage.gen_freelist_reg_manage.i_fpr_free_list.free_count;
    end else begin
      assign cur_nof_allocated_rob_entries = '0; // There is no ROB in this design
      assign cur_nof_allocated_gpr = NofPhysGpr - gen_phys_reg_manage.gen_refcount_reg_manage.i_refcount.gpr_free_count;
      assign cur_nof_allocated_fpr = NofPhysFpr - gen_phys_reg_manage.gen_refcount_reg_manage.i_refcount.fpr_free_count;
    end
  end else begin
    assign cur_nof_allocated_rss = '{default: '0};
    assign cur_nof_allocated_rob_entries = '0;
    assign cur_nof_allocated_gpr = 32;
    assign cur_nof_allocated_fpr = 32;
  end

  final begin
    if (EnableAllocTrace) begin
      string msg;
      int alloc_file_id;
      string alloc_file_name;

      msg = "";

      for (int alu = 0; alu < NofAlus; alu++) begin
        msg = {msg, $sformatf("ALU%0d value=%0d\n", alu, max_nof_allocated_rss[alu])};
      end

      for (int lsu = 0; lsu < NofLsus; lsu++) begin
        msg = {msg, $sformatf("LSU%0d value=%0d\n", lsu, max_nof_allocated_rss[NofAlus+lsu])};
      end

      for (int fpu = 0; fpu < NofFpus; fpu++) begin
        msg = {msg, $sformatf("FPU%0d value=%0d\n", fpu, max_nof_allocated_rss[NofAlus+NofLsus+fpu])};
      end

      msg = {msg, $sformatf("ROB value=%0d\n", max_nof_allocated_rob_entries)};
      msg = {msg, $sformatf("GPR value=%0d\n", max_nof_allocated_gpr)};
      msg = {msg, $sformatf("FPR value=%0d\n", max_nof_allocated_fpr)};

      // Write the allocation metrics to a file
      $sformat(alloc_file_name, "logs/alloc_metrics_hart_%05x.txt", hart_id_i);
      alloc_file_id = $fopen(alloc_file_name, "w");
      $fwrite(alloc_file_id, msg);
    end
    $fclose(file_id);
  end

endmodule

// pragma translate_on
