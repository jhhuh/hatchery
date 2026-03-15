; return42.asm — minimal test: return 42
; Called as: int fn(void) — standard C calling convention
; Return value in eax
BITS 64
    mov eax, 42
    ret
