// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "math.h"
#include "snrt.h"

#include "../../eltwise/src/eltwise.h"
#include "../../misc/exp/src/vexpf_schnizo_fp32.h"

// GeLU sigmoid approximation (Hendrycks & Gimpel, arXiv:1606.08415, eq. 4):
// y = x * sigmoid(1.702 * x) = x / (1 + exp(-1.702 * x))
static inline void gelu_fp32_sigmoid_naive(float *in, float *out,
                                           uint32_t size) {
    for (uint32_t i = 0; i < size; i++)
        out[i] = in[i] / (1.0f + expf(-1.702f * in[i]));
}

// Optimized GeLU sigmoid approx using vectorized exp and eltwise kernels.
// Requires size % 4 == 0 and size >= 8.
static inline void gelu_fp32_sigmoid_schnizo(float *in, float *out,
                                             uint32_t size) {
    // Step 1: out[i] = -1.702f * in[i]
    {
        float *src = in, *dst = out;
        float scale = -1.702f;
#ifdef FORCE_HW_LOOP
        int n_frep = size / 4 - 1;
        asm volatile(
            // clang-format off
            "frep.i %[n], 14, 0, 0             \n"
            "flw    fa0,  0(%[src])            \n"
            "flw    fa1,  4(%[src])            \n"
            "flw    fa2,  8(%[src])            \n"
            "flw    fa3, 12(%[src])            \n"
            "fmul.s fa0, fa0, %[scale]         \n"
            "fmul.s fa1, fa1, %[scale]         \n"
            "fmul.s fa2, fa2, %[scale]         \n"
            "fmul.s fa3, fa3, %[scale]         \n"
            "fsw    fa0,  0(%[dst])            \n"
            "fsw    fa1,  4(%[dst])            \n"
            "fsw    fa2,  8(%[dst])            \n"
            "fsw    fa3, 12(%[dst])            \n"
            "addi   %[src], %[src], 16         \n"
            "addi   %[dst], %[dst], 16         \n"
            // clang-format on
            : [ src ] "+r"(src), [ dst ] "+r"(dst)
            : [ n ] "r"(n_frep), [ scale ] "f"(scale)
            : "fa0", "fa1", "fa2", "fa3", "memory");
#else
        int n_frep = size - 1;
        asm volatile(
            // clang-format off
            "frep.o %[n], 5, 0, 0              \n"
            "flw    fa0,  0(%[src])            \n"
            "fmul.s fa0, fa0, %[scale]         \n"
            "fsw    fa0,  0(%[dst])            \n"
            "addi   %[src], %[src], 4          \n"
            "addi   %[dst], %[dst], 4          \n"
            // clang-format on
            : [ src ] "+r"(src), [ dst ] "+r"(dst)
            : [ n ] "r"(n_frep), [ scale ] "f"(scale)
            : "fa0", "memory");
#endif
    }

    // Step 2: out[i] = exp(-1.702 * in[i])
    vexpf_fp32_schnizo(out, out, size);

    // Step 3: out[i] = 1.0f + out[i]  (in-place: two pointers avoids WAR hazard)
    {
        float *src = out, *dst = out;
        float one = 1.0f;
#ifdef FORCE_HW_LOOP
        int n_frep = size / 4 - 1;
        asm volatile(
            // clang-format off
            "frep.i %[n], 14, 0, 0             \n"
            "flw    fa0,  0(%[src])            \n"
            "flw    fa1,  4(%[src])            \n"
            "flw    fa2,  8(%[src])            \n"
            "flw    fa3, 12(%[src])            \n"
            "fadd.s fa0, fa0, %[one]           \n"
            "fadd.s fa1, fa1, %[one]           \n"
            "fadd.s fa2, fa2, %[one]           \n"
            "fadd.s fa3, fa3, %[one]           \n"
            "fsw    fa0,  0(%[dst])            \n"
            "fsw    fa1,  4(%[dst])            \n"
            "fsw    fa2,  8(%[dst])            \n"
            "fsw    fa3, 12(%[dst])            \n"
            "addi   %[src], %[src], 16         \n"
            "addi   %[dst], %[dst], 16         \n"
            // clang-format on
            : [ src ] "+r"(src), [ dst ] "+r"(dst)
            : [ n ] "r"(n_frep), [ one ] "f"(one)
            : "fa0", "fa1", "fa2", "fa3", "memory");
#else
        int n_frep = size - 1;
        asm volatile(
            // clang-format off
            "frep.o %[n], 5, 0, 0              \n"
            "flw    fa0,  0(%[src])            \n"
            "fadd.s fa0, fa0, %[one]           \n"
            "fsw    fa0,  0(%[dst])            \n"
            "addi   %[src], %[src], 4          \n"
            "addi   %[dst], %[dst], 4          \n"
            // clang-format on
            : [ src ] "+r"(src), [ dst ] "+r"(dst)
            : [ n ] "r"(n_frep), [ one ] "f"(one)
            : "fa0", "memory");
#endif
    }

    // Step 4: out[i] = in[i] / out[i] = x / (1 + exp(-1.702*x)) = x * sigmoid(1.702*x)
    eltwise_fp32_schnizo(in, out, out, size, ELTWISE_DIV);
}
