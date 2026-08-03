// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Author: Viviane Potocnik <vivianep@iis.ee.ethz.ch>

#define UNROLL_FACTOR 4

/**
 * Single-cluster implementation of a layernorm tile (data assumed in TCDM)
 */
template <typename T>
static inline void layernorm_naive(T *input, T *output, int32_t batch_size,
                                   int32_t seq_len, int32_t embeddings,
                                   int32_t eps) {
    if (snrt_is_compute_core()) {
        // Get parameters for every core's tile
        // cores access rows in interleaved fashion
        // offset: offset between data accessed by every core (for
        //         corresponding iterations)
        // stride: offset between data accessed by the same core in
        //         consecutive iterations
        // tile_seq_len: fraction of the sequence assigned to each core
        uint32_t offset = snrt_cluster_core_idx() * embeddings;
        uint32_t stride = snrt_cluster_compute_core_num() * embeddings;
        uint32_t tile_seq_len = seq_len / snrt_cluster_compute_core_num();
        T *core_itile = input + offset;
        T *core_otile = output + offset;

        // get derived layernorm quantities
        uint32_t batch_offset = seq_len * embeddings;

        // compute the mean and variance along the last dimension
        float mean = 0.0;  // max value of the current core
        float var = 0.0;   // sum of the exp values of the current core
        for (int32_t b = 0; b < batch_size; b++) {
            for (int32_t s = 0; s < tile_seq_len; s++) {
                mean = 0.0;
                var = 0.0;

                for (int32_t i = 0; i < embeddings; i++) {
                    mean += core_itile[b * batch_offset + s * stride + i];
                }
                mean /= embeddings;

                for (int32_t i = 0; i < embeddings; i++) {
                    var +=
                        (core_itile[b * batch_offset + s * stride + i] - mean) *
                        (core_itile[b * batch_offset + s * stride + i] - mean);
                }
                var /= embeddings;
                var = sqrtf(var + eps);

                // compute the shifted value of the current row
                for (int32_t i = 0; i < embeddings; i++) {
                    core_otile[b * batch_offset + s * stride + i] =
                        (core_itile[b * batch_offset + s * stride + i] - mean) /
                        var;
                }
            }
        }

        snrt_fpu_fence();
    }
}

static inline void layernorm_fp32_opt(float *input, float *output,
                                      uint32_t batch_size, uint32_t seq_len,
                                      const uint32_t embeddings, int32_t eps) {
#ifdef SNRT_SUPPORTS_FREP
    if (snrt_is_compute_core()) {
        uint32_t offset = snrt_cluster_core_idx() * embeddings;
        uint32_t stride = snrt_cluster_compute_core_num() * embeddings;
        uint32_t tile_seq_len = seq_len / snrt_cluster_compute_core_num();
        float *core_itile = input + offset;
        float *core_otile = output + offset;

        uint32_t batch_offset = seq_len * embeddings;

        // compute the mean and variance along the last dimension
        float mean_tot = 0.0;  // max value of the current core
        float var_tot = 0.0;   // sum of the exp values of the current core
        v2f32 mean_reg = {0.0, 0.0};
        const int num_elems_per_vector = sizeof(double) / sizeof(float);
        for (int32_t b = 0; b < batch_size; b++) {
            const uint32_t ssr0_b[4] = {
                UNROLL_FACTOR,
                embeddings / (UNROLL_FACTOR * num_elems_per_vector), 2,
                tile_seq_len};
            const uint32_t ssr0_i[4] = {sizeof(double),
                                        UNROLL_FACTOR * sizeof(double), 0,
                                        stride * sizeof(float)};

            const uint32_t ssr1_b[2] = {
                UNROLL_FACTOR,
                embeddings / (UNROLL_FACTOR * num_elems_per_vector)};
            const uint32_t ssr1_i[2] = {sizeof(double),
                                        UNROLL_FACTOR * sizeof(double)};

            snrt_ssr_loop_4d(SNRT_SSR_DM0, ssr0_b[0], ssr0_b[1], ssr0_b[2],
                             ssr0_b[3], ssr0_i[0], ssr0_i[1], ssr0_i[2],
                             ssr0_i[3]);

            snrt_ssr_loop_4d(SNRT_SSR_DM1, ssr0_b[0], ssr0_b[1], ssr0_b[2],
                             ssr0_b[3], ssr0_i[0], ssr0_i[1], ssr0_i[2],
                             ssr0_i[3]);

            snrt_ssr_loop_2d(SNRT_SSR_DM2, ssr1_b[0], ssr1_b[1], ssr1_i[0],
                             ssr1_i[1]);

            snrt_ssr_read(SNRT_SSR_DM0, SNRT_SSR_4D,
                          &core_itile[b * batch_offset]);
            snrt_ssr_write(SNRT_SSR_DM1, SNRT_SSR_4D,
                           &core_otile[b * batch_offset]);

            // kernel progresses two values in each iteration
            const uint32_t n_frep =
                embeddings / (UNROLL_FACTOR * num_elems_per_vector);

            for (int32_t s = 0; s < tile_seq_len; s++) {
                float mean[UNROLL_FACTOR] = {0.0, 0.0};
                float var[UNROLL_FACTOR] = {0.0, 0.0};
                mean_tot = 0.0;
                var_tot = 0.0;
                v2f32 var_reg[UNROLL_FACTOR];
                v2f32 pow[UNROLL_FACTOR];
                v2f32 one_reg = {1.0f, 1.0f};

                var_tot = 0.0;
                snrt_ssr_enable();

                // Computation of the row mean
                asm volatile(
                    "vfcpka.s.s %[mean0], %[zero], %[zero] \n"
                    "vfcpka.s.s %[mean1], %[zero], %[zero] \n"
                    "vfcpka.s.s %[mean2], %[zero], %[zero] \n"
                    "vfcpka.s.s %[mean3], %[zero], %[zero] \n"
                    "frep.o  %[n_frep], 4, 0, 0 \n"
                    "vfsum.s %[mean0], ft0 \n"
                    "vfsum.s %[mean1], ft0 \n"
                    "vfsum.s %[mean2], ft0 \n"
                    "vfsum.s %[mean3], ft0 \n"
                    "fadd.s %[mean0], %[mean0], %[mean1] \n"
                    "fadd.s %[mean2], %[mean2], %[mean3] \n"
                    "fadd.s %[mean_tot], %[mean0], %[mean2] \n"
                    "fdiv.s %[mean_tot], %[mean_tot], %[embeddings] \n"
                    : [ mean0 ] "+f"(mean[0]), [ mean1 ] "+f"(mean[1]),
                      [ mean2 ] "+f"(mean[2]), [ mean3 ] "+f"(mean[3]),
                      [ mean_tot ] "+f"(mean_tot)
                    : [ n_frep ] "r"(n_frep - 1), [ zero ] "f"(0.0),
                      [ embeddings ] "f"((float)embeddings)
                    : "ft0", "ft1", "ft2");

                snrt_fpu_fence();

                // Computation of the row variance
                asm volatile(
                    "vfcpka.s.s %[mean_reg], %[mean_tot], %[mean_tot] \n"
                    "frep.o  %[n_frep], 16, 0, 0 \n"
                    "vfsub.s %[var_reg0], ft0, %[mean_reg] \n"
                    "vfsub.s %[var_reg1], ft0, %[mean_reg] \n"
                    "vfsub.s %[var_reg2], ft0, %[mean_reg] \n"
                    "vfsub.s %[var_reg3], ft0, %[mean_reg] \n"
                    "vfadd.s ft1, %[var_reg0], %[zero] \n"
                    "vfadd.s ft1, %[var_reg1], %[zero] \n"
                    "vfadd.s ft1, %[var_reg2], %[zero] \n"
                    "vfadd.s ft1, %[var_reg3], %[zero] \n"
                    "vfmul.s %[pow0], %[var_reg0], %[var_reg0] \n"
                    "vfmul.s %[pow1], %[var_reg1], %[var_reg1] \n"
                    "vfmul.s %[pow2], %[var_reg2], %[var_reg2] \n"
                    "vfmul.s %[pow3], %[var_reg3], %[var_reg3] \n"
                    "vfsum.s %[var0], %[pow0] \n"
                    "vfsum.s %[var1], %[pow1] \n"
                    "vfsum.s %[var2], %[pow2] \n"
                    "vfsum.s %[var3], %[pow3] \n"
                    "fadd.s %[var0], %[var0], %[var1] \n"
                    "fadd.s %[var2], %[var2], %[var3] \n"
                    "fadd.s %[var_tot], %[var0], %[var2] \n"
                    "fdiv.s %[var_tot], %[var_tot], %[embeddings] \n"
                    "fadd.s %[var_tot], %[var_tot], %[eps] \n"
                    "fsqrt.s %[var_tot], %[var_tot] \n"
                    "fdiv.s %[var_tot], %[one_reg], %[var_tot] \n"
                    "vfcpka.s.s %[mean_reg], %[var_tot], %[var_tot] \n"

                    : [ var_reg0 ] "+f"(var_reg[0]), [ var_reg1 ] "+f"(var_reg[1]),
                      [ var_reg2 ] "+f"(var_reg[2]), [ var_reg3 ] "+f"(var_reg[3]),
                      [ pow0 ] "+f"(pow[0]), [ pow1 ] "+f"(pow[1]),
                      [ pow2 ] "+f"(pow[2]), [ pow3 ] "+f"(pow[3]),
                      [ var0 ] "+f"(var[0]), [ var1 ] "+f"(var[1]),
                      [ var2 ] "+f"(var[2]), [ var3 ] "+f"(var[3]),
                      [ var_tot ] "+f"(var_tot), [ mean_reg ] "+f"(mean_reg)
                    : [ n_frep ] "r"(n_frep - 1), [ mean_tot ] "f"(mean_tot),
                      [ embeddings ] "f"((float)embeddings),
                      [ eps ] "f"((float)eps), [ zero ] "f"(0.0),
                      [ one_reg ] "f"(one_reg)
                    : "ft0", "ft1", "ft2"

                );

                snrt_fpu_fence();

                snrt_ssr_read(SNRT_SSR_DM2, SNRT_SSR_2D,
                              &core_otile[b * batch_offset + s * stride]);
                // Normalization of the row
                asm volatile(
                    "frep.o  %[n_frep], 4, 0, 0 \n"
                    "vfmul.s ft1, ft2, %[mean_reg] \n"
                    "vfmul.s ft1, ft2, %[mean_reg] \n"
                    "vfmul.s ft1, ft2, %[mean_reg] \n"
                    "vfmul.s ft1, ft2, %[mean_reg] \n"
                    : [ mean_reg ] "+f"(mean_reg)
                    : [ n_frep ] "r"(n_frep - 1)
                    : "ft0", "ft1", "ft2"

                );
                snrt_ssr_disable();
            }
        }

        snrt_fpu_fence();
    }
#endif
}

#ifdef FORCE_HW_LOOP
#define FREP "frep.i"
#else
#define FREP "frep.o"
#endif

// Plain C naive variant. Multi-core distribution: cores take interleaved rows.
static inline void layernorm_fp32_naive(void *ifmap_, void *ofmap_,
                                        uint32_t batch_size, uint32_t seq_len,
                                        uint32_t embeddings, float eps) {
    float *ifmap = (float *)ifmap_;
    float *ofmap = (float *)ofmap_;
    uint32_t num_cores = snrt_cluster_compute_core_num();
    uint32_t core_idx = snrt_cluster_core_idx();
    uint32_t stride = num_cores * embeddings;

    for (uint32_t b = 0; b < batch_size; b++) {
        for (uint32_t s = core_idx; s < seq_len; s += num_cores) {
            float *x = ifmap + (b * seq_len + s) * embeddings;
            float *y = ofmap + (b * seq_len + s) * embeddings;
            float mean = 0.0f, var = 0.0f;
            for (uint32_t i = 0; i < embeddings; i++) mean += x[i];
            mean /= embeddings;
            for (uint32_t i = 0; i < embeddings; i++) {
                float d = x[i] - mean;
                var += d * d;
            }
            var /= embeddings;
            float inv_std = 1.0f / sqrtf(var + eps);
            for (uint32_t i = 0; i < embeddings; i++)
                y[i] = (x[i] - mean) * inv_std;
        }
    }
    (void)stride;
}

// Baseline: same as naive with unrolled innermost loops.
static inline void layernorm_fp32_baseline(void *ifmap_, void *ofmap_,
                                           uint32_t batch_size,
                                           uint32_t seq_len,
                                           uint32_t embeddings, float eps) {
    float *ifmap = (float *)ifmap_;
    float *ofmap = (float *)ofmap_;
    uint32_t num_cores = snrt_cluster_compute_core_num();
    uint32_t core_idx = snrt_cluster_core_idx();

    for (uint32_t b = 0; b < batch_size; b++) {
        for (uint32_t s = core_idx; s < seq_len; s += num_cores) {
            float *x = ifmap + (b * seq_len + s) * embeddings;
            float *y = ofmap + (b * seq_len + s) * embeddings;
            float mean = 0.0f, var = 0.0f;
#pragma clang loop unroll_count(4)
            for (uint32_t i = 0; i < embeddings; i++) mean += x[i];
            mean /= embeddings;
#pragma clang loop unroll_count(4)
            for (uint32_t i = 0; i < embeddings; i++) {
                float d = x[i] - mean;
                var += d * d;
            }
            var /= embeddings;
            float inv_std = 1.0f / sqrtf(var + eps);
#pragma clang loop unroll_count(4)
            for (uint32_t i = 0; i < embeddings; i++)
                y[i] = (x[i] - mean) * inv_std;
        }
    }
}

// Schnizo: three FREP passes. Assumes embeddings % 8 == 0, embeddings >= 16.
//
// Pass 1 (sum for mean):   4 accumulators, 9 insns.
// Pass 2 (sum sq. dev.):   4 accumulators, 13 insns.
// Pass 3 (normalize):      8-wide software-pipelined fsub+fmul, 34-insn body.
static inline void layernorm_fp32_schnizo(void *ifmap_, void *ofmap_,
                                          uint32_t batch_size, uint32_t seq_len,
                                          uint32_t embeddings, float eps) {
    float *ifmap = (float *)ifmap_;
    float *ofmap = (float *)ofmap_;
    uint32_t num_cores = snrt_cluster_compute_core_num();
    uint32_t core_idx = snrt_cluster_core_idx();
    int n_frep = (int)(embeddings / 4) - 1;
    int n_frep_pass3 = (int)(embeddings / 8) - 1;

    for (uint32_t b = 0; b < batch_size; b++) {
        for (uint32_t s = core_idx; s < seq_len; s += num_cores) {
            float *x = ifmap + (b * seq_len + s) * embeddings;
            float *y = ofmap + (b * seq_len + s) * embeddings;

            // Pass 1: sum for mean (4 accumulators)
            float s0 = 0.0f, s1 = 0.0f, s2 = 0.0f, s3 = 0.0f;
            float *xp = x;
            asm volatile(FREP
                         " %[n], 9, 0, 0               \n"
                         "flw    fa0,  0(%[xp])               \n"
                         "flw    fa1,  4(%[xp])               \n"
                         "flw    fa2,  8(%[xp])               \n"
                         "flw    fa3, 12(%[xp])               \n"
                         "fadd.s %[s0], %[s0], fa0            \n"
                         "fadd.s %[s1], %[s1], fa1            \n"
                         "fadd.s %[s2], %[s2], fa2            \n"
                         "fadd.s %[s3], %[s3], fa3            \n"
                         "addi   %[xp], %[xp], 16            \n"
                         : [ s0 ] "+f"(s0), [ s1 ] "+f"(s1), [s2] "+f"(s2),
                           [ s3 ] "+f"(s3), [ xp ] "+r"(xp)
                         : [ n ] "r"(n_frep)
                         : "fa0", "fa1", "fa2", "fa3");
            float mean = (s0 + s1 + s2 + s3) / (float)embeddings;

            // Pass 2: sum of squared deviations (4 accumulators, uses fmadd)
            float v0 = 0.0f, v1 = 0.0f, v2 = 0.0f, v3 = 0.0f;
            xp = x;
            asm volatile(FREP
                         " %[n], 13, 0, 0               \n"
                         "flw    fa0,  0(%[xp])               \n"
                         "flw    fa1,  4(%[xp])               \n"
                         "flw    fa2,  8(%[xp])               \n"
                         "flw    fa3, 12(%[xp])               \n"
                         "fsub.s fa0, fa0, %[mean]            \n"
                         "fsub.s fa1, fa1, %[mean]            \n"
                         "fsub.s fa2, fa2, %[mean]            \n"
                         "fsub.s fa3, fa3, %[mean]            \n"
                         "fmadd.s %[v0], fa0, fa0, %[v0]      \n"
                         "fmadd.s %[v1], fa1, fa1, %[v1]      \n"
                         "fmadd.s %[v2], fa2, fa2, %[v2]      \n"
                         "fmadd.s %[v3], fa3, fa3, %[v3]      \n"
                         "addi   %[xp], %[xp], 16            \n"
                         : [ v0 ] "+f"(v0), [ v1 ] "+f"(v1), [ v2 ] "+f"(v2),
                           [ v3 ] "+f"(v3), [ xp ] "+r"(xp)
                         : [ n ] "r"(n_frep), [ mean ] "f"(mean)
                         : "fa0", "fa1", "fa2", "fa3");
            float inv_std =
                1.0f / sqrtf((v0 + v1 + v2 + v3) / (float)embeddings + eps);

            // Pass 3: normalize — 8-wide software-pipelined (peel + FREP + epilogue)
            // frep.o needs >= 4 iterations; fall back to frep.i for small embeddings.
#define _P3_PEEL                             \
    "flw    fa0,  0(%[xp])               \n" \
    "flw    fa1,  4(%[xp])               \n" \
    "flw    fa2,  8(%[xp])               \n" \
    "flw    fa3, 12(%[xp])               \n" \
    "flw    fa4, 16(%[xp])               \n" \
    "flw    fa5, 20(%[xp])               \n" \
    "flw    fa6, 24(%[xp])               \n" \
    "flw    fa7, 28(%[xp])               \n" \
    "fsub.s fa0, fa0, %[mean]            \n" \
    "fsub.s fa1, fa1, %[mean]            \n" \
    "fsub.s fa2, fa2, %[mean]            \n" \
    "fsub.s fa3, fa3, %[mean]            \n" \
    "fsub.s fa4, fa4, %[mean]            \n" \
    "fsub.s fa5, fa5, %[mean]            \n" \
    "fsub.s fa6, fa6, %[mean]            \n" \
    "fsub.s fa7, fa7, %[mean]            \n" \
    "fmul.s fa0, fa0, %[inv_std]         \n" \
    "fmul.s fa1, fa1, %[inv_std]         \n" \
    "fmul.s fa2, fa2, %[inv_std]         \n" \
    "fmul.s fa3, fa3, %[inv_std]         \n" \
    "fmul.s fa4, fa4, %[inv_std]         \n" \
    "fmul.s fa5, fa5, %[inv_std]         \n" \
    "fmul.s fa6, fa6, %[inv_std]         \n" \
    "fmul.s fa7, fa7, %[inv_std]         \n"
#define _P3_BODY_EPILOGUE                    \
    "addi   %[xp], %[xp], 32             \n" \
    "fsw    fa0,  0(%[yp])               \n" \
    "fsw    fa1,  4(%[yp])               \n" \
    "fsw    fa2,  8(%[yp])               \n" \
    "fsw    fa3, 12(%[yp])               \n" \
    "flw    fa0,  0(%[xp])               \n" \
    "flw    fa1,  4(%[xp])               \n" \
    "flw    fa2,  8(%[xp])               \n" \
    "flw    fa3, 12(%[xp])               \n" \
    "fsub.s fa0, fa0, %[mean]            \n" \
    "fsub.s fa1, fa1, %[mean]            \n" \
    "fsub.s fa2, fa2, %[mean]            \n" \
    "fsub.s fa3, fa3, %[mean]            \n" \
    "fmul.s fa0, fa0, %[inv_std]         \n" \
    "fmul.s fa1, fa1, %[inv_std]         \n" \
    "fmul.s fa2, fa2, %[inv_std]         \n" \
    "fmul.s fa3, fa3, %[inv_std]         \n" \
    "fsw    fa4, 16(%[yp])               \n" \
    "fsw    fa5, 20(%[yp])               \n" \
    "fsw    fa6, 24(%[yp])               \n" \
    "fsw    fa7, 28(%[yp])               \n" \
    "addi   %[yp], %[yp], 32             \n" \
    "flw    fa4, 16(%[xp])               \n" \
    "flw    fa5, 20(%[xp])               \n" \
    "flw    fa6, 24(%[xp])               \n" \
    "flw    fa7, 28(%[xp])               \n" \
    "fsub.s fa4, fa4, %[mean]            \n" \
    "fsub.s fa5, fa5, %[mean]            \n" \
    "fsub.s fa6, fa6, %[mean]            \n" \
    "fsub.s fa7, fa7, %[mean]            \n" \
    "fmul.s fa4, fa4, %[inv_std]         \n" \
    "fmul.s fa5, fa5, %[inv_std]         \n" \
    "fmul.s fa6, fa6, %[inv_std]         \n" \
    "fmul.s fa7, fa7, %[inv_std]         \n" \
    "fsw    fa0,  0(%[yp])               \n" \
    "fsw    fa1,  4(%[yp])               \n" \
    "fsw    fa2,  8(%[yp])               \n" \
    "fsw    fa3, 12(%[yp])               \n" \
    "fsw    fa4, 16(%[yp])               \n" \
    "fsw    fa5, 20(%[yp])               \n" \
    "fsw    fa6, 24(%[yp])               \n" \
    "fsw    fa7, 28(%[yp])               \n"
#define _P3_OPERANDS                                                                   \
                : [ xp ] "+r"(xp), [ yp ] "+r"(yp) \
                : [ n ]  "r"(n_frep_pass3 - 1), [ mean ] "f"(mean), [ inv_std ] "f"(inv_std) \
                : "fa0","fa1","fa2","fa3","fa4","fa5","fa6","fa7","memory"
            xp = x;
            float *yp = y;
            if (n_frep_pass3 < 4) {
                asm volatile(
                    _P3_PEEL
                    "frep.i %[n], 34, 0, 0 \n" _P3_BODY_EPILOGUE _P3_OPERANDS);
            } else {
                asm volatile(
                    _P3_PEEL FREP
                    " %[n], 34, 0, 0 \n" _P3_BODY_EPILOGUE _P3_OPERANDS);
            }
#undef _P3_PEEL
#undef _P3_BODY_EPILOGUE
#undef _P3_OPERANDS
        }
    }
}

// Schnizo: three FREP passes. Assumes embeddings % 8 == 0, embeddings >= 16.
//
// Pass 1 (sum for mean):   4 accumulators, 9 insns.
// Pass 2 (sum sq. dev.):   4 accumulators, 13 insns.
// Pass 3 (normalize):      8-wide software-pipelined fsub+fmul, 34-insn body.
static inline void layernorm_fp32_schnova(void *ifmap_, void *ofmap_,
                                          uint32_t batch_size, uint32_t seq_len,
                                          uint32_t embeddings, float eps) {
    float *ifmap = (float *)ifmap_;
    float *ofmap = (float *)ofmap_;
    uint32_t num_cores = snrt_cluster_compute_core_num();
    uint32_t core_idx = snrt_cluster_core_idx();
    int n_frep = (int)(embeddings / 4) - 1;
    int n_frep_pass3 = (int)(embeddings / 8) - 1;

    for (uint32_t b = 0; b < batch_size; b++) {
        for (uint32_t s = core_idx; s < seq_len; s += num_cores) {
            float *x = ifmap + (b * seq_len + s) * embeddings;
            float *y = ofmap + (b * seq_len + s) * embeddings;

            // Pass 1: sum for mean (4 accumulators)
            float s0 = 0.0f, s1 = 0.0f, s2 = 0.0f, s3 = 0.0f;
            float *xp = x;
            asm volatile(FREP
                         " %[n], 9, 0, 0               \n"
#ifdef BALANCE_INSTRUCTION_MIX
                         "flw    fa0,  0(%[xp])               \n"
                         "fadd.s %[s0], %[s0], fa0            \n"
                         "flw    fa1,  4(%[xp])               \n"
                         "fadd.s %[s1], %[s1], fa1            \n"
                         "flw    fa2,  8(%[xp])               \n"
                         "fadd.s %[s2], %[s2], fa2            \n"
                         "flw    fa3, 12(%[xp])               \n"
                         "fadd.s %[s3], %[s3], fa3            \n"
                         "addi   %[xp], %[xp], 16             \n"
#else
                          "flw    fa0,  0(%[xp])               \n"
                          "flw    fa1,  4(%[xp])               \n"
                          "flw    fa2,  8(%[xp])               \n"
                          "flw    fa3, 12(%[xp])               \n"
                          "fadd.s %[s0], %[s0], fa0            \n"
                          "fadd.s %[s1], %[s1], fa1            \n"
                          "fadd.s %[s2], %[s2], fa2            \n"
                          "fadd.s %[s3], %[s3], fa3            \n"
                          "addi   %[xp], %[xp], 16             \n"
#endif
                         : [ s0 ] "+f"(s0), [ s1 ] "+f"(s1), [ s2 ] "+f"(s2),
                           [ s3 ] "+f"(s3), [ xp ] "+r"(xp)
                         : [ n ] "r"(n_frep)
                         : "fa0", "fa1", "fa2", "fa3");
            float mean = (s0 + s1 + s2 + s3) / (float)embeddings;

            // Pass 2: sum of squared deviations (4 accumulators, uses fmadd)
            float v0 = 0.0f, v1 = 0.0f, v2 = 0.0f, v3 = 0.0f;
            xp = x;
            asm volatile(FREP
                         " %[n], 13, 0, 0               \n"
#ifdef BALANCE_INSTRUCTION_MIX
                         "flw    fa0,  0(%[xp])               \n"
                         "flw    fa1,  4(%[xp])               \n"
                         "flw    fa2,  8(%[xp])               \n"
                         "flw    fa3, 12(%[xp])               \n"
                         "fsub.s fa0, fa0, %[mean]            \n"
                         "fsub.s fa1, fa1, %[mean]            \n"
                         "fsub.s fa2, fa2, %[mean]            \n"
                         "fsub.s fa3, fa3, %[mean]            \n"
                         "fmadd.s %[v0], fa0, fa0, %[v0]      \n"
                         "fmadd.s %[v1], fa1, fa1, %[v1]      \n"
                         "fmadd.s %[v2], fa2, fa2, %[v2]      \n"
                         "fmadd.s %[v3], fa3, fa3, %[v3]      \n"
                         "addi   %[xp], %[xp], 16             \n"
#else
                          "flw    fa0,  0(%[xp])               \n"
                          "fsub.s fa0, fa0, %[mean]            \n"
                          "flw    fa1,  4(%[xp])               \n"
                          "fsub.s fa1, fa1, %[mean]            \n"
                          "flw    fa2,  8(%[xp])               \n"
                          "fsub.s fa2, fa2, %[mean]            \n"
                          "flw    fa3, 12(%[xp])               \n"
                          "fsub.s fa3, fa3, %[mean]            \n"
                          "fmadd.s %[v0], fa0, fa0, %[v0]      \n"
                          "fmadd.s %[v1], fa1, fa1, %[v1]      \n"
                          "fmadd.s %[v2], fa2, fa2, %[v2]      \n"
                          "fmadd.s %[v3], fa3, fa3, %[v3]      \n"
                          "addi   %[xp], %[xp], 16             \n"
#endif
                         : [ v0 ] "+f"(v0), [ v1 ] "+f"(v1), [ v2 ] "+f"(v2),
                           [ v3 ] "+f"(v3), [ xp ] "+r"(xp)
                         : [ n ] "r"(n_frep), [ mean ] "f"(mean)
                         : "fa0", "fa1", "fa2", "fa3");
            float inv_std =
                1.0f / sqrtf((v0 + v1 + v2 + v3) / (float)embeddings + eps);

            // Pass 3: normalize — 8-wide software-pipelined (peel + FREP + epilogue)
#define _P3_PEEL                             \
    "flw    fa0,  0(%[xp])               \n" \
    "flw    fa1,  4(%[xp])               \n" \
    "flw    fa2,  8(%[xp])               \n" \
    "flw    fa3, 12(%[xp])               \n" \
    "flw    fa4, 16(%[xp])               \n" \
    "flw    fa5, 20(%[xp])               \n" \
    "flw    fa6, 24(%[xp])               \n" \
    "flw    fa7, 28(%[xp])               \n" \
    "fsub.s fa0, fa0, %[mean]            \n" \
    "fsub.s fa1, fa1, %[mean]            \n" \
    "fsub.s fa2, fa2, %[mean]            \n" \
    "fsub.s fa3, fa3, %[mean]            \n" \
    "fsub.s fa4, fa4, %[mean]            \n" \
    "fsub.s fa5, fa5, %[mean]            \n" \
    "fsub.s fa6, fa6, %[mean]            \n" \
    "fsub.s fa7, fa7, %[mean]            \n" \
    "fmul.s fa0, fa0, %[inv_std]         \n" \
    "fmul.s fa1, fa1, %[inv_std]         \n" \
    "fmul.s fa2, fa2, %[inv_std]         \n" \
    "fmul.s fa3, fa3, %[inv_std]         \n" \
    "fmul.s fa4, fa4, %[inv_std]         \n" \
    "fmul.s fa5, fa5, %[inv_std]         \n" \
    "fmul.s fa6, fa6, %[inv_std]         \n" \
    "fmul.s fa7, fa7, %[inv_std]         \n"

#define _P3_BODY_EPILOGUE                    \
    "addi   %[xp], %[xp], 32             \n" \
    "fsw    fa0,  0(%[yp])               \n" \
    "fsw    fa1,  4(%[yp])               \n" \
    "fsw    fa2,  8(%[yp])               \n" \
    "fsw    fa3, 12(%[yp])               \n" \
    "flw    fa0,  0(%[xp])               \n" \
    "flw    fa1,  4(%[xp])               \n" \
    "flw    fa2,  8(%[xp])               \n" \
    "flw    fa3, 12(%[xp])               \n" \
    "fsub.s fa0, fa0, %[mean]            \n" \
    "fsub.s fa1, fa1, %[mean]            \n" \
    "fsub.s fa2, fa2, %[mean]            \n" \
    "fsub.s fa3, fa3, %[mean]            \n" \
    "fmul.s fa0, fa0, %[inv_std]         \n" \
    "fmul.s fa1, fa1, %[inv_std]         \n" \
    "fmul.s fa2, fa2, %[inv_std]         \n" \
    "fmul.s fa3, fa3, %[inv_std]         \n" \
    "fsw    fa4, 16(%[yp])               \n" \
    "fsw    fa5, 20(%[yp])               \n" \
    "fsw    fa6, 24(%[yp])               \n" \
    "fsw    fa7, 28(%[yp])               \n" \
    "addi   %[yp], %[yp], 32             \n" \
    "flw    fa4, 16(%[xp])               \n" \
    "flw    fa5, 20(%[xp])               \n" \
    "flw    fa6, 24(%[xp])               \n" \
    "flw    fa7, 28(%[xp])               \n" \
    "fsub.s fa4, fa4, %[mean]            \n" \
    "fsub.s fa5, fa5, %[mean]            \n" \
    "fsub.s fa6, fa6, %[mean]            \n" \
    "fsub.s fa7, fa7, %[mean]            \n" \
    "fmul.s fa4, fa4, %[inv_std]         \n" \
    "fmul.s fa5, fa5, %[inv_std]         \n" \
    "fmul.s fa6, fa6, %[inv_std]         \n" \
    "fmul.s fa7, fa7, %[inv_std]         \n" \
    "fsw    fa0,  0(%[yp])               \n" \
    "fsw    fa1,  4(%[yp])               \n" \
    "fsw    fa2,  8(%[yp])               \n" \
    "fsw    fa3, 12(%[yp])               \n" \
    "fsw    fa4, 16(%[yp])               \n" \
    "fsw    fa5, 20(%[yp])               \n" \
    "fsw    fa6, 24(%[yp])               \n" \
    "fsw    fa7, 28(%[yp])               \n"

#define _P3_BODY_EPILOGUE_BAL                \
    "addi   %[xp], %[xp], 32             \n" \
    "fsw    fa0,  0(%[yp])               \n" \
    "fsw    fa1,  4(%[yp])               \n" \
    "fsw    fa2,  8(%[yp])               \n" \
    "fsw    fa3, 12(%[yp])               \n" \
    "flw    fa0,  0(%[xp])               \n" \
    "fsub.s fa0, fa0, %[mean]            \n" \
    "flw    fa1,  4(%[xp])               \n" \
    "fsub.s fa1, fa1, %[mean]            \n" \
    "flw    fa2,  8(%[xp])               \n" \
    "fsub.s fa2, fa2, %[mean]            \n" \
    "flw    fa3, 12(%[xp])               \n" \
    "fsub.s fa3, fa3, %[mean]            \n" \
    "fmul.s fa0, fa0, %[inv_std]         \n" \
    "fsw    fa4, 16(%[yp])               \n" \
    "fmul.s fa1, fa1, %[inv_std]         \n" \
    "fsw    fa5, 20(%[yp])               \n" \
    "fmul.s fa2, fa2, %[inv_std]         \n" \
    "fsw    fa6, 24(%[yp])               \n" \
    "fmul.s fa3, fa3, %[inv_std]         \n" \
    "fsw    fa7, 28(%[yp])               \n" \
    "addi   %[yp], %[yp], 32             \n" \
    "flw    fa4, 16(%[xp])               \n" \
    "fsub.s fa4, fa4, %[mean]            \n" \
    "flw    fa5, 20(%[xp])               \n" \
    "fsub.s fa5, fa5, %[mean]            \n" \
    "flw    fa6, 24(%[xp])               \n" \
    "fsub.s fa6, fa6, %[mean]            \n" \
    "flw    fa7, 28(%[xp])               \n" \
    "fsub.s fa7, fa7, %[mean]            \n" \
    "fmul.s fa4, fa4, %[inv_std]         \n" \
    "fmul.s fa5, fa5, %[inv_std]         \n" \
    "fmul.s fa6, fa6, %[inv_std]         \n" \
    "fmul.s fa7, fa7, %[inv_std]         \n" \
    "fsw    fa0,  0(%[yp])               \n" \
    "fsw    fa1,  4(%[yp])               \n" \
    "fsw    fa2,  8(%[yp])               \n" \
    "fsw    fa3, 12(%[yp])               \n" \
    "fsw    fa4, 16(%[yp])               \n" \
    "fsw    fa5, 20(%[yp])               \n" \
    "fsw    fa6, 24(%[yp])               \n" \
    "fsw    fa7, 28(%[yp])               \n"

#define _P3_OPERANDS                                                                   \
                : [ xp ] "+r"(xp), [ yp ] "+r"(yp) \
                : [ n ]  "r"(n_frep_pass3 - 1), [ mean ] "f"(mean), [ inv_std ] "f"(inv_std) \
                : "fa0","fa1","fa2","fa3","fa4","fa5","fa6","fa7","memory"
            xp = x;
            float *yp = y;

#ifdef BALANCE_INSTRUCTION_MIX
            asm volatile(
                _P3_PEEL FREP
                " %[n], 34, 0, 0 \n" _P3_BODY_EPILOGUE_BAL _P3_OPERANDS);
#else
            asm volatile(_P3_PEEL FREP
                         " %[n], 34, 0, 0 \n" _P3_BODY_EPILOGUE _P3_OPERANDS);
#endif

#undef _P3_PEEL
#undef _P3_BODY_EPILOGUE
#undef _P3_BODY_EPILOGUE_BAL
#undef _P3_OPERANDS
        }
    }
}