```asm
; ============================================================
; Pinterest Painful Automatizer™
; x86-64 Linux / NASM
;
; Because apparently shell scripting wasn't painful enough.
;
; Build:
;   nasm -felf64 painful.asm -o painful.o
;   ld painful.o -o painful
;
; Run:
;   ./painful
;
; Requirements:
;   - Linux x86-64
;   - NASM
;   - ./run.sh in the same directory
;
; This program repeatedly executes:
;
;   ./run.sh --max-images 5 --max-scrolls 2 --max-runtime 1
;
; and then sleeps for 30 seconds.
; ============================================================

BITS 64

global _start

section .data

    ; Executable
    run_path:
        db "./run.sh", 0

    ; argv for execve()
    arg0:
        dq run_path

    arg1:
        db "--max-images", 0
    arg1_ptr:
        dq arg1

    arg2:
        db "5", 0
    arg2_ptr:
        dq arg2

    arg3:
        db "--max-scrolls", 0
    arg3_ptr:
        dq arg3

    arg4:
        db "2", 0
    arg4_ptr:
        dq arg4

    arg5:
        db "--max-runtime", 0
    arg5_ptr:
        dq arg5

    arg6:
        db "1", 0
    arg6_ptr:
        dq arg6

    argv:
        dq run_path
        dq arg1
        dq arg2
        dq arg3
        dq arg4
        dq arg5
        dq arg6
        dq 0

    ; Environment pointer.
    ; NULL means execve inherits no environment.
    envp:
        dq 0

    ; nanosleep() structure:
    ;
    ; struct timespec {
    ;     time_t tv_sec;
    ;     long   tv_nsec;
    ; };
    ;
    ; 30 seconds.
    sleep_time:
        dq 30
        dq 0

    newline:
        db 10

    banner:
        db "==================================================", 10
        db "     PINTEREST PAINFUL AUTOMATIZER(TM)", 10
        db "==================================================", 10
        db "x86-64 Assembly was chosen voluntarily.", 10
        db "This was a terrible decision.", 10, 10
        db 0

    round_msg:
        db "[ROUND] Launching the collector...", 10
        db 0

section .text

_start:

    ; --------------------------------------------------------
    ; Print the extremely important banner.
    ; --------------------------------------------------------

    lea rsi, [rel banner]
    call print_string

    ; --------------------------------------------------------
    ; Start the eternal suffering.
    ; --------------------------------------------------------

main_loop:

    lea rsi, [rel round_msg]
    call print_string

    ; --------------------------------------------------------
    ; fork()
    ;
    ; syscall:
    ;   RAX = 57
    ;
    ; Parent gets child's PID.
    ; Child gets 0.
    ; --------------------------------------------------------

    mov eax, 57
    syscall

    test rax, rax
    jz child_process

    ; --------------------------------------------------------
    ; Parent process.
    ;
    ; Wait for child to finish.
    ;
    ; wait4(
    ;     pid,
    ;     status,
    ;     options,
    ;     rusage
    ; )
    ;
    ; RAX = 61
    ; --------------------------------------------------------

    mov rdi, rax
    lea rsi, [rel exit_status]
    xor rdx, rdx
    xor r10, r10

    mov eax, 61
    syscall

    ; --------------------------------------------------------
    ; Now we wait 30 seconds because efficiency is forbidden.
    ; --------------------------------------------------------

    call painful_sleep

    jmp main_loop


child_process:

    ; --------------------------------------------------------
    ; execve("./run.sh", argv, envp)
    ;
    ; syscall:
    ;   RAX = 59
    ; --------------------------------------------------------

    lea rdi, [rel run_path]
    lea rsi, [rel argv]
    lea rdx, [rel envp]

    mov eax, 59
    syscall

    ; --------------------------------------------------------
    ; If execve() returned, something went wrong.
    ; Exit with status 127.
    ; --------------------------------------------------------

    mov edi, 127
    mov eax, 60
    syscall


; ============================================================
; print_string
;
; Input:
;   RSI = zero-terminated string
;
; Uses:
;   write(stdout, string, length)
; ============================================================

print_string:

    push rsi
    mov rdi, rsi

.find_end:
    cmp byte [rdi], 0
    je .found_end

    inc rdi
    jmp .find_end

.found_end:

    sub rdi, rsi

    ; length -> RDX
    mov rdx, rdi

    ; buffer -> RSI
    ; already there

    ; stdout
    mov edi, 1

    ; write syscall
    mov eax, 1
    syscall

    pop rsi
    ret


; ============================================================
; painful_sleep
;
; nanosleep(30 seconds)
; ============================================================

painful_sleep:

    lea rdi, [rel sleep_time]

    ; NULL remainder pointer
    xor rsi, rsi

    ; nanosleep syscall
    mov eax, 35
    syscall

    ret


section .bss

    ; wait4() exit status
    exit_status:
        resd 1
```
