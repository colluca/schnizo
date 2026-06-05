// Copyright 2020 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "math.h"
#include "snrt.h"
#include "blas.h"
#include "../../misc/exp/src/vexpf.h"

/**
 * @struct softmax_layer_struct
 * @brief This structure contains all parameters necessary
 *       for computing the Softmax activation function
 * @var softmax_layer_struct::batch_size
 * Size of each input sample
 * @var softmax_layer_struct::seq_len
 * Size of each output sample
 * @var softmax_layer_struct::input_samples
 * Number of input samples
 * @var softmax_layer_struct::reduce_dim
 * Along which dimension to reduce
 * @var softmax_layer_struct::ifmap
 * Pointer to input feature map
 * @var softmax_layer_struct::ofmap
 * Pointer to output feature map
 */
typedef struct softmax_layer_struct {
    uint32_t batch_size;
    uint32_t seq_len;
    uint32_t input_samples;
    int32_t reduce_dim;
    float *ifmap;
    float *ofmap;
    precision_t dtype;
} softmax_layer_t;

static inline void softmax_fp32_naive(float *input, float *output, int32_t ldI,
                                      int32_t batch_offset, int32_t batch_size,
                                      int32_t seq_len, int32_t input_samples) {
    float max_core = 0.0;  // max value of the current core
    float sum = 0.0;       // sum of the exp values of the current core
    float inv_sum;         // inverse of the sum, used for normalization

    for (int32_t b = 0; b < batch_size; b++) {
        for (int32_t s = 0; s < seq_len; s++) {
            max_core = -INFINITY;
            sum = 0.0;

            for (int32_t i = 0; i < input_samples; i++) {
                if (input[b * batch_offset + s * ldI + i] > max_core) {
                    max_core = input[b * batch_offset + s * ldI + i];
                }
            }

            // compute the shifted value of the current row
            for (int32_t i = 0; i < input_samples; i++) {
                output[b * batch_offset + s * ldI + i] =
                    expf(input[b * batch_offset + s * ldI + i] - max_core);
                sum += output[b * batch_offset + s * ldI + i];
            }

            inv_sum = 1.0 / sum;

            // compute the softmax value of the current row
            for (int32_t i = 0; i < input_samples; i++) {
                output[b * batch_offset + s * ldI + i] *= inv_sum;
            }
        }
    }

    snrt_cluster_hw_barrier();
}

// Max (compute-bound, fmax.s): 4 accumulators, FREP for both frep.i and frep.o.
// Shift (load-use-store): frep.i → 4x unroll, frep.o → scalar.
// Sum (compute-bound): 4 accumulators, FREP for both frep.i and frep.o.
// Assumes input_samples is a multiple of 4.
static inline void softmax_fp32_schnizo(float *input, float *output,
                                        int32_t ldI, int32_t batch_offset,
                                        int32_t batch_size, int32_t seq_len,
                                        int32_t input_samples) {
    float max_core;
    float sum;

    for (int32_t b = 0; b < batch_size; b++) {
        for (int32_t s = 0; s < seq_len; s++) {
            float *row_in  = &input [b * batch_offset + s * ldI];
            float *row_out = &output[b * batch_offset + s * ldI];

            // find max (compute-bound, fmax.s: 4 accumulators for both frep.i/o)
            {
                float m0 = -INFINITY, m1 = -INFINITY;
                float m2 = -INFINITY, m3 = -INFINITY;
                float *ptr = row_in;
                int n_frep = input_samples / 4 - 1;
                asm volatile(
                    // clang-format off
                    FREP " %[n], 9, 0, 0              \n"
                    "flw    fa0,  0(%[ptr])            \n"
                    "flw    fa1,  4(%[ptr])            \n"
                    "flw    fa2,  8(%[ptr])            \n"
                    "flw    fa3, 12(%[ptr])            \n"
                    "fmax.s %[m0], %[m0], fa0          \n"
                    "fmax.s %[m1], %[m1], fa1          \n"
                    "fmax.s %[m2], %[m2], fa2          \n"
                    "fmax.s %[m3], %[m3], fa3          \n"
                    "addi   %[ptr], %[ptr], 16         \n"
                    // clang-format on
                    : [ m0 ] "+f"(m0), [ m1 ] "+f"(m1),
                      [ m2 ] "+f"(m2), [ m3 ] "+f"(m3), [ ptr ] "+r"(ptr)
                    : [ n ] "r"(n_frep)
                    : "fa0", "fa1", "fa2", "fa3", "memory"
                );
                m0 = fmaxf(m0, m1);
                m2 = fmaxf(m2, m3);
                max_core = fmaxf(m0, m2);
            }

            // shift: row_out[i] = row_in[i] - max_core  (load-use-store)
            {
                float *in_ptr = row_in, *out_ptr = row_out;
#ifdef FORCE_HW_LOOP
                int n_frep = input_samples / 4 - 1;
                asm volatile(
                    // clang-format off
                    "frep.i %[n], 14, 0, 0           \n"
                    "flw    fa0,  0(%[in])            \n"
                    "flw    fa1,  4(%[in])            \n"
                    "flw    fa2,  8(%[in])            \n"
                    "flw    fa3, 12(%[in])            \n"
                    "fsub.s fa0, fa0, %[max]          \n"
                    "fsub.s fa1, fa1, %[max]          \n"
                    "fsub.s fa2, fa2, %[max]          \n"
                    "fsub.s fa3, fa3, %[max]          \n"
                    "fsw    fa0,  0(%[out])           \n"
                    "fsw    fa1,  4(%[out])           \n"
                    "fsw    fa2,  8(%[out])           \n"
                    "fsw    fa3, 12(%[out])           \n"
                    "addi   %[in],  %[in],  16        \n"
                    "addi   %[out], %[out], 16        \n"
                    // clang-format on
                    : [ in ] "+r"(in_ptr), [ out ] "+r"(out_ptr)
                    : [ n ] "r"(n_frep), [ max ] "f"(max_core)
                    : "fa0", "fa1", "fa2", "fa3", "memory"
                );
#else
                int n_frep = input_samples - 1;
                asm volatile(
                    // clang-format off
                    "frep.o %[n], 5, 0, 0             \n"
                    "flw    fa0,  0(%[in])             \n"
                    "fsub.s fa0, fa0, %[max]           \n"
                    "fsw    fa0,  0(%[out])            \n"
                    "addi   %[in],  %[in],  4          \n"
                    "addi   %[out], %[out], 4          \n"
                    // clang-format on
                    : [ in ] "+r"(in_ptr), [ out ] "+r"(out_ptr)
                    : [ n ] "r"(n_frep), [ max ] "f"(max_core)
                    : "fa0", "memory"
                );
#endif
            }

            // in-place vectorized exp (float I/O, double-precision algorithm)
            vexpf_fp32_schnizo(row_out, row_out, input_samples);

            // sum accumulation (compute-bound: 4 accumulators for both frep.i/o)
            {
                float sum1 = 0.0f, sum2 = 0.0f, sum3 = 0.0f, sum4 = 0.0f;
                float *ptr = row_out;
                int n_frep = input_samples / 4 - 1;
                asm volatile(
                    // clang-format off
                    FREP " %[n], 9, 0, 0              \n"
                    "flw    fa0,  0(%[ptr])            \n"
                    "flw    fa1,  4(%[ptr])            \n"
                    "flw    fa2,  8(%[ptr])            \n"
                    "flw    fa3, 12(%[ptr])            \n"
                    "fadd.s %[s0], %[s0], fa0          \n"
                    "fadd.s %[s1], %[s1], fa1          \n"
                    "fadd.s %[s2], %[s2], fa2          \n"
                    "fadd.s %[s3], %[s3], fa3          \n"
                    "addi   %[ptr], %[ptr], 16         \n"
                    // clang-format on
                    : [ s0 ] "+f"(sum1), [ s1 ] "+f"(sum2),
                      [ s2 ] "+f"(sum3), [ s3 ] "+f"(sum4), [ ptr ] "+r"(ptr)
                    : [ n ] "r"(n_frep)
                    : "fa0", "fa1", "fa2", "fa3", "memory"
                );
                sum1 += sum2;
                sum3 += sum4;
                sum = sum1 + sum3;
            }

            // in-place normalization: row_out[i] *= 1/sum
            scal_fp32_schnizo(1.0f / sum, row_out, input_samples);
        }
    }

    snrt_cluster_hw_barrier();
}

/**
 * @brief  SoftMax layer
 *
 * @param l softmax_layer struct that holds addresses and parameters
 *
 */
static inline void softmax_layer(softmax_layer_t const l) {
    uint32_t cluster_num = snrt_cluster_num();
    uint32_t cluster_id = snrt_cluster_idx();
    uint32_t compute_num = snrt_cluster_compute_core_num();
    uint32_t compute_id = snrt_global_core_idx();

    uint32_t ifmap_size = l.batch_size * l.seq_len * l.input_samples;
    uint32_t ofmap_size = ifmap_size;

    float *ptr = (float *)snrt_l1_next();
    float *ifmap = ptr;
    ptr += ifmap_size;
    float *ofmap = ptr;
    ptr += ofmap_size;

    // DMA transfer the ifmap into the cluster TCDM
    if (snrt_is_dm_core()) {
        snrt_dma_txid_t txid_ifmap = snrt_dma_start_2d(
            ifmap, l.ifmap, l.batch_size * sizeof(float),
            l.batch_size * sizeof(float), l.batch_size * sizeof(float),
            l.seq_len * l.input_samples * sizeof(float));

        snrt_dma_wait_all();
    }

    snrt_cluster_hw_barrier();

    if (snrt_is_compute_core()) {
        // determine the row offset for each core
        int32_t row_offset = compute_id * l.input_samples;

        // determine the row stride of each matrix
        int32_t ldI = compute_num * l.input_samples;

        // determine the batch offset for each core
        int32_t batch_offset = l.seq_len * l.input_samples;

        snrt_mcycle();
        softmax_fp32_schnizo(&ifmap[row_offset], &ofmap[row_offset], ldI,
                             batch_offset, l.batch_size,
                             l.seq_len / compute_num, l.input_samples);
        snrt_mcycle();

    } else {
        snrt_cluster_hw_barrier();
    }

    // DMA transfer the ofmap to DRAM
    if (snrt_is_dm_core()) {
        snrt_dma_txid_t txid_ofmap = snrt_dma_start_2d(
            l.ofmap, ofmap, l.batch_size * sizeof(float),
            l.batch_size * sizeof(float), l.batch_size * sizeof(float),
            l.seq_len * l.input_samples * sizeof(float));

        snrt_dma_wait_all();
    }

    snrt_global_barrier();
}
