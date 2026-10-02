# =============================================================================
# cache_dside.S - D-cache and write buffer (docs/architecture.md P4.3, P4.6)
# -----------------------------------------------------------------------------
# Runs on every model; on the cache model (Vcore_tb_cache) the CACHE-EXPECT
# floors prove that each case reaches the cache path it names. `buf` is 4 KB,
# 2 KB aligned, and cold at the start (nothing reads or writes it before).
#
#   2  store miss, then at once a load of the same word: the store is still in
#      the write buffer, so the load miss must wait for it (P4.3 rule 1)
#   3  a line is refilled, then sb/sh store hits merge into it; lw/lbu/lh read
#      the merged bytes back from the cache
#   4  sb to each of the 4 lanes of a cached word
#   5  conflict at a 2 KB stride: A and B share an index. A no-allocate store
#      to B leaves A cached; loading B evicts A; A misses again
#   6  four back-to-back stores to four lines (the 2-entry write buffer
#      fills), then read back
#   7  4 KB sweep (twice the cache): write, then read back and compare
#      checksums, twice (every line conflicts, so both passes miss per line)
#   8  2 KB region read twice: the second pass hits on every word
#   9  uncached access after buffered stores: a load from an unmapped
#      address (below MEM_BASE, so it bypasses the cache) raises a precise
#      load access fault; the buffered store before it has reached memory
#  10  a burst of 8 stores run 4 times: from the second iteration the loop
#      runs from the I-cache, so the stores arrive every 2 cycles, as fast as
#      the D-cache accepts them. With random latency the write buffer (one
#      write in flight, P4.3) falls behind and fills; then read back
#
# Derived floors (ideal memory, cache model; 16-byte lines, 4 words). Before
# case 7 at most 8 lines of buf are cached (cases 2-6 touch lines 0-7 and B).
#   dc_ld_miss >= 641: case 2: 1; 3: 1; 5: 3; 6: 4; 7: >= 504 (2 passes x 256
#                      lines, minus <= 8 already cached in the first pass);
#                      8: 128 (the first pass: case 7 ended on the upper 2 KB,
#                      which shares every index with the lower 2 KB)
#   dc_ld_hit  >= 2432: 7: 2 x 768 (words 1-3 of every line hit after word 0);
#                      8: 384 (first pass) + 512 (second pass)
#   dc_st_hit  >= 6:   3: 2; 4: 4
#   dc_st_miss >= 960: 7: 1024 stores, of which at most 32 (8 cached lines)
#                      can hit
#   dc_unc     >= 1:   9
# CACHE-EXPECT: dc_ld_miss>=641 dc_ld_hit>=2432 dc_st_hit>=6 dc_st_miss>=960 dc_unc>=1
# With random latency, in every run (seeded, so reproducible; each write needs
# at least 2 cycles and most need more, against one store every 2 cycles):
#   dc_wb_full >= 1: 10
# CACHE-EXPECT(random): dc_wb_full>=1
#
# Stock environment + sw/common/irq_handler.h, interrupts enabled. Registers
# t5/t6 and s5-s11 belong to the trap handler.
# =============================================================================
#include "riscv_test.h"
#include "test_macros.h"
#include "irq_handler.h"

#define WAY_STRIDE 2048                  /* cache size: same index, other tag */

RVTEST_RV32M
RVTEST_CODE_BEGIN

  DIRECTED_TRAP_INSTALL(trap_handler)
  IRQ_ENABLE_ALL
  la   s0, buf

  # --- 2: store miss, then a load of the same word ----------------------------
  TEST_CASE( 2, a1, 0x12345678, li a0, 0x12345678; sw a0, 0(s0); lw a1, 0(s0) )

  # --- 3: refill, then sub-word store hits merged into the line ---------------
  li   a0, 0x11223344
  sw   a0, 16(s0)                        # miss, no allocate
  lw   a1, 16(s0)                        # miss: refills line 1
  li   a2, 0x55
  sb   a2, 17(s0)                        # hit, lane 1
  li   a2, 0x6677
  sh   a2, 18(s0)                        # hit, lanes 2-3
  TEST_CASE( 3, a1, 0x66775544, lw a1, 16(s0) )
  TEST_CASE(30, a1, 0x55,       lbu a1, 17(s0) )
  TEST_CASE(31, a1, 0x6677,     lh a1, 18(s0) )

  # --- 4: sb to every lane of a cached word -----------------------------------
  li   a2, 0xa1
  sb   a2, 16(s0)
  li   a2, 0xb2
  sb   a2, 17(s0)
  li   a2, 0xc3
  sb   a2, 18(s0)
  li   a2, 0xd4
  sb   a2, 19(s0)
  TEST_CASE( 4, a1, 0xd4c3b2a1, lw a1, 16(s0) )

  # --- 5: conflict at a 2 KB stride -------------------------------------------
  addi s1, s0, 32                        # A: line 2
  li   t0, WAY_STRIDE
  add  s2, s1, t0                        # B: same index, other tag
  li   a0, 0x0a0a0a0a
  sw   a0, 0(s1)                         # A (miss, no allocate)
  lw   a1, 0(s1)                         # A refilled
  li   a0, 0x0b0b0b0b
  sw   a0, 0(s2)                         # B: miss, A stays cached
  TEST_CASE( 5, a1, 0x0a0a0a0a, lw a1, 0(s1) )
  TEST_CASE(50, a1, 0x0b0b0b0b, lw a1, 0(s2) )   # evicts A
  TEST_CASE(51, a1, 0x0a0a0a0a, lw a1, 0(s1) )   # A misses again

  # --- 6: four back-to-back stores to four lines ------------------------------
  li   a0, 0x61
  li   a1, 0x62
  li   a2, 0x63
  li   a3, 0x64
  sw   a0, 64(s0)
  sw   a1, 80(s0)
  sw   a2, 96(s0)
  sw   a3, 112(s0)
  TEST_CASE( 6, a4, 0x61, lw a4, 64(s0) )
  TEST_CASE(60, a4, 0x62, lw a4, 80(s0) )
  TEST_CASE(61, a4, 0x63, lw a4, 96(s0) )
  TEST_CASE(62, a4, 0x64, lw a4, 112(s0) )

  # --- 7: 4 KB sweep, written once, read back twice ---------------------------
  li   TESTNUM, 7
  li   s3, 0                             # checksum of the values written
  li   t0, 0                             # word index
  mv   t1, s0
  li   t2, 1024
1:slli a0, t0, 16                        # value = i ^ (i << 16) ^ 0xa5a50000
  xor  a0, a0, t0
  li   a1, 0xa5a50000
  xor  a0, a0, a1
  sw   a0, 0(t1)
  add  s3, s3, a0
  addi t1, t1, 4
  addi t0, t0, 1
  bne  t0, t2, 1b
  li   s4, 2                             # two read passes
2:li   a2, 0
  mv   t1, s0
  li   t0, 1024
3:lw   a0, 0(t1)
  add  a2, a2, a0
  addi t1, t1, 4
  addi t0, t0, -1
  bnez t0, 3b
  bne  a2, s3, fail
  addi s4, s4, -1
  bnez s4, 2b

  # --- 8: 2 KB read twice: the second pass hits -----------------------------------
  li   TESTNUM, 8
  li   s4, 2
2:li   a2, 0
  mv   t1, s0
  li   t0, 512
3:lw   a0, 0(t1)
  add  a2, a2, a0
  addi t1, t1, 4
  addi t0, t0, -1
  bnez t0, 3b
  addi s4, s4, -1
  bnez s4, 2b
  # checksum of words 0..511 as written in case 7
  li   a3, 0
  li   t0, 0
  li   t2, 512
4:slli a0, t0, 16
  xor  a0, a0, t0
  li   a1, 0xa5a50000
  xor  a0, a0, a1
  add  a3, a3, a0
  addi t0, t0, 1
  bne  t0, t2, 4b
  bne  a2, a3, fail

  # --- 9: uncached access after buffered stores: precise fault ----------------
  li   TESTNUM, 9
  li   a0, 0x99
  li   a7, 0x70000000                    # unmapped
  la   s11, 2f
  sw   a0, 0(s0)                         # buffered
1:lw   a1, 0(a7)                         # waits for the buffer, then faults
  j    fail
2:bnez s11, fail
  li   t0, CAUSE_LOAD_ACCESS; bne s8, t0, fail
  la   t0, 1b; bne s9, t0, fail
  bne  s10, a7, fail
  TEST_CASE(90, a1, 0x99, lw a1, 0(s0) )

  # --- 10: warm burst of 8 stores, 4 times ------------------------------------------
  li   TESTNUM, 10
  li   s4, 4
  li   a0, 0x100
1:sw   a0, 128(s0)
  sw   a0, 132(s0)
  sw   a0, 136(s0)
  sw   a0, 140(s0)
  sw   a0, 144(s0)
  sw   a0, 148(s0)
  sw   a0, 152(s0)
  sw   a0, 156(s0)
  addi a0, a0, 1
  addi s4, s4, -1
  bnez s4, 1b
  TEST_CASE(100, a1, 0x103, lw a1, 128(s0) )
  TEST_CASE(101, a1, 0x103, lw a1, 156(s0) )

  TEST_PASSFAIL

  .align 2
trap_handler:
  DIRECTED_TRAP_HANDLER

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA
  IRQ_DATA

  .balign 2048
buf:
  .skip 4096

RVTEST_DATA_END
