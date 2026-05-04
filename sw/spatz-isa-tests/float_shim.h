// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Compatibility shim for spatz ISA tests that were written against an older
// ara-style test framework.  The spatz vector_macros.h uses different names:
//   ara name       ? spatz equivalent
//   VLOAD_F64      ? VLOAD(uint64_t, e64, ...)
//   VLOAD_F32      ? VLOAD(uint32_t, e32, ...)
//   VLOAD_U64      ? VLOAD(uint64_t, e64, ...)
//   VLOAD_U32      ? VLOAD(uint32_t, e32, ...)
//   VLOAD_U8       ? VLOAD(uint8_t,  e8,  ...)
//   VEC_CMP_U64    ? VCMP_U64
//   VEC_CMP_U32    ? VCMP_U32
//   VEC_CMP_U8     ? VCMP_U8
//   VEC_CMP_8      ? VCMP_I8  (signed, values can be negative)
//   VEC_CMP_F32    ? VCMP_U32 (compares raw float32 bits as uint32)
//   CLEAR(vreg)    ? VCLEAR(vreg)
//   _d(x).i        ? inline function returning double_bits.i (uint64_t)
//   _f(x).i        ? inline function returning float_bits.i  (uint32_t)

#ifndef FLOAT_SHIM_H
#define FLOAT_SHIM_H

#include <stdint.h>

// _d / _f: convert a float/double literal to its raw integer bit pattern
typedef union {
    double d;
    uint64_t i;
} _double_bits_t;
typedef union {
    float f;
    uint32_t i;
} _float_bits_t;

static inline _double_bits_t _d(double x) {
    _double_bits_t u;
    u.d = x;
    return u;
}
static inline _float_bits_t _f(float x) {
    _float_bits_t u;
    u.f = x;
    return u;
}

// Vector load aliases
#define VLOAD_F64(vreg, vec...) VLOAD(uint64_t, e64, vreg, ##vec)
#define VLOAD_F32(vreg, vec...) VLOAD(uint32_t, e32, vreg, ##vec)
#define VLOAD_U64(vreg, vec...) VLOAD(uint64_t, e64, vreg, ##vec)
#define VLOAD_U32(vreg, vec...) VLOAD(uint32_t, e32, vreg, ##vec)
#define VLOAD_U8(vreg, vec...) VLOAD(uint8_t, e8, vreg, ##vec)

// Vector compare aliases
#define VEC_CMP_U64(casenum, vreg, act...) VCMP_U64(casenum, vreg, ##act)
#define VEC_CMP_U32(casenum, vreg, act...) VCMP_U32(casenum, vreg, ##act)
#define VEC_CMP_U8(casenum, vreg, act...) VCMP_U8(casenum, vreg, ##act)
#define VEC_CMP_8(casenum, vreg, act...) VCMP_I8(casenum, vreg, ##act)
// VEC_CMP_F32 is used with _f(x).i (raw uint32 bits), so compare as uint32
#define VEC_CMP_F32(casenum, vreg, act...) VCMP_U32(casenum, vreg, ##act)

// Vector clear alias
#define CLEAR(vreg) VCLEAR(vreg)

// Scalar FP load: store raw bits to stack, then flw into the FP register
#define FLOAD32(freg, bits)                                      \
    do {                                                         \
        uint32_t _fload_tmp = (uint32_t)(bits);                  \
        asm volatile("flw " #freg ", 0(%0)" ::"r"(&_fload_tmp)); \
    } while (0)

#endif  // FLOAT_SHIM_H
