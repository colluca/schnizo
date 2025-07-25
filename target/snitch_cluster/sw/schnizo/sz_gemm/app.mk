# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

APP              := sz_gemm
$(APP)_BUILD_DIR ?= $(SN_ROOT)/target/snitch_cluster/sw/schnizo/$(APP)/build
SRC_DIR          := $(SN_ROOT)/sw/schnizo/$(APP)/src
SRCS             := $(SRC_DIR)/main.c

include $(SN_ROOT)/sw/apps/common.mk
include $(SN_ROOT)/target/snitch_cluster/sw/apps/common.mk

# Add this app to the list of schnizo targets
sw-schnizo: $(APP)
clean-sw-schnizo: clean-$(APP)
