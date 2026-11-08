# SPDX-License-Identifier: ISC
# bigsoc firmware (RV32IM, bare metal, one image for every core).
# 8 epochs of epoch_iters work iterations; each iteration fills a buffer with an LCG, runs it
# through the CRC accelerator, multiplies two 4x4 matrices, sorts 16 words, divides, and pushes
# 16 entries into the core's ring in cluster shared RAM (reading each back into a checksum).
# At the end of an epoch the core reports STATUS / PERF_CNT / CRC_RES / checksum to its
# TRACE_OUT register and to its SoC mailbox word.
#
# Known bugs (the benchmark's x sources, see ../README.md):
#  - tile 1 skips CRC_INIT in epoch 0 (the CRC state has no reset)
#  - tile 2 sums a calibration table at 0x3400 in epoch 2 that nothing ever writes
#  - the ring index wraps at 1024 entries, not 512 (tile 3 then runs past the shared RAM)
#  - core 0x12 dispatches through a handler table at 0x3800 in epoch 7 that nothing writes

        .equ MMIO,      0x10000000
        .equ R_ID,      0x00
        .equ R_ITERS,   0x04
        .equ R_TRACE,   0x08
        .equ R_CRCDATA, 0x0c
        .equ R_CRCINIT, 0x10
        .equ R_CRCRES,  0x14
        .equ R_PERFCTL, 0x18
        .equ R_PERFCNT, 0x1c
        .equ R_DONE,    0x20
        .equ R_STATUS,  0x24
        .equ R_CYCLE,   0x28
        .equ SHARED,    0x20000000
        .equ MAILBOX,   0x30000000
        .equ BUF,       0x2000
        .equ MATC,      0x2100
        .equ CALIB,     0x3400
        .equ HANDLERS,  0x3800
        .equ EPOCHS,    8

        .section .text
        .globl _start
_start:
        li   sp, 0x3000
        li   s0, MMIO
        lw   s1, R_ID(s0)          # id = cluster*16 + tile
        lw   s2, R_ITERS(s0)
        andi s3, s1, 15            # tile in cluster
        srli s4, s1, 4             # cluster
        li   s5, SHARED
        slli t0, s3, 11            # 512 words per tile
        add  s6, s5, t0            # this core's ring
        li   s7, 0
        li   s8, 0
        li   s10, 0
        la   t0, seed
        lw   s9, 0(t0)
        add  s9, s9, s1

epoch_loop:
        # CRC_INIT, except tile 1 in epoch 0
        li   t0, 1
        bne  s3, t0, 1f
        beqz s8, 2f
1:      li   t1, -1
        sw   t1, R_CRCINIT(s0)
2:
        # tile 0 turns its perf counter on in epoch 1
        bnez s3, 3f
        li   t0, 1
        bne  s8, t0, 3f
        sw   t0, R_PERFCTL(s0)
3:
        # tile 2: calibration offset in epoch 2
        li   t0, 2
        bne  s3, t0, 4f
        bne  s8, t0, 4f
        li   a0, CALIB
        li   a1, 64
        call sum_words
        add  s10, s10, a0
4:
        # core 0x12, epoch 7: run the epoch handler from the handler table
        li   t0, 0x12
        bne  s1, t0, 5f
        li   t0, EPOCHS-1
        bne  s8, t0, 5f
        li   t1, HANDLERS
        lw   t2, 0(t1)
        jalr ra, 0(t2)
5:
        mv   s11, s2
iter_loop:
        call work
        addi s11, s11, -1
        bnez s11, iter_loop

        # epoch report
        lw   t0, R_STATUS(s0)
        lw   t1, R_PERFCNT(s0)
        lw   t2, R_CRCRES(s0)
        lw   t3, R_CYCLE(s0)
        sw   t3, R_TRACE(s0)
        sw   t0, R_TRACE(s0)
        sw   t1, R_TRACE(s0)
        sw   t2, R_TRACE(s0)
        sw   s10, R_TRACE(s0)
        slli t3, s4, 2             # mailbox word = cluster*4 + tile
        add  t3, t3, s3
        slli t3, t3, 2
        li   t4, MAILBOX
        add  t4, t4, t3
        xor  t5, s10, t2
        add  t5, t5, t1
        sw   t5, 0(t4)
        lw   t6, 0(t4)             # read back
        li   s10, 0
        addi s8, s8, 1
        li   t0, EPOCHS
        blt  s8, t0, epoch_loop

        li   t0, 1
        sw   t0, R_DONE(s0)
halt:   j    halt

# a0 = sum of a1 words at a0
sum_words:
        li   t0, 0
1:      lw   t1, 0(a0)
        add  t0, t0, t1
        addi a0, a0, 4
        addi a1, a1, -1
        bnez a1, 1b
        mv   a0, t0
        ret

# One work iteration. Uses t*, a*; s9 = LCG state, s10 = checksum, s7 = ring index.
work:
        addi sp, sp, -16
        sw   ra, 12(sp)
        sw   s11, 8(sp)

        # 1. fill BUF[0..63] with the LCG
        li   a0, BUF
        li   a1, 64
        li   a2, 1103515245
        li   a3, 12345
1:      mul  s9, s9, a2
        add  s9, s9, a3
        sw   s9, 0(a0)
        addi a0, a0, 4
        addi a1, a1, -1
        bnez a1, 1b

        # 2. CRC of BUF[0..15] through the accelerator
        li   a0, BUF
        li   a1, 16
1:      lw   t0, 0(a0)
        sw   t0, R_CRCDATA(s0)
        addi a0, a0, 4
        addi a1, a1, -1
        bnez a1, 1b

        # 3. C = A * B, A = BUF[0..15], B = BUF[16..31] (4x4, row major), C at MATC
        li   a4, 0                 # i
2:      li   a5, 0                 # j
3:      li   a6, 0                 # k
        li   a7, 0                 # sum
4:      slli t0, a4, 2
        add  t0, t0, a6
        slli t0, t0, 2
        li   t1, BUF
        add  t0, t0, t1
        lw   t2, 0(t0)             # A[i][k]
        slli t0, a6, 2
        add  t0, t0, a5
        slli t0, t0, 2
        addi t0, t0, 64
        add  t0, t0, t1
        lw   t3, 0(t0)             # B[k][j]
        mul  t4, t2, t3
        add  a7, a7, t4
        addi a6, a6, 1
        li   t5, 4
        blt  a6, t5, 4b
        slli t0, a4, 2
        add  t0, t0, a5
        slli t0, t0, 2
        li   t1, MATC
        add  t0, t0, t1
        sw   a7, 0(t0)
        addi a5, a5, 1
        blt  a5, t5, 3b
        addi a4, a4, 1
        blt  a4, t5, 2b

        # 4. insertion sort of BUF[32..47] (unsigned)
        li   a0, BUF+128
        li   a1, 1                 # i
5:      slli t0, a1, 2
        add  t0, t0, a0
        lw   t1, 0(t0)             # key
        addi t2, a1, -1            # j
6:      bltz t2, 7f
        slli t3, t2, 2
        add  t3, t3, a0
        lw   t4, 0(t3)
        bgeu t1, t4, 7f
        sw   t4, 4(t3)
        addi t2, t2, -1
        j    6b
7:      addi t3, t2, 1
        slli t3, t3, 2
        add  t3, t3, a0
        sw   t1, 0(t3)
        addi a1, a1, 1
        li   t5, 16
        blt  a1, t5, 5b

        # 5. divide: checksum += BUF[48] / 97 + BUF[49] % 251
        li   a0, BUF+192
        lw   t0, 0(a0)
        lw   t1, 4(a0)
        li   t2, 97
        divu t3, t0, t2
        li   t2, 251
        remu t4, t1, t2
        add  s10, s10, t3
        add  s10, s10, t4

        # 6. ring: push 16 entries (C ^ index), read each back
        li   a0, MATC
        li   a1, 16
8:      lw   t0, 0(a0)
        xor  t0, t0, s7
        andi t1, s7, 1023          # ring has 512 entries
        slli t1, t1, 2
        add  t1, t1, s6
        sw   t0, 0(t1)
        lw   t2, 0(t1)
        add  s10, s10, t2
        addi s7, s7, 1
        addi a0, a0, 4
        addi a1, a1, -1
        bnez a1, 8b

        # 7. checksum of C
        li   a0, MATC
        li   a1, 16
1:      lw   t0, 0(a0)
        add  s10, s10, t0
        addi a0, a0, 4
        addi a1, a1, -1
        bnez a1, 1b

        lw   s11, 8(sp)
        lw   ra, 12(sp)
        addi sp, sp, 16
        ret

        .section .rodata
        .align 2
seed:   .word 0x2545F491
