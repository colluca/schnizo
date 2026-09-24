// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "math.h"
#include "snrt.h"

static inline void gelu_fp64_tanh_naive(double *in, double *out,
                                        uint32_t size) {
    for (uint32_t i = 0; i < size; i++)
        out[i] = 0.5 * in[i] *
                 (1.0 + tanh(sqrt(2.0 / M_PI) *
                             (in[i] + 0.044715 * in[i] * in[i] * in[i])));
}

// GeLU sigmoid approximation (Hendrycks & Gimpel, arXiv:1606.08415, eq. 4):
// y = x * sigmoid(1.702 * x) = x / (1 + exp(-1.702 * x))
static inline void gelu_fp64_sigmoid_naive(double *in, double *out,
                                           uint32_t size) {
    for (uint32_t i = 0; i < size; i++)
        out[i] = in[i] / (1.0 + exp(-1.702 * in[i]));
}
