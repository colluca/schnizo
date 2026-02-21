// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once
#include <stdint.h>

typedef void (*dot_fp_t)(uint32_t n, double *x, double *y, double *output);

typedef struct {
    dot_fp_t funcptr;
} dot_args_t;
