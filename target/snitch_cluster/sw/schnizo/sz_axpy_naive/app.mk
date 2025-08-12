# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

# This is a dummy target for the experiments.
# It uses the sz_axpy code but the experiment can pass a different configuration to it.

APP              := sz_axpy_naive
$(APP)_BUILD_DIR ?= $(SN_ROOT)/target/snitch_cluster/sw/schnizo/$(APP)/build
# Override the source
SRC_DIR          := $(SN_ROOT)/sw/schnizo/sz_axpy/src
SRCS             := $(SRC_DIR)/main.c

include $(SN_ROOT)/sw/apps/common.mk
include $(SN_ROOT)/target/snitch_cluster/sw/apps/common.mk

# Add this app to the list of schnizo targets
sw-schnizo: $(APP)
clean-sw-schnizo: clean-$(APP)