; int_test: the position of INT against the raster, the same code for unreal-ng (int_test.sna, PENTAGON) and
; for tb_p4096 (int_test.rom as ROM page 2, the page of the reset: it copies the payload to #6000).
; After each INT (IM 2, HALT) it waits a fixed time and writes the border 80 times in a row, red / cyan every
; 12 T: the stripes in the top border show where the frame is at a given T after INT; the white paper is the
; reference of the picture.
; sjasmplus -DROM int_test.asm  -> int_test.rom;   sjasmplus int_test.asm -> int_test.sna

	DEVICE ZXSPECTRUM128

	IFDEF ROM
	ORG 0
	di
	ld hl,payload
	ld de,#6000
	ld bc,#400		; a fixed length: the time of the copy must not depend on PAD
	ldir
	jp #6000
payload:
	DISP #6000
	ELSE
	ORG #6000
	ENDIF

start:
	di
	ld sp,#6000
	ld hl,#7E00		; IM 2 table: vector #7F7F
	ld de,#7E01
	ld bc,256
	ld (hl),#7F
	ldir
	ld a,#C9		; the handler: RET (IFF stays 0)
	ld (#7F7F),a
	ld hl,#4000		; screen: pixels 0, attributes white paper
	ld de,#4001
	ld bc,#1800
	ld (hl),0
	ldir
	ld bc,#2FF
	ld (hl),#38
	ldir
	ld a,#7E
	ld i,a
	im 2
	xor a
	out (#FE),a
	; PAD 0..3: 8 / 9 / 6 / 7 T before the first HALT, so that the 4 builds start their HALT in the 4 phases
	; of the 4 T of its M1 (INT is taken only at the end of one: one build alone measures INT to 4 T)
	IFNDEF PAD
	DEFINE PAD 0
	ENDIF
	IF PAD == 0
	nop
	nop
	ENDIF
	IF PAD == 1
	ld a,i
	ENDIF
	IF PAD == 2
	inc hl
	ENDIF
	IF PAD == 3
	ld a,(hl)
	ENDIF
loop:
	ei
	halt
	; INT taken, back here: wait about 16 lines (the frame pulse) + 24
	ld b,0
.d1:	djnz .d1		; 256 * 13 - 5 = 3323 T
	ld b,170
.d2:	djnz .d2		; 170 * 13 - 5 = 2205 T
	ld b,154
.d3:	djnz .d3		; 154 * 13 - 5 = 1997 T
	ld bc,#00FE
	ld d,2
	ld e,5
	REPT 80
	out (c),d
	out (c),e
	ENDR
	xor a
	out (#FE),a
	jp loop

	IFDEF ROM
	ENT
payload_end:
	SAVEBIN "int_test.rom",0,#4000
	ELSE
	SAVESNA "int_test.sna",start
	ENDIF
