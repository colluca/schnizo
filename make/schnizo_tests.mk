# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# Custom make targets to build and run:
#   vfu-tests           ? all sw/tests/src/vfu_test_*.c tests
#   spatz-isa-tests     ? spatz rv64uv ISA tests (hw/spatz/sw/riscvTests/isa/rv64uv/)
#   schnizo-extra-tests ? schnizo-specific SIMD tests (sw/spatz-isa-tests/schnizo_extra.c)
#
# Usage:
#   make vfu-tests-build              # compile ELFs only
#   make vfu-tests                    # compile + run with vsim
#   make spatz-isa-tests-build        # compile ELFs only
#   make spatz-isa-tests              # compile + run with vsim
#   make schnizo-extra-tests-build    # compile ELF only
#   make schnizo-extra-tests          # compile + run with vsim
#
# Override the simulator: SN_TESTS_SIM=verilator make vfu-tests

SN_TESTS_SIM   ?= vsim
SN_TESTS_RUN_PY = $(SN_ROOT)/util/experiments/run.py

###############
#  VFU Tests  #
###############

# Subset of the already-defined SN_TEST_NAMES that start with vfu_test_
SN_VFU_TEST_NAMES = $(filter vfu_test_%,$(SN_TEST_NAMES))
SN_VFU_TEST_ELFS  = $(addprefix $(SN_TESTS_BUILDDIR)/,$(addsuffix .elf,$(SN_VFU_TEST_NAMES)))

SN_VFU_TESTLIST  = $(SN_ROOT)/test/vfu_tests.yaml
SN_VFU_RUNS_DIR  = $(SN_SIM_DIR)/runs/vfu-tests

$(SN_VFU_RUNS_DIR):
	mkdir -p $@

.PHONY: vfu-tests-build vfu-tests-run vfu-tests

vfu-tests-build: $(SN_VFU_TEST_ELFS)

vfu-tests-run: $(SN_VFU_TEST_ELFS) $(SN_VSIM_BINARY) | $(SN_VFU_RUNS_DIR)
	PATH=$(SN_BIN_DIR):$$PATH \
	python3 $(SN_TESTS_RUN_PY) $(SN_VFU_TESTLIST) \
	    --simulator $(SN_TESTS_SIM) \
	    --run-dir $(SN_VFU_RUNS_DIR)

vfu-tests: vfu-tests-build vfu-tests-run

####################
#  Spatz ISA Tests #
####################

SN_SPATZ_ISA_SRCDIR   = $(SN_ROOT)/hw/spatz/sw/riscvTests/isa/rv64uv
SN_SPATZ_ISA_MACRODIR = $(SN_ROOT)/hw/spatz/sw/riscvTests/isa/macros/vector
SN_SPATZ_ISA_BUILDDIR = $(SN_ROOT)/sw/spatz-isa-tests/build

# Tests from hw/spatz/sw/riscvTests/CMakeLists.txt that work as-is with the
# SIMD (VLEN=256, single-word) constraint.  Excluded:
#   vsetvli                          ? not needed
#   vredsum/and/or/xor/min/minu/max/maxu  ? covered by schnizo-extra-tests
#   vfredmin/max/osum/usum           ? covered by schnizo-extra-tests
#   vmv / vslide1up/up/1down/down    ? covered by schnizo-extra-tests
#   vloxei / vsuxei                  ? indexed scatter/gather not implemented
SN_SPATZ_ISA_NAMES = \
  vadd vsub vrsub \
  vand vor vxor \
  vsll vsrl vsra \
  vmin vminu vmax vmaxu \
  vmul vmulh vmulhu vmulhsu \
  vdiv vdivu vrem vremu \
  vmacc vmadd vnmsac vnmsub \
  vwadd vwaddu vwsub vwsubu \
  vwmul vwmulu vwmulsu \
  vwmacc vwmaccu vwmaccsu vwmaccus \
  vfadd vfsub vfrsub vfmin vfmax \
  vfmul vfmacc vfnmacc vfmsac vfnmsac vfmadd vfnmadd vfmsub vfnmsub \
  vfwadd vfwsub vfwmul vfwmacc vfwmsac vfwnmsac \
  vfsgnj vfsgnjn vfsgnjx \
  vfcvt \
  vfmv

SN_SPATZ_ISA_SRCS  = $(addprefix $(SN_SPATZ_ISA_SRCDIR)/,$(addsuffix .c,$(SN_SPATZ_ISA_NAMES)))
SN_SPATZ_ISA_ELFS  = $(addprefix $(SN_SPATZ_ISA_BUILDDIR)/,$(addsuffix .elf,$(SN_SPATZ_ISA_NAMES)))
SN_SPATZ_ISA_DUMPS = $(SN_SPATZ_ISA_ELFS:.elf=.dump)

# sw/spatz-isa-tests/include must be first so its vector_macros.h wrapper is found
# before the upstream one in SN_SPATZ_ISA_MACRODIR.  Using a subdirectory ensures
# #include_next works for source files that live in sw/spatz-isa-tests/ itself
# (clang's #include_next is broken when the wrapper is in the same dir as the TU).
SN_SPATZ_ISA_INCDIRS  = $(SN_ROOT)/sw/spatz-isa-tests/include
SN_SPATZ_ISA_INCDIRS += $(SN_RUNTIME_INCDIRS)
SN_SPATZ_ISA_INCDIRS += $(SN_SPATZ_ISA_MACRODIR)
SN_SPATZ_ISA_INCDIRS += $(SN_ROOT)/sw/deps/riscv-tests/env

# Strip -Werror; keep everything else (runtime is C++ and requires -x c++).
SN_SPATZ_ISA_CFLAGS  = $(filter-out -Werror,$(SN_RISCV_CFLAGS))
SN_SPATZ_ISA_CFLAGS += $(addprefix -I,$(SN_SPATZ_ISA_INCDIRS))
SN_SPATZ_ISA_CFLAGS += -DELEN=64 -DVLEN=256
# vector_macros.h calls snrt_l1alloc (no underscore); schnizo runtime uses snrt_l1_alloc
SN_SPATZ_ISA_CFLAGS += -Dsnrt_l1alloc=snrt_l1_alloc
# IRQ_M_CLUSTER is defined in riscv-opcodes/encoding.h but not pulled in by the runtime
SN_SPATZ_ISA_CFLAGS += -DIRQ_M_CLUSTER=19
# VLOAD_8 passes 0xAA literals to int8_t params; suppress C++11 narrowing errors
SN_SPATZ_ISA_CFLAGS += -Wno-narrowing -Wno-c++11-narrowing
# vfclass/vfrdiv/vfsqrt use _d(x).i / _f(x).i not present in spatz float_macros.h
SN_SPATZ_ISA_CFLAGS += -include $(SN_ROOT)/sw/spatz-isa-tests/float_shim.h

SN_SPATZ_ISA_LDFLAGS = $(SN_TESTS_RISCV_LDFLAGS)

SN_SPATZ_ISA_TESTLIST = $(SN_ROOT)/test/spatz_isa_tests.yaml
SN_SPATZ_ISA_RUNS_DIR = $(SN_SIM_DIR)/runs/spatz-isa-tests

$(SN_SPATZ_ISA_BUILDDIR):
	mkdir -p $@

$(SN_SPATZ_ISA_RUNS_DIR):
	mkdir -p $@

# Per-source compilation + dump rules
define sn_spatz_isa_rule
$$(SN_SPATZ_ISA_BUILDDIR)/$$(notdir $$(basename $(1))).elf: $(1) $$(SN_RUNTIME_LD_DEPS) | $$(SN_SPATZ_ISA_BUILDDIR)
	$$(SN_RISCV_CXX) $$(SN_SPATZ_ISA_CFLAGS) $$(SN_SPATZ_ISA_LDFLAGS) -x c++ $(1) -o $$@
endef

$(SN_SPATZ_ISA_BUILDDIR)/%.dump: $(SN_SPATZ_ISA_BUILDDIR)/%.elf | $(SN_SPATZ_ISA_BUILDDIR)
	$(SN_RISCV_OBJDUMP) $(SN_RISCV_OBJDUMP_FLAGS) $< > $@

$(foreach src,$(SN_SPATZ_ISA_SRCS),$(eval $(call sn_spatz_isa_rule,$(src))))

# schnizo_extra.c ? same flags as the spatz ISA tests, separate rule
SN_SCHNIZO_EXTRA_SRC  = $(SN_ROOT)/sw/spatz-isa-tests/schnizo_extra.c
SN_SCHNIZO_EXTRA_ELF  = $(SN_SPATZ_ISA_BUILDDIR)/schnizo_extra.elf
SN_SCHNIZO_EXTRA_DUMP = $(SN_SPATZ_ISA_BUILDDIR)/schnizo_extra.dump

$(SN_SCHNIZO_EXTRA_ELF): $(SN_SCHNIZO_EXTRA_SRC) $(SN_RUNTIME_LD_DEPS) | $(SN_SPATZ_ISA_BUILDDIR)
	$(SN_RISCV_CXX) $(SN_SPATZ_ISA_CFLAGS) $(SN_SPATZ_ISA_LDFLAGS) -x c++ $< -o $@

$(SN_SCHNIZO_EXTRA_DUMP): $(SN_SCHNIZO_EXTRA_ELF) | $(SN_SPATZ_ISA_BUILDDIR)
	$(SN_RISCV_OBJDUMP) $(SN_RISCV_OBJDUMP_FLAGS) $< > $@

.PHONY: spatz-isa-tests-build spatz-isa-tests-run spatz-isa-tests

spatz-isa-tests-build: $(SN_SPATZ_ISA_ELFS) $(SN_SPATZ_ISA_DUMPS) \
                       $(SN_SCHNIZO_EXTRA_ELF) $(SN_SCHNIZO_EXTRA_DUMP)

spatz-isa-tests-run: $(SN_SPATZ_ISA_ELFS) $(SN_SCHNIZO_EXTRA_ELF) $(SN_VSIM_BINARY) | $(SN_SPATZ_ISA_RUNS_DIR)
	PATH=$(SN_BIN_DIR):$$PATH \
	python3 $(SN_TESTS_RUN_PY) $(SN_SPATZ_ISA_TESTLIST) \
	    --simulator $(SN_TESTS_SIM) \
	    --run-dir $(SN_SPATZ_ISA_RUNS_DIR)

spatz-isa-tests: spatz-isa-tests-build spatz-isa-tests-run

.PHONY: clean-schnizo-tests
clean-schnizo-tests:
	rm -rf $(SN_SPATZ_ISA_BUILDDIR) $(SN_VFU_RUNS_DIR) $(SN_SPATZ_ISA_RUNS_DIR)
