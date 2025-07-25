# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

###############
# Directories #
###############

SZ_TESTS_SRCDIR   = $(ROOT)/sw/schnizo/tests
SZ_TESTS_BUILDDIR = $(ROOT)/target/snitch_cluster/sw/schnizo/tests/build

###################
# Build variables #
###################

SZ_TESTS_RISCV_CFLAGS += $(RISCV_CFLAGS)
SZ_TESTS_RISCV_CFLAGS += $(addprefix -I,$(SNRT_INCDIRS))
SZ_TESTS_RISCV_CFLAGS += $(addprefix -I,$(SZRT_INCDIRS))

SZ_BASE_LD    = $(SNRT_DIR)/base.ld
SZ_MEMORY_LD ?= $(ROOT)/target/snitch_cluster/sw/runtime/memory.ld

SZ_TESTS_RISCV_LDFLAGS += $(RISCV_LDFLAGS)
SZ_TESTS_RISCV_LDFLAGS += -L$(dir $(SZ_MEMORY_LD))
SZ_TESTS_RISCV_LDFLAGS += -T$(SZ_BASE_LD)
SZ_TESTS_RISCV_LDFLAGS += -L$(SNRT_BUILDDIR)
SZ_TESTS_RISCV_LDFLAGS += -lsnRuntime

LD_DEPS = $(SZ_MEMORY_LD) $(SZ_BASE_LD) $(SNRT_LIB)

###########
# Outputs #
###########

TEST_NAMES   = $(basename $(notdir $(wildcard $(SZ_TESTS_SRCDIR)/*.c)))
TEST_ELFS    = $(abspath $(addprefix $(SZ_TESTS_BUILDDIR)/,$(addsuffix .elf,$(TEST_NAMES))))
TEST_DEPS    = $(abspath $(addprefix $(SZ_TESTS_BUILDDIR)/,$(addsuffix .d,$(TEST_NAMES))))
TEST_DUMPS   = $(abspath $(addprefix $(SZ_TESTS_BUILDDIR)/,$(addsuffix .dump,$(TEST_NAMES))))
TEST_OUTPUTS = $(TEST_ELFS)

ifeq ($(DEBUG),ON)
TEST_OUTPUTS += $(TEST_DUMPS)
endif

#########
# Rules #
#########

.PHONY: schnizo-tests clean-schnizo-tests

sw: schnizo-tests
clean-sw: clean-schnizo-tests

schnizo-tests: $(TEST_OUTPUTS)

clean-schnizo-tests:
	rm -rf $(SZ_TESTS_BUILDDIR)

$(SZ_TESTS_BUILDDIR):
	mkdir -p $@

$(SZ_TESTS_BUILDDIR)/%.d: $(SZ_TESTS_SRCDIR)/%.c | $(SZ_TESTS_BUILDDIR)
	$(RISCV_CC) $(SZ_TESTS_RISCV_CFLAGS) -MM -MT '$(SZ_TESTS_BUILDDIR)/$*.elf' $< > $@

$(SZ_TESTS_BUILDDIR)/%.elf: $(SZ_TESTS_SRCDIR)/%.c $(LD_DEPS) $(SZ_TESTS_BUILDDIR)/%.d | $(SZ_TESTS_BUILDDIR)
	$(RISCV_CC) $(SZ_TESTS_RISCV_CFLAGS) $(SZ_TESTS_RISCV_LDFLAGS) $(SZ_TESTS_SRCDIR)/$*.c -o $@

$(SZ_TESTS_BUILDDIR)/%.dump: $(SZ_TESTS_BUILDDIR)/%.elf | $(SZ_TESTS_BUILDDIR)
	$(RISCV_OBJDUMP) $(RISCV_OBJDUMP_FLAGS) $< > $@

$(TEST_DEPS): | $(SNRT_HAL_HDRS)

ifneq ($(filter-out clean%,$(MAKECMDGOALS)),)
-include $(TEST_DEPS)
endif
