// Copyright 2020 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "snrt.h"

#include "batchnorm_fp32.h"

typedef void (*batchnorm_fp_t)(void *ifmap, void *gamma, void *beta,
                               void *ofmap, uint32_t CI, uint32_t n_pixels);

typedef struct {
    uint32_t CI;
    uint32_t IH;
    uint32_t IW;
    batchnorm_fp_t funcptr;
    void *ifmap;
    void *gamma;
    void *beta;
    void *ofmap;
    precision_t dtype;
} batchnorm_layer_t;

/**
 * @brief FP64 batchnorm: y = gamma * x + beta, using SSR for streaming.
 */
static inline void batchnorm_fp64(double *ifmap, double *gamma, double *beta,
                                  double *ofmap, uint32_t OW, uint32_t CI,
                                  uint32_t compute_num, uint32_t setup_SSR) {
#ifdef SNRT_SUPPORTS_FREP
#ifdef SNRT_SUPPORTS_SSR

    if (setup_SSR) {
        uint32_t ssr_b[2] = {OW, CI / compute_num};
        uint32_t ssr_i[2] = {CI * sizeof(double), compute_num * sizeof(double)};

        snrt_ssr_loop_2d(SNRT_SSR_DM0, ssr_b[0], ssr_b[1], ssr_i[0], ssr_i[1]);
        snrt_ssr_loop_2d(SNRT_SSR_DM1, ssr_b[0], ssr_b[1], ssr_i[0], ssr_i[1]);
    }

    snrt_ssr_read(SNRT_SSR_DM0, SNRT_SSR_2D, ifmap);
    snrt_ssr_write(SNRT_SSR_DM1, SNRT_SSR_2D, ofmap);
    snrt_ssr_enable();

    for (uint32_t ci = 0; ci < CI; ci += compute_num) {
        double g = gamma[ci];
        double b = beta[ci];

        asm volatile(
            "frep.o %[n_frep], 1, 0, 0 \n"
            "fmadd.d ft1, ft0, %[g], %[b] \n" ::[g] "f"(g),
            [b] "f"(b), [n_frep] "r"(OW - 1)
            : "ft0", "ft1", "ft2");
    }
    snrt_fpu_fence();
    snrt_ssr_disable();
#endif
#endif
}

static inline void batchnorm_layer(batchnorm_layer_t l) {
    uint32_t n_pixels = l.IH * l.IW;
    uint32_t data_type_size = l.dtype;
    uint32_t ifmap_size = l.CI * n_pixels * data_type_size;
    uint32_t weights_size = l.CI * data_type_size;

    char *local_ifmap = (char *)snrt_l1_next();
    char *local_gamma = local_ifmap + ifmap_size;
    char *local_beta = local_gamma + weights_size;
    char *local_ofmap = local_beta + weights_size;

    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(local_ifmap, l.ifmap, ifmap_size);
        snrt_dma_start_1d(local_gamma, l.gamma, weights_size);
        snrt_dma_start_1d(local_beta, l.beta, weights_size);
        snrt_dma_wait_all();
    }

    snrt_cluster_hw_barrier();

    if (snrt_is_compute_core()) {
        snrt_mcycle();
        l.funcptr(local_ifmap, local_gamma, local_beta, local_ofmap, l.CI,
                  n_pixels);
        snrt_mcycle();
    }

    snrt_cluster_hw_barrier();

    if (snrt_is_dm_core()) {
        snrt_dma_start_1d(l.ofmap, local_ofmap, ifmap_size);
        snrt_dma_wait_all();
    }

    snrt_global_barrier();
}
