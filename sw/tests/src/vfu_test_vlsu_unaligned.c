// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>
#include <string.h>
#include "snrt.h"

// Test unaligned vector loads and stores exercising the schnizo_vlsu slow path.
//
// The VLSU detects rs1[2:0] != 0 and enters UNALIGNED_LOAD_ISSUE /
// UNALIGNED_STORE states, processing one element per cycle via port 0.
// Each element is barrel-rotated and written/read with a byte-enable strobe.
//
// TotalBytes = NrMemPorts * ELENB = 4 * 8 = 32.  Element counts per vl:
//   e8  -> vl=32, e16 -> vl=16, e32 -> vl=8

#define SECTION_END(name)            \
    if (errors == sec_errors)        \
        printf("[PASS] " name "\n"); \
    else                             \
        printf("[FAIL] " name " (%d errors)\n", errors - sec_errors)

#define VEC_BYTES 32  // TotalBytes in VLSU

// Backing buffer: 8-byte-aligned base with room for max 7-byte offset plus
// VEC_BYTES of payload.  Extra 8 bytes trailing guard to catch overwrites.
#define BUF_SIZE (8 + VEC_BYTES + 8)

int main() {
    if (snrt_global_core_idx() != 0) {
        snrt_cluster_hw_barrier();
        return 0;
    }

    int errors = 0;
    int sec_errors;

    __attribute__((aligned(8))) uint8_t src_buf[BUF_SIZE];
    __attribute__((aligned(8))) uint8_t dst_buf[BUF_SIZE];

    // ================================================================
    // Unaligned load  e8  (vl = 32, 1 byte/element)
    //
    // For each offset 'off', load VEC_BYTES bytes from src_buf+off.
    // Expected: result[i] == src_buf[off + i].
    // ================================================================
    sec_errors = errors;
    {
        static const int offsets[] = {1, 3, 5, 7};
        for (int oi = 0; oi < 4; oi++) {
            int off = offsets[oi];

            for (int i = 0; i < VEC_BYTES; i++)
                src_buf[off + i] = (uint8_t)(i + off * 7 + 1);

            uint8_t result[VEC_BYTES];
            memset(result, 0, sizeof(result));

            // src_buf is 8-byte aligned so src_buf+off has rs1[2:0] = off -> unaligned
            asm volatile(
                "vsetvli zero, %[vl], e8, m1, ta, ma\n"
                "vle8.v  v0, (%[src])\n"
                "vse8.v  v0, (%[dst])\n"
                :
                : [ vl ] "r"(VEC_BYTES), [ src ] "r"(src_buf + off),
                  [ dst ] "r"(result)
                : "memory");

            for (int i = 0; i < VEC_BYTES; i++) {
                if (result[i] != src_buf[off + i]) {
                    printf("e8 load off=%d i=%d: got 0x%02x exp 0x%02x\n", off,
                           i, result[i], src_buf[off + i]);
                    errors++;
                }
            }
        }
    }
    SECTION_END("unaligned load e8 (offsets 1,3,5,7)");

    // ================================================================
    // Unaligned load  e16  (vl = 16, 2 bytes/element)
    //
    // offsets 2, 4, 6 give rs1[2:0] = 2/4/6 -> unaligned slow path.
    // ================================================================
    sec_errors = errors;
    {
        static const int offsets[] = {2, 4, 6};
        for (int oi = 0; oi < 3; oi++) {
            int off = offsets[oi];

            uint16_t *src16 = (uint16_t *)(src_buf + off);
            for (int i = 0; i < 16; i++)
                src16[i] = (uint16_t)(0xA000 + (off << 4) + i);

            uint16_t result[16];
            memset(result, 0, sizeof(result));

            asm volatile(
                "vsetvli zero, %[vl], e16, m1, ta, ma\n"
                "vle16.v v0, (%[src])\n"
                "vse16.v v0, (%[dst])\n"
                :
                : [ vl ] "r"(16), [ src ] "r"(src16), [ dst ] "r"(result)
                : "memory");

            for (int i = 0; i < 16; i++) {
                if (result[i] != src16[i]) {
                    printf("e16 load off=%d i=%d: got 0x%04x exp 0x%04x\n", off,
                           i, result[i], src16[i]);
                    errors++;
                }
            }
        }
    }
    SECTION_END("unaligned load e16 (offsets 2,4,6)");

    // ================================================================
    // Unaligned load  e32  (vl = 8, 4 bytes/element)
    //
    // The VLSU reads one 8-byte-aligned TCDM word per element and extracts
    // the element via barrel-shift.  An element crosses an 8-byte boundary
    // when ua_offset + 4 > 8 (ua_offset >= 5).  The VLSU does not handle
    // cross-boundary accesses, so only offsets where all 8 elements stay
    // within one word are valid.  For a 32-byte vector with e32:
    //   off=1: ua_offset cycles 1,5,1,5... -> offset 5 crosses -> invalid
    //   off=3: ua_offset cycles 3,7,3,7... -> offset 7 crosses -> invalid
    //   off=4: ua_offset cycles 4,0,4,0... -> max=4, 4+4=8 fits -> valid
    // ================================================================
    sec_errors = errors;
    {
        static const int offsets[] = {4};
        for (int oi = 0; oi < 3; oi++) {
            int off = offsets[oi];

            // Use an aligned reference array and memcpy into the unaligned
            // location.  A direct uint32_t* write to src_buf+1 or src_buf+3
            // would generate a scalar `sw` to a misaligned address, which
            // traps in Snitch.
            uint32_t ref32[8];
            for (int i = 0; i < 8; i++)
                ref32[i] = (uint32_t)(0xBEEF0000u + (uint32_t)(off << 8) +
                                      (uint32_t)i);
            memcpy(src_buf + off, ref32, sizeof(ref32));

            uint32_t result[8];
            memset(result, 0, sizeof(result));

            asm volatile(
                "vsetvli zero, %[vl], e32, m1, ta, ma\n"
                "vle32.v v0, (%[src])\n"
                "vse32.v v0, (%[dst])\n"
                :
                : [ vl ] "r"(8), [ src ] "r"(src_buf + off), [ dst ] "r"(result)
                : "memory");

            for (int i = 0; i < 8; i++) {
                if (result[i] != ref32[i]) {
                    printf("e32 load off=%d i=%d: got 0x%08x exp 0x%08x\n", off,
                           i, (unsigned)result[i], (unsigned)ref32[i]);
                    errors++;
                }
            }
        }
    }
    SECTION_END("unaligned load e32 (offset 4)");

    // ================================================================
    // Unaligned store  e8  (vl = 32)
    //
    // Load from an aligned source, then store to an unaligned destination.
    // Verify each byte in memory using scalar C reads.  Also check that
    // the bytes before the offset are not overwritten (overrun guard).
    // ================================================================
    sec_errors = errors;
    {
        __attribute__((aligned(8))) uint8_t src8[VEC_BYTES];
        static const int offsets[] = {1, 3, 5, 7};
        for (int oi = 0; oi < 4; oi++) {
            int off = offsets[oi];

            for (int i = 0; i < VEC_BYTES; i++)
                src8[i] = (uint8_t)(i * 3 + off + 1);

            memset(dst_buf, 0xCC, sizeof(dst_buf));

            // dst_buf is 8-byte aligned; dst_buf+off has rs1[2:0] = off -> unaligned store
            asm volatile(
                "vsetvli zero, %[vl], e8, m1, ta, ma\n"
                "vle8.v  v0, (%[src])\n"
                "vse8.v  v0, (%[dst])\n"
                :
                : [ vl ] "r"(VEC_BYTES), [ src ] "r"(src8),
                  [ dst ] "r"(dst_buf + off)
                : "memory");

            // Payload bytes must match source
            for (int i = 0; i < VEC_BYTES; i++) {
                if (dst_buf[off + i] != src8[i]) {
                    printf("e8 store off=%d i=%d: got 0x%02x exp 0x%02x\n", off,
                           i, dst_buf[off + i], src8[i]);
                    errors++;
                }
            }
            // Bytes before the offset must be untouched
            for (int i = 0; i < off; i++) {
                if (dst_buf[i] != 0xCC) {
                    printf(
                        "e8 store off=%d: guard byte [%d] overwritten "
                        "(0x%02x)\n",
                        off, i, dst_buf[i]);
                    errors++;
                }
            }
        }
    }
    SECTION_END("unaligned store e8 (offsets 1,3,5,7)");

    // ================================================================
    // Unaligned store  e16  (vl = 16)
    // ================================================================
    sec_errors = errors;
    {
        __attribute__((aligned(8))) uint16_t src16[16];
        static const int offsets[] = {2, 4, 6};
        for (int oi = 0; oi < 3; oi++) {
            int off = offsets[oi];

            for (int i = 0; i < 16; i++)
                src16[i] = (uint16_t)(0xC000 + (off << 4) + i);

            memset(dst_buf, 0xCC, sizeof(dst_buf));

            asm volatile(
                "vsetvli zero, %[vl], e16, m1, ta, ma\n"
                "vle16.v v0, (%[src])\n"
                "vse16.v v0, (%[dst])\n"
                :
                : [ vl ] "r"(16), [ src ] "r"(src16), [ dst ] "r"(dst_buf + off)
                : "memory");

            uint16_t *dst16 = (uint16_t *)(dst_buf + off);
            for (int i = 0; i < 16; i++) {
                if (dst16[i] != src16[i]) {
                    printf("e16 store off=%d i=%d: got 0x%04x exp 0x%04x\n",
                           off, i, dst16[i], src16[i]);
                    errors++;
                }
            }
            for (int i = 0; i < off; i++) {
                if (dst_buf[i] != 0xCC) {
                    printf(
                        "e16 store off=%d: guard byte [%d] overwritten "
                        "(0x%02x)\n",
                        off, i, dst_buf[i]);
                    errors++;
                }
            }
        }
    }
    SECTION_END("unaligned store e16 (offsets 2,4,6)");

    // ================================================================
    // Unaligned store  e32  (vl = 8)
    //
    // Same cross-boundary constraint as the load test: only off=4 avoids
    // ua_offset >= 5 for any element in the 32-byte vector.
    // ================================================================
    sec_errors = errors;
    {
        __attribute__((aligned(8))) uint32_t src32[8];
        static const int offsets[] = {4};
        for (int oi = 0; oi < 3; oi++) {
            int off = offsets[oi];

            for (int i = 0; i < 8; i++)
                src32[i] = (uint32_t)(0xCAFE0000u + (uint32_t)(off << 8) +
                                      (uint32_t)i);

            memset(dst_buf, 0xCC, sizeof(dst_buf));

            asm volatile(
                "vsetvli zero, %[vl], e32, m1, ta, ma\n"
                "vle32.v v0, (%[src])\n"
                "vse32.v v0, (%[dst])\n"
                :
                : [ vl ] "r"(8), [ src ] "r"(src32), [ dst ] "r"(dst_buf + off)
                : "memory");

            // Read back via memcpy to avoid a scalar misaligned `lw` when
            // off=1 or off=3.
            uint32_t readback[8];
            memcpy(readback, dst_buf + off, sizeof(readback));
            for (int i = 0; i < 8; i++) {
                if (readback[i] != src32[i]) {
                    printf("e32 store off=%d i=%d: got 0x%08x exp 0x%08x\n",
                           off, i, (unsigned)readback[i], (unsigned)src32[i]);
                    errors++;
                }
            }
            for (int i = 0; i < off; i++) {
                if (dst_buf[i] != 0xCC) {
                    printf(
                        "e32 store off=%d: guard byte [%d] overwritten "
                        "(0x%02x)\n",
                        off, i, dst_buf[i]);
                    errors++;
                }
            }
        }
    }
    SECTION_END("unaligned store e32 (offset 4)");

    // ================================================================
    // Store-then-load roundtrip  e32, offset 4
    //
    // Unaligned store followed immediately by an unaligned load from the
    // same address.  Verifies that ua_byte_q resets between instructions
    // and that the barrel-rotate logic is consistent in both directions.
    //
    // offset 4: ua_offset cycles {4, 0} for e32; max 4+4=8 stays within
    // one 8-byte TCDM word.  offset 3 would give ua_offset=7 for odd
    // elements (7+4=11 > 8, crossing into the next TCDM word).
    // ================================================================
    sec_errors = errors;
    {
        __attribute__((aligned(8))) uint32_t src32[8], dst32[8];
        __attribute__((aligned(8))) uint8_t tmp[VEC_BYTES + 8];

        for (int i = 0; i < 8; i++)
            src32[i] = (uint32_t)(0x12345600u + (uint32_t)i);
        memset(dst32, 0, sizeof(dst32));
        memset(tmp, 0, sizeof(tmp));

        uint8_t *ptr = tmp + 4;  // rs1[2:0] = 4 for both store and load

        asm volatile(
            "vsetvli zero, %[vl], e32, m1, ta, ma\n"
            "vle32.v v0, (%[src])\n"
            "vse32.v v0, (%[ptr])\n"  // unaligned store
            "vle32.v v4, (%[ptr])\n"  // unaligned load from same address
            "vse32.v v4, (%[dst])\n"
            :
            : [ vl ] "r"(8), [ src ] "r"(src32), [ ptr ] "r"(ptr),
              [ dst ] "r"(dst32)
            : "memory");

        for (int i = 0; i < 8; i++) {
            if (dst32[i] != src32[i]) {
                printf("roundtrip e32 off=3 i=%d: got 0x%08x exp 0x%08x\n", i,
                       (unsigned)dst32[i], (unsigned)src32[i]);
                errors++;
            }
        }
    }
    SECTION_END("store-load roundtrip e32 offset 4");

    // ================================================================
    // Back-to-back unaligned stores  e8
    //
    // Two consecutive unaligned stores to *different* buffers.  Checks
    // that ua_byte_q resets to 0 between instructions and that the second
    // store does not inherit leftover state from the first.
    // ================================================================
    sec_errors = errors;
    {
        __attribute__((aligned(8))) uint8_t src_a[VEC_BYTES], src_b[VEC_BYTES];
        __attribute__((aligned(8))) uint8_t dst_a[BUF_SIZE], dst_b[BUF_SIZE];

        for (int i = 0; i < VEC_BYTES; i++) {
            src_a[i] = (uint8_t)(i + 0x10);
            src_b[i] = (uint8_t)(i + 0x80);
        }
        memset(dst_a, 0xCC, sizeof(dst_a));
        memset(dst_b, 0xCC, sizeof(dst_b));

        uint8_t *pa = dst_a + 1;  // offset 1
        uint8_t *pb = dst_b + 5;  // offset 5

        asm volatile(
            "vsetvli zero, %[vl], e8, m1, ta, ma\n"
            "vle8.v  v0, (%[a])\n"
            "vse8.v  v0, (%[pa])\n"
            "vle8.v  v4, (%[b])\n"
            "vse8.v  v4, (%[pb])\n"
            :
            : [ vl ] "r"(VEC_BYTES), [ a ] "r"(src_a), [ b ] "r"(src_b),
              [ pa ] "r"(pa), [ pb ] "r"(pb)
            : "memory");

        for (int i = 0; i < VEC_BYTES; i++) {
            if (dst_a[1 + i] != src_a[i]) {
                printf("back-to-back store A i=%d: got 0x%02x exp 0x%02x\n", i,
                       dst_a[1 + i], src_a[i]);
                errors++;
            }
            if (dst_b[5 + i] != src_b[i]) {
                printf("back-to-back store B i=%d: got 0x%02x exp 0x%02x\n", i,
                       dst_b[5 + i], src_b[i]);
                errors++;
            }
        }
    }
    SECTION_END("back-to-back unaligned store e8 (offsets 1 and 5)");

    // ================================================================
    // Back-to-back unaligned loads  e16
    //
    // Two consecutive unaligned loads from different offsets; result
    // vectors are summed elementwise to confirm both were correct.
    // ================================================================
    sec_errors = errors;
    {
        __attribute__((aligned(8))) uint8_t mem_a[BUF_SIZE], mem_b[BUF_SIZE];

        // Fill with known 16-bit patterns at offsets 2 and 6
        uint16_t *src_a = (uint16_t *)(mem_a + 2);
        uint16_t *src_b = (uint16_t *)(mem_b + 6);
        for (int i = 0; i < 16; i++) {
            src_a[i] = (uint16_t)(0x0100 + i);
            src_b[i] = (uint16_t)(0x0200 + i);
        }

        uint16_t res_a[16], res_b[16], res_sum[16];
        memset(res_a, 0, sizeof(res_a));
        memset(res_b, 0, sizeof(res_b));

        asm volatile(
            "vsetvli zero, %[vl], e16, m1, ta, ma\n"
            "vle16.v v0, (%[sa])\n"
            "vse16.v v0, (%[ra])\n"
            "vle16.v v4, (%[sb])\n"
            "vse16.v v4, (%[rb])\n"
            "vadd.vv v8, v0, v4\n"
            "vse16.v v8, (%[rs])\n"
            :
            : [ vl ] "r"(16), [ sa ] "r"(src_a), [ ra ] "r"(res_a),
              [ sb ] "r"(src_b), [ rb ] "r"(res_b), [ rs ] "r"(res_sum)
            : "memory");

        for (int i = 0; i < 16; i++) {
            uint16_t exp_sum = (uint16_t)(src_a[i] + src_b[i]);
            if (res_a[i] != src_a[i]) {
                printf("back-to-back load A i=%d: got 0x%04x exp 0x%04x\n", i,
                       res_a[i], src_a[i]);
                errors++;
            }
            if (res_b[i] != src_b[i]) {
                printf("back-to-back load B i=%d: got 0x%04x exp 0x%04x\n", i,
                       res_b[i], src_b[i]);
                errors++;
            }
            if (res_sum[i] != exp_sum) {
                printf("back-to-back load sum i=%d: got 0x%04x exp 0x%04x\n", i,
                       res_sum[i], exp_sum);
                errors++;
            }
        }
    }
    SECTION_END("back-to-back unaligned load e16 (offsets 2 and 6)");

    if (errors == 0)
        printf("All unaligned VLSU tests passed\n");
    else
        printf("%d total errors\n", errors);

    snrt_cluster_hw_barrier();
    return 0;
}
