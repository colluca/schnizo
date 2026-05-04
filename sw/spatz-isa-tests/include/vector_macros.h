// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Wrapper around the upstream spatz vector_macros.h that makes all tests
// compatible with a fixed 256-bit SIMD (VLEN=256) implementation.
//
// Strategy:
//   1. Include the real vector_macros.h via #include_next.
//   2. Override VSET / VSETMAX to capture the *actual* vl returned by
//      vsetvli into _spatz_vl (hardware clamps to min(AVL, VLMAX)).
//   3. Override VCMP to iterate only over _spatz_vl elements, not over
//      the full list of expected values supplied by the test.
//
// Tests that supply more expected values than _spatz_vl will silently
// ignore the excess ? which is correct since those elements were never
// computed.

#ifndef __SPATZ_SIMD_VECTOR_MACROS_WRAPPER_H__
#define __SPATZ_SIMD_VECTOR_MACROS_WRAPPER_H__

// Pull in the real vector_macros.h (next match in include search path)
#include_next "vector_macros.h"

// Per-TU vl tracker ? set to exactly VLEN/SEW = 256/SEW by VSET
static unsigned int _spatz_vl = 0;

// Map SEW token ? element count for a single 256-bit register
#define _SPATZ_NELEMS_e8 32
#define _SPATZ_NELEMS_e16 16
#define _SPATZ_NELEMS_e32 8
#define _SPATZ_NELEMS_e64 4

// ?? VSET override ??????????????????????????????????????????????????????????
// The hardware only supports full 256-bit vector operations: vl must always
// equal VLEN/SEW = 256/SEW.  We pass that count as AVL so vsetvli always
// returns exactly 256/SEW regardless of what the test originally requested
// or which LMUL is used.  VLOAD zero-pads to _spatz_vl so the full register
// is initialised before the instruction runs.
#undef VSET
#define VSET(VSET_AVL, VTYPE, LMUL)                                     \
    do {                                                                \
        const unsigned int _vset_fixed = _SPATZ_NELEMS_##VTYPE;         \
        asm volatile("vsetvli %[vl], %[A]," #VTYPE "," #LMUL ", ta, ma" \
                     : [ vl ] "=r"(_spatz_vl)                           \
                     : [ A ] "r"(_vset_fixed));                         \
    } while (0)

#undef VSETMAX
#define VSETMAX(VTYPE, LMUL)                                            \
    do {                                                                \
        const unsigned int _vset_fixed = _SPATZ_NELEMS_##VTYPE;         \
        asm volatile("vsetvli %[vl], %[A]," #VTYPE "," #LMUL ", ta, ma" \
                     : [ vl ] "=r"(_spatz_vl)                           \
                     : [ A ] "r"(_vset_fixed));                         \
    } while (0)

// ?? VCLEAR override ????????????????????????????????????????????????????????
// The upstream VCLEAR does csrr vtype / csrr vl, which hit unimplemented CSRs
// in schnizo's snitch (only spatz's snitch wires up CSR_VL/CSR_VTYPE at 0xC20/0xC21).
// Reading an unimplemented CSR causes an illegal-instruction trap.
// For SIMD, zeroing the register with the current active vl/vsew is sufficient.
#undef VCLEAR
#define VCLEAR(vreg) asm volatile("vmv.v.i " #vreg ", 0")

// ?? VSTORE override ????????????????????????????????????????????????????????
// The original VSTORE uses whatever vl is current in the hardware.  After a
// widening instruction the hardware vl still reflects the *input* SEW count
// (e.g. 16 for e16 inputs), so a subsequent VSTORE_U32 would try to store
// 16×4 = 64 bytes even though only 8 EW_32 results (32 bytes) were written.
// The upper half of the store buffer is X, making scalar comparison loads X.
// Fix: re-issue vsetvli for the store element type (m1 sufficient for SIMD)
// so that exactly VLEN/store-SEW elements are stored and _spatz_vl is updated
// to match, giving VCMP the correct iteration count.
#undef VSTORE
#define VSTORE(T, storetype, vreg, vec)                                   \
    do {                                                                  \
        const unsigned int _vstore_fixed = _SPATZ_NELEMS_##storetype;     \
        asm volatile("vsetvli %[vl], %[A]," #storetype ",m1, ta, ma"      \
                     : [ vl ] "=r"(_spatz_vl)                             \
                     : [ A ] "r"(_vstore_fixed));                         \
        asm volatile("vs" #storetype ".v " #vreg ", (%0)\n" : "+r"(vec)); \
    } while (0)

// ?? VLOAD override ?????????????????????????????????????????????????????????
// The original VLOAD allocates exactly as many elements as the caller
// provides.  If the caller supplies fewer values than _spatz_vl the upper
// elements are uninitialized, causing X-propagation in simulation and
// spurious VCMP failures.  This override zero-pads the allocation to
// _spatz_vl so the vector register is fully defined before the instruction
// operates on it.
#undef VLOAD
#define VLOAD(datatype, loadtype, vreg, vec...)                           \
    do {                                                                  \
        const datatype _vsrc_##vreg[] = {vec};                            \
        const unsigned int _vn_##vreg =                                   \
            sizeof(_vsrc_##vreg) / sizeof(datatype);                      \
        datatype *V##vreg =                                               \
            (datatype *)snrt_l1alloc(_spatz_vl * sizeof(datatype));       \
        for (unsigned int _vi = 0; _vi < _spatz_vl; _vi++)                \
            V##vreg[_vi] =                                                \
                (_vi < _vn_##vreg) ? _vsrc_##vreg[_vi] : (datatype)0;     \
        asm volatile("vl" #loadtype ".v " #vreg ", (%0)" ::"r"(V##vreg)); \
    } while (0)

// ?? VCMP override ??????????????????????????????????????????????????????????
// Clamp the comparison loop to min(_spatz_vl, n_expected) so we never:
//   - read past the end of the expected-value array (if vl > n_expected), or
//   - compare elements that were not computed (if n_expected > vl).
#undef VCMP
#define VCMP(T, str, casenum, vexp, act...)                                    \
    do {                                                                       \
        const T vact[] = {act};                                                \
        const unsigned int _vn_act = sizeof(vact) / sizeof(T);                 \
        const unsigned int _vn_cmp =                                           \
            (_spatz_vl < _vn_act) ? _spatz_vl : _vn_act;                       \
        for (unsigned int _i = 0; _i < _vn_cmp; _i++) {                        \
            if (vexp[_i] != vact[_i]) {                                        \
                printf("[TC %d] Index %d FAILED. Got " #str ", expected " #str \
                       ".\n",                                                  \
                       casenum, _i, vexp[_i], vact[_i]);                       \
                num_failed++;                                                  \
                return;                                                        \
            }                                                                  \
        }                                                                      \
        printf("[TC %d] PASSED.\n", casenum);                                  \
    } while (0)

#endif  // __SPATZ_SIMD_VECTOR_MACROS_WRAPPER_H__
