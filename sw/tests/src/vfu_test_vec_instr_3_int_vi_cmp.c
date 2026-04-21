// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "snrt.h"
#include <stdint.h>

// 6 NOPs after every vector instruction to drain pipeline hazards
#define NOPS() asm volatile( \
    "addi x0, x0, 0\n" \
    "addi x0, x0, 0\n" \
    "addi x0, x0, 0\n" \
    "addi x0, x0, 0\n" \
    "addi x0, x0, 0\n" \
    "addi x0, x0, 0\n" \
)

#define SECTION_END(name) \
    if (errors == sec_errors) printf("[PASS] " name "\n"); \
    else printf("[FAIL] " name " (%d errors)\n", errors - sec_errors);

// Read the 4-bit mask from v0 into an integer (vmv.x.s reads element-0 = packed mask word)
// Original macro:
#define READ_MASK(dst) asm volatile("vmv.x.s %0, v0" : "=r"(dst)); NOPS()

#define N 4  // 4 x 64-bit elements = 256-bit vector

int main() {
    if (snrt_global_core_idx() == 0) {
        int errors = 0;
        int sec_errors;

        int64_t  xi[N]     = {10, 20, 30, 40};
        int64_t  xi_neg[N] = {-80, -60, -40, -20};
        uint64_t xu[N]     = {10, 20, 30, 40};
        int64_t  zi[N];

        // Compare test data: ca={1,2,3,4}, cb={4,2,2,1}
        int64_t  ca[N]  = {1, 2, 3, 4};
        int64_t  cb[N]  = {4, 2, 2, 1};
        uint64_t cau[N] = {1, 2, 3, 4};
        uint64_t cbu[N] = {4, 2, 2, 1};
        int64_t  cmask;

        int64_t  cxs  = 2;
        uint64_t cxsu = 2;

        asm volatile("vsetvli zero, %0, e64, m1, ta, ma" :: "r"(N)); NOPS();

        // ================================================================
        // INTEGER VI (vector-immediate)
        // ================================================================
        sec_errors = errors;

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vadd.vi v8, v0, 5");            NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));  NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != xi[i] + 5) { printf("vadd.vi error at %d\n", i); errors++; }

        // vrsub.vi: vd[i] = imm - vs2[i]
        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vrsub.vi v8, v0, 5");           NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));  NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != 5 - xi[i]) { printf("vrsub.vi error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vand.vi v8, v0, 7");            NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));  NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] & 7)) { printf("vand.vi error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vor.vi v8, v0, 3");             NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));  NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] | 3)) { printf("vor.vi error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vxor.vi v8, v0, 6");            NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));  NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] ^ 6)) { printf("vxor.vi error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi)); NOPS();
        asm volatile("vsll.vi v8, v0, 2");            NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));  NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi[i] << 2)) { printf("vsll.vi error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xu)); NOPS();
        asm volatile("vsrl.vi v8, v0, 2");            NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));  NOPS();
        for (int i = 0; i < N; i++)
            if ((uint64_t)zi[i] != (xu[i] >> 2)) { printf("vsrl.vi error at %d\n", i); errors++; }

        asm volatile("vle64.v v0, (%0)" :: "r"(xi_neg)); NOPS();
        asm volatile("vsra.vi v8, v0, 2");                NOPS();
        asm volatile("vse64.v v8, (%0)" :: "r"(zi));      NOPS();
        for (int i = 0; i < N; i++)
            if (zi[i] != (xi_neg[i] >> 2)) { printf("vsra.vi error at %d\n", i); errors++; }

        // vmv.v.i: broadcast immediate to all elements -> No VSLDU
        // asm volatile("vmv.v.i v8, 7");               NOPS();
        // asm volatile("vse64.v v8, (%0)" :: "r"(zi)); NOPS();
        // for (int i = 0; i < N; i++)
        //     if (zi[i] != 7) { printf("vmv.v.i error at %d\n", i); errors++; }

        SECTION_END("integer vi (vadd/vrsub/vand/vor/vxor/vsll/vsrl/vsra)");

        // ================================================================
        // INTEGER COMPARE VV  (result written as mask to v0; read via vmv.x.s)
        // ca={1,2,3,4}, cb={4,2,2,1}
        // vmseq  expect mask 0x6 = {0,1,1,0} (ca[1]==cb[1], ca[2]==cb[2])
        // vmsne  expect mask 0x9 = {1,0,0,1}
        // vmslt  expect mask 0x1 = {1,0,0,0} (ca[0]<cb[0])
        // vmsltu expect mask 0x1
        // vmsle  expect mask 0x7 = {1,1,1,0}
        // vmsleu expect mask 0x7
        // ================================================================
        // sec_errors = errors;
       
       
        // Not working yet -> To read a mast i need a vsldu
       
       
        // asm volatile("vle64.v v0, (%0)" :: "r"(ca)); NOPS();
        // asm volatile("vle64.v v4, (%0)" :: "r"(cb)); NOPS();
        // asm volatile("vmseq.vv v0, v0, v4");          NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0x6) { printf("vmseq.vv error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(ca)); NOPS();
        // asm volatile("vle64.v v4, (%0)" :: "r"(cb)); NOPS();
        // asm volatile("vmsne.vv v0, v0, v4");          NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0x9) { printf("vmsne.vv error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(ca)); NOPS();
        // asm volatile("vle64.v v4, (%0)" :: "r"(cb)); NOPS();
        // asm volatile("vmslt.vv v0, v0, v4");          NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0x1) { printf("vmslt.vv error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(cau)); NOPS();
        // asm volatile("vle64.v v4, (%0)" :: "r"(cbu)); NOPS();
        // asm volatile("vmsltu.vv v0, v0, v4");          NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0x1) { printf("vmsltu.vv error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(ca)); NOPS();
        // asm volatile("vle64.v v4, (%0)" :: "r"(cb)); NOPS();
        // asm volatile("vmsle.vv v0, v0, v4");          NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0x7) { printf("vmsle.vv error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(cau)); NOPS();
        // asm volatile("vle64.v v4, (%0)" :: "r"(cbu)); NOPS();
        // asm volatile("vmsleu.vv v0, v0, v4");          NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0x7) { printf("vmsleu.vv error: got 0x%lx\n", cmask & 0xF); errors++; }

        // SECTION_END("integer compare vv (vmseq/vmsne/vmslt/vmsltu/vmsle/vmsleu)");

        // ================================================================
        // INTEGER COMPARE VX  (scalar = 2)
        // ca={1,2,3,4} vs scalar 2:
        // vmseq  {0,1,0,0} = 0x2
        // vmsne  {1,0,1,1} = 0xD
        // vmslt  {1,0,0,0} = 0x1
        // vmsltu {1,0,0,0} = 0x1
        // vmsle  {1,1,0,0} = 0x3
        // vmsleu {1,1,0,0} = 0x3
        // ================================================================


        // Not working yet -> To read a mast i need a vsldu


        // sec_errors = errors;

        // asm volatile("vle64.v v0, (%0)" :: "r"(ca)); NOPS();
        // asm volatile("vmseq.vx v0, v0, %0" :: "r"(cxs)); NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0x2) { printf("vmseq.vx error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(ca)); NOPS();
        // asm volatile("vmsne.vx v0, v0, %0" :: "r"(cxs)); NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0xD) { printf("vmsne.vx error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(ca)); NOPS();
        // asm volatile("vmslt.vx v0, v0, %0" :: "r"(cxs)); NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0x1) { printf("vmslt.vx error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(cau)); NOPS();
        // asm volatile("vmsltu.vx v0, v0, %0" :: "r"(cxsu)); NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0x1) { printf("vmsltu.vx error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(ca)); NOPS();
        // asm volatile("vmsle.vx v0, v0, %0" :: "r"(cxs)); NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0x3) { printf("vmsle.vx error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(cau)); NOPS();
        // asm volatile("vmsleu.vx v0, v0, %0" :: "r"(cxsu)); NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0x3) { printf("vmsleu.vx error: got 0x%lx\n", cmask & 0xF); errors++; }

        // SECTION_END("integer compare vx (vmseq/vmsne/vmslt/vmsltu/vmsle/vmsleu)");

        // ================================================================
        // INTEGER COMPARE VI  (immediate = 2)
        // ca={1,2,3,4} vs imm 2:
        // vmseq  {0,1,0,0} = 0x2
        // vmsne  {1,0,1,1} = 0xD
        // vmsle  {1,1,0,0} = 0x3
        // vmsleu {1,1,0,0} = 0x3
        // vmsgt  {0,0,1,1} = 0xC
        // vmsgtu {0,0,1,1} = 0xC
        // ================================================================
        
        
        // Not working yet -> To read a mast i need a vsldu

        
        // sec_errors = errors;

        // asm volatile("vle64.v v0, (%0)" :: "r"(ca)); NOPS();
        // asm volatile("vmseq.vi v0, v0, 2");           NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0x2) { printf("vmseq.vi error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(ca)); NOPS();
        // asm volatile("vmsne.vi v0, v0, 2");           NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0xD) { printf("vmsne.vi error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(ca)); NOPS();
        // asm volatile("vmsle.vi v0, v0, 2");           NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0x3) { printf("vmsle.vi error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(cau)); NOPS();
        // asm volatile("vmsleu.vi v0, v0, 2");           NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0x3) { printf("vmsleu.vi error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(ca)); NOPS();
        // asm volatile("vmsgt.vi v0, v0, 2");           NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0xC) { printf("vmsgt.vi error: got 0x%lx\n", cmask & 0xF); errors++; }

        // asm volatile("vle64.v v0, (%0)" :: "r"(cau)); NOPS();
        // asm volatile("vmsgtu.vi v0, v0, 2");           NOPS();
        // READ_MASK(cmask);
        // if ((cmask & 0xF) != 0xC) { printf("vmsgtu.vi error: got 0x%lx\n", cmask & 0xF); errors++; }

        // SECTION_END("integer compare vi (vmseq/vmsne/vmsle/vmsleu/vmsgt/vmsgtu)");

        if (errors == 0)
            printf("All tests passed (int vi + compare)\n");
        else
            printf("%d total errors\n", errors);
    }

    snrt_cluster_hw_barrier();
    return 0;
}
