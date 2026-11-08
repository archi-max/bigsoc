/* SPDX-License-Identifier: ISC */
ENTRY(_start)
SECTIONS {
  . = 0x0;
  .text : { *(.text*) }
  .rodata : { *(.rodata*) *(.srodata*) }
  .data : { *(.data*) *(.sdata*) }
  _end = .;
  ASSERT(_end <= 0x2000, "firmware overlaps the work buffers")
}
