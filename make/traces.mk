# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
#
# Luca Colagrande <colluca@iis.ee.ethz.ch>

##########
# Traces #
##########

# Reads the binary from the logs/.rtlbinary file that is written at start
# of simulation in the vsim script
SN_BINARY ?= $(shell cat $(SN_SIM_DIR)/.rtlbinary)

# Schnizo traces
SN_DASM_TRACES      = $(shell (ls $(SN_LOGS_DIR)/sz_trace_hart_*.dasm 2>/dev/null))
SN_TXT_TRACES       = $(shell (echo $(SN_DASM_TRACES) | sed 's/\.dasm/\.txt/g'))
SN_ANNOTATED_TRACES = $(shell (echo $(SN_DASM_TRACES) | sed 's/\.dasm/\.s/g'))
SN_PERF_DUMPS       = $(shell (echo $(SN_DASM_TRACES) | sed 's/sz_trace_hart/sz_hart/g' | sed 's/.dasm/_perf.json/g'))

SN_DMA_PERF_DUMPS   = $(SN_LOGS_DIR)/dma_*_perf.json

SN_JOINT_PERF_DUMP  = $(SN_LOGS_DIR)/perf.json
SN_ROI_DUMP         = $(SN_LOGS_DIR)/roi.json
SN_VISUAL_TRACE     = $(SN_LOGS_DIR)/trace.json

# Schnova traces
SV_DASM_TRACES      = $(shell (ls $(SN_LOGS_DIR)/sv_trace_hart_*.dasm 2>/dev/null))
SV_TXT_TRACES       = $(shell (echo $(SV_DASM_TRACES) | sed 's/\.dasm/\.txt/g'))
SV_ANNOTATED_TRACES = $(shell (echo $(SV_DASM_TRACES) | sed 's/\.dasm/\.s/g'))
SV_PERF_DUMPS       = $(shell (echo $(SV_DASM_TRACES) | sed 's/sv_trace_hart/sv_hart/g' | sed 's/.dasm/_perf.json/g'))

SV_JOINT_PERF_DUMP  = $(SN_LOGS_DIR)/sv_perf.json
SV_ROI_DUMP         = $(SN_LOGS_DIR)/sv_roi.json
SV_VISUAL_TRACE     = $(SN_LOGS_DIR)/sv_trace.json

SN_VISUALIZE_PY_FLAGS += --tracevis "$(SN_BINARY) $(SN_TXT_TRACES) --addr2line $(SN_ADDR2LINE) -f snitch"
SV_VISUALIZE_PY_FLAGS += --tracevis "$(SN_BINARY) $(SV_TXT_TRACES) --addr2line $(SN_ADDR2LINE) -f snitch"
SN_GENTRACE_PY_FLAGS  += --mc-exec $(SN_RISCV_MC) --mc-flags "$(SN_RISCV_MC_FLAGS)"

# Do not suspend trace generation upon gentrace errors when debugging
ifeq ($(DEBUG),ON)
SN_GENTRACE_PY_FLAGS += --permissive
endif

.PHONY: sn-traces sn-annotate sn-visual-trace sn-clean-traces sn-clean-annotate sn-clean-perf sn-clean-visual-trace \
				sv-traces sv-annotate sv-visual-trace sv-clean-traces sv-clean-annotate sv-clean-perf sv-clean-visual-trace

sn-traces: $(SN_TXT_TRACES)
sn-annotate: $(SN_ANNOTATED_TRACES)
sn-perf: $(SN_JOINT_PERF_DUMP)
sn-roi: $(SN_ROI_DUMP)
sn-visual-trace: $(SN_VISUAL_TRACE)
sn-clean-traces:
	rm -f $(SN_TXT_TRACES) $(SN_PERF_DUMPS) $(SN_DMA_PERF_DUMPS)
sn-clean-annotate:
	rm -f $(SN_ANNOTATED_TRACES)
sn-clean-perf:
	rm -f $(SN_JOINT_PERF_DUMP)
sn-clean-visual-trace:
	rm -f $(SN_VISUAL_TRACE)


sv-traces: $(SV_TXT_TRACES)
sv-annotate: $(SV_ANNOTATED_TRACES)
sv-perf: $(SV_JOINT_PERF_DUMP)
sv-roi: $(SV_ROI_DUMP)
sv-visual-trace: $(SV_VISUAL_TRACE)
sv-clean-traces:
	rm -f $(SV_TXT_TRACES) $(SV_PERF_DUMPS) $(SN_DMA_PERF_DUMPS)
sv-clean-annotate:
	rm -f $(SV_ANNOTATED_TRACES)
sv-clean-perf:
	rm -f $(SV_JOINT_PERF_DUMP)
sv-clean-visual-trace:
	rm -f $(SV_VISUAL_TRACE)


$(addprefix $(SN_LOGS_DIR)/,sz_trace_hart_%.txt sz_hart_%_perf.json dma_%_perf.json): $(SN_LOGS_DIR)/sz_trace_hart_%.dasm $(SN_GENTRACE_PY) $(SN_GENTRACE_SRC)
	$(SN_GENTRACE_PY) $< $(SN_GENTRACE_PY_FLAGS) --dma-trace $(SN_SIM_DIR)/dma_trace_$*_00000.log --dump-hart-perf $(SN_LOGS_DIR)/sz_hart_$*_perf.json --dump-dma-perf $(SN_LOGS_DIR)/dma_$*_perf.json --perfetto-trace $(SN_LOGS_DIR)/sz_perfetto_hart_$*.tb -o $(SN_LOGS_DIR)/sz_trace_hart_$*.txt

# Generate source-code interleaved traces for all harts
$(SN_LOGS_DIR)/sz_trace_hart_%.s: $(SN_LOGS_DIR)/sz_trace_hart_%.txt $(SN_ANNOTATE_PY) $(SN_ANNOTATE_SRC)
	$(SN_ANNOTATE_PY) $(SN_ANNOTATE_FLAGS) -o $@ $(SN_BINARY) $<
$(SN_LOGS_DIR)/sz_trace_hart_%.diff: $(SN_LOGS_DIR)/sz_trace_hart_%.txt $(SN_ANNOTATE_PY) $(SN_ANNOTATE_SRC)
	$(SN_ANNOTATE_PY) $(SN_ANNOTATE_FLAGS) -o $@ $(SN_BINARY) $< -d

$(SN_JOINT_PERF_DUMP): $(SN_PERF_DUMPS) $(SN_JOIN_PY)
	$(SN_JOIN_PY) -i $(shell ls $(SN_LOGS_DIR)/*_perf.json) -o $@

$(SN_ROI_DUMP): $(SN_JOINT_PERF_DUMP) $(SN_ROI_SPEC) $(SN_ROI_PY)
	$(SN_ROI_PY) $(SN_JOINT_PERF_DUMP) $(SN_ROI_SPEC) --cfg $(SN_CFG) -o $@

$(SN_VISUAL_TRACE): $(SN_ROI_DUMP) $(SN_VISUALIZE_PY)
	$(SN_VISUALIZE_PY) $(SN_ROI_DUMP) $(SN_VISUALIZE_PY_FLAGS) -o $@


$(addprefix $(SN_LOGS_DIR)/,sv_trace_hart_%.txt sv_hart_%_perf.json): $(SN_LOGS_DIR)/sv_trace_hart_%.dasm $(SV_GENTRACE_PY) $(SV_GENTRACE_SRC)
	$(SV_GENTRACE_PY) $< $(SN_GENTRACE_PY_FLAGS) --dma-trace $(SN_SIM_DIR)/dma_trace_$*_00000.log --dump-hart-perf $(SN_LOGS_DIR)/sv_hart_$*_perf.json --dump-dma-perf $(SN_LOGS_DIR)/dma_$*_perf.json --perfetto-trace $(SN_LOGS_DIR)/sv_perfetto_hart_$*.tb -o $(SN_LOGS_DIR)/sv_trace_hart_$*.txt

# Generate source-code interleaved traces for all harts
$(SN_LOGS_DIR)/sv_trace_hart_%.s: $(SN_LOGS_DIR)/sv_trace_hart_%.txt $(SN_ANNOTATE_PY) $(SN_ANNOTATE_SRC)
	$(SN_ANNOTATE_PY) $(SV_ANNOTATE_FLAGS) -o $@ $(SN_BINARY) $<
$(SN_LOGS_DIR)/sv_trace_hart_%.diff: $(SN_LOGS_DIR)/sv_trace_hart_%.txt $(SN_ANNOTATE_PY) $(SN_ANNOTATE_SRC)
	$(SN_ANNOTATE_PY) $(SV_ANNOTATE_FLAGS) -o $@ $(SN_BINARY) $< -d

$(SV_JOINT_PERF_DUMP): $(SV_PERF_DUMPS) $(SN_JOIN_PY)
	$(SN_JOIN_PY) -i $(shell ls $(SN_LOGS_DIR)/*_perf.json) -o $@

$(SV_ROI_DUMP): $(SV_JOINT_PERF_DUMP) $(SN_ROI_SPEC) $(SN_ROI_PY)
	$(SN_ROI_PY) $(SV_JOINT_PERF_DUMP) $(SN_ROI_SPEC) --cfg $(SN_CFG) -o $@

$(SV_VISUAL_TRACE): $(SV_ROI_DUMP) $(SN_VISUALIZE_PY)
	$(SN_VISUALIZE_PY) $(SV_ROI_DUMP) $(SV_VISUALIZE_PY_FLAGS) -o $@