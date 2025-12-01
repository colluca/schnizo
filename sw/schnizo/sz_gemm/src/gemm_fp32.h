// Requires that A and B is regular and not transposed!
// Should work for all MNK possible dimensions, not tested for very specific edge cases


static inline void gemm_fp32_vec_frep(uint32_t setup_ssr, uint32_t partition_banks,
                                 uint32_t transa, uint32_t transb, uint32_t M,
                                 uint32_t N, uint32_t K, void* A_p,
                                 uint32_t lda, void* B_p, uint32_t ldb,
                                 uint32_t beta, void* C_p, uint32_t ldc) {

    if (transa || transb || partition_banks)
        return; // Fallback not implemented here.

    snrt_mcycle();

    uint32_t inc_b = (uint32_t)ldb * sizeof(float);
    uint32_t inc_a = sizeof(float);

    int computed_col = 0;
    while (computed_col < N) {

        int vl;
        asm volatile("vsetvli %[vl], %[rvl], e32, m2, ta, ma"
                 : [vl] "=r"(vl)
                 : [rvl] "r"(N-computed_col));

        float * C_l1 = (float *)C_p + computed_col;
        float * B_l1 = (float *)B_p + computed_col;

        for (int i = 0; i < M; i += 2) {
            float* C_l2_1 = C_l1 + ldc * i;
            float* C_l2_2 = C_l1 + ldc * (i + 1);

            uint8_t use_second = i + 1 < M;

            if (beta) {
                asm volatile("vle32.v v0, (%0);" ::"r"(C_l2_1));
                if (use_second) asm volatile("vle32.v v8, (%0);" ::"r"(C_l2_2));
            } else {
                asm volatile("vmv.v.i v0, 0");
                if (use_second) asm volatile("vmv.v.i v8, 0");
            }

            float* B_l3_1 = B_l1;

            float* A_l3_1 = (float*)A_p + lda * i;
            float* A_l3_2 = (float*)A_p + lda * (i + 1);

            float t0 = *A_l3_1;
            float t1 = *A_l3_2;

            asm volatile(
                "frep.o  %[n_frep], 8, 0, 0 \n"
                // Body:
                "vle32.v v16, (%[ptr_b])\n"
                "add     %[ptr_b], %[ptr_b], %[inc_b]\n"
                "vfmacc.vf v0, %[ft0], v16\n"
                "vfmacc.vf v8, %[ft1], v16\n"
                "add     %[ptr_a0], %[ptr_a0], %[inc_a]\n"
                "fld     %[ft0], 0(%[ptr_a0])\n"
                "add     %[ptr_a1], %[ptr_a1], %[inc_a]\n"
                "fld     %[ft1], 0(%[ptr_a1])\n"
                : [ptr_b] "+r"(B_l3_1), [ptr_a0] "+r"(A_l3_1),
                  [ptr_a1] "+r"(A_l3_2), [ft0] "+f"(t0), [ft1] "+f"(t1)
                : [inc_b] "r"(inc_b), [inc_a] "r"(inc_a), [n_frep] "r"(K - 1)
                : "memory");

            asm volatile("vse32.v v0, (%0);" ::"r"(C_l2_1));
            if (use_second) asm volatile("vse32.v v8, (%0);" ::"r"(C_l2_2));
        }

        asm volatile("fence");
        computed_col += vl;
    }

    asm volatile("fence");
    snrt_mcycle();
}

static inline void gemm_fp32_vec_naive_2sregs(uint32_t setup_ssr, uint32_t partition_banks,
                                       uint32_t transa, uint32_t transb,
                                       uint32_t M, uint32_t N, uint32_t K,
                                       void *A_p, uint32_t lda, void *B_p, uint32_t ldb,
                                       uint32_t beta, void *C_p, uint32_t ldc) {
    // Only supports !transa && !transb and non bank-partitioned layout.
    if (transa || transb || partition_banks)
        return; // Fallback not implemented here.

    snrt_mcycle();

    int computed_col = 0;
    while (computed_col < N) {

        int vl;
        asm volatile("vsetvli %[vl], %[rvl], e32, m2, ta, ma"
                 : [vl] "=r"(vl)
                 : [rvl] "r"(N-computed_col));

        double * C_l1 = (double *)C_p + computed_col;
        double * B_l1 = (double *)B_p + computed_col;

        for(int i = 0; i < M; i+=2) {
            double *C_l2_1 = C_l1 + ldc*i;
            double *C_l2_2 = C_l1 + ldc*(i+1);

            uint8_t use_second = i+1 < M;

            if (beta) {
                asm volatile("vle32.v v0, (%0);" ::"r"(C_l2_1));
                if (use_second) asm volatile("vle32.v v8, (%0);" ::"r"(C_l2_2));
            } else {
                asm volatile("vmv.v.i v0, 0");
                if (use_second) asm volatile("vmv.v.i v8, 0");
            }
            
            double * B_l3_1 = B_l1;

            double *A_l3_1 = (double *)A_p + lda*i;
            double *A_l3_2 = (double *)A_p + lda*(i+1);

            double t0 = *A_l3_1;
            double t1 = *A_l3_2;

            #pragma clang loop unroll(disable)
            for (int j = 0; j < K; j++) {
                asm volatile("vle32.v v16, (%0);" ::"r"(B_l3_1));
                B_l3_1 += ldb;
                asm volatile("vfmacc.vf v0, %0, v16" ::"f"(t0));
                A_l3_1++; t0 = *A_l3_1;
                asm volatile("vfmacc.vf v8, %0, v16" ::"f"(t1));
                A_l3_2++; t1 = *A_l3_2;
            }

            asm volatile("vse32.v v0, (%0);" ::"r"(C_l2_1));
            if (use_second) asm volatile("vse32.v v8, (%0);" ::"r"(C_l2_2));
        }

        computed_col += vl;
    }

    
    asm volatile("fence");
    snrt_mcycle();
}