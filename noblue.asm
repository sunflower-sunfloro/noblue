; noblue takes the blue out of your screen, on Linux with X (the window
; system).
;
; How: every screen has a color table. It is the graphics card's last
; step before the picture goes to the screen. noblue sets each table so
; red and green display as they are, and blue is always 0. White then
; shows as yellow, and blue as black, whatever a program draws.
;
; noblue does this in two steps.
;
; Step 1: it asks X to set the tables. X is the program in charge of the
; graphics card.
;
; Step 2: it checks. X sometimes says "done" when nothing was done (seen
; in QEMU, a pretend computer). So noblue does not take X's word. It
; asks Linux what is really in each table. Linux runs the card, so Linux
; knows.
;
; To pass the check, every screen that is on must have a table, and the
; table's blue must be 0 from top to bottom.
;
; (Linux keeps two kinds of table: a newer kind, named GAMMA_LUT, and an
; older kind. noblue reads the newer kind if the card has it. If not, it
; reads the older kind.)
;
; noblue says what it found. It answers 0 if every screen passed, else 1.
;
; Three ways to run it:
;   noblue          set the tables once, and check them
;   noblue watch    keep going: set and check again each second, and
;                   whenever X says a screen changed. Says what it found
;                   each time that changes. Ends, answering 1, when X
;                   ends or its answers stop making sense.
;   noblue off      put blue back: every table plain again. A
;                   calibration loaded before noblue is not brought
;                   back. Not checked. Answers 0 once X took it.
;
; X lets a program in only if it shows X's key. noblue takes the key
; from the file that the setting XAUTHORITY names. If there is no such
; setting, it takes the key from .Xauthority in your home folder.
;
; noblue uses no libraries (other people's ready-made code). It talks to
; Linux and to X directly. So this one file runs on any 64-bit PC Linux
; with X.
;
; For the tests only, two settings point noblue at stand-ins:
;   NOBLUE_SOCKET   a stand-in for X's socket (the door X listens at)
;   NOBLUE_DRI      a stand-in for /dev/dri, Linux's folder of cards
;
; To build it (INCLUDE must name fasmg's x86 package):
;   fasmg noblue.asm noblue
;   chmod +x noblue
;
; For programmers: each routine may change RAX, RCX, RDX, RSI, RDI and
; R8 to R11. It keeps the other registers, unless it says so. (Linux's
; own calls change RCX and R11.)
;
; Copyright (C) 2026 the noblue project. GPL version 3 only (LICENSE).
; No warranty.
include 'format/format.inc'
format ELF64 executable 3
entry start


; ---- Names for numbers. Each line gives a number a name, so the code
; below can say the name.

; How much noblue has room for. (A "screen driver" is the part of a card
; that feeds one screen. Linux and X call it a CRTC.)
CRTCS_MOST     = 256                    ; screen drivers on one card, or on one X screen
PROPS_MOST     = 256                    ; settings of one screen driver (Linux allows fewer)
LUT_MOST       = 4096                   ; entries in one color table; a bigger table fails the check
IN_ROOM        = 1 shl 18 + 8           ; bytes of room for one answer from X (262,152): any welcome fits
assert IN_ROOM >= 8 + 4 * 65535         ; a welcome is 8 bytes, and up to 65,535 times 4 more
OUT_ROOM       = 12 + 20 + 65536        ; bytes of room for what we send X. The longest is a hello: its own 12,
                                        ; the key's kind's name (18, filled out to 20), and the longest key the
                                        ; key file's layout can hold (65,535, filled out to 65,536)
assert OUT_ROOM >= 12 + 6 * LUT_MOST + 4 ; a whole color table fits too: 12 bytes, and 6 an entry
AUTH_ROOM      = 1 shl 20               ; bytes of the key file we read (1,048,576)
DENTS_ROOM     = 4096                   ; bytes of a folder's list of names, read a part at a time

; Linux's numbers for its calls, on a 64-bit PC.
SYS_READ       = 0
SYS_WRITE      = 1
SYS_OPEN       = 2
SYS_CLOSE      = 3
SYS_POLL       = 7                      ; wait for something to read
SYS_SIGACTION  = 13                     ; say what a signal should do (Linux's name: rt_sigaction)
SYS_IOCTL      = 16                     ; ask a device a question
SYS_SOCKET     = 41
SYS_CONNECT    = 42
SYS_EXIT       = 60
SYS_UNAME      = 63                     ; this computer's name
SYS_GETDENTS   = 217                    ; a folder's list of names (Linux's name: getdents64)

; Linux's numbers that go with those calls.
O_RDONLY       = 0                      ; open for reading only
O_DIRECTORY    = 10000h                 ; open only if it is a folder
ENOENT         = 2                      ; the error "no such file"
SIGPIPE        = 13                     ; the signal for writing to something that has gone
AF_UNIX        = 1                      ; a socket on this computer, not the network
SOCK_STREAM    = 1                      ; a socket that carries bytes in order
POLLIN         = 1                      ; "there is something to read"

; Linux's numbers for questions to a graphics card (its DRM_IOCTL_MODE names).
GETRESOURCES   = 0C04064A0h             ; list the card's screen drivers (GETRESOURCES)
GETCRTC        = 0C06864A1h             ; what is one screen driver showing? (GETCRTC)
GETGAMMA       = 0C02064A4h             ; read an older color table (GETGAMMA)
GETPROPERTIES  = 0C02064B9h             ; list a screen driver's settings (OBJ_GETPROPERTIES)
GETPROPERTY    = 0C04064AAh             ; a setting's name (GETPROPERTY)
GETPROPBLOB    = 0C01064ACh             ; a setting's block of data: here, a newer color table (GETPROPBLOB)
OBJECT_CRTC    = 0CCCCCCCCh             ; "this number names a screen driver" (DRM_MODE_OBJECT_CRTC)

; The key file's numbers.
FAMILY_LOCAL   = 256                    ; a key for one computer, named beside it
FAMILY_WILD    = 65535                  ; a key for any computer

; X's numbers for requests.
X_INPUT_FOCUS  = 43                     ; a harmless question (GetInputFocus): its answer means X has done all we sent before
X_EXTENSION    = 98                     ; "do you have this add-on?" (QueryExtension)

; RandR is X's add-on for screens. Its requests:
RR_VERSION     = 0                      ; which version do you speak?
RR_SELECT      = 4                      ; tell me when screens change
RR_GAMMA_SIZE  = 22                     ; how big is this color table?
RR_SET_GAMMA   = 24                     ; set this color table
RR_RESOURCES   = 25                     ; list the screen drivers (GetScreenResourcesCurrent)
RR_CHANGES     = 1 or 2 or 4            ; the changes to tell of: screens, screen drivers and outputs

; From here: the program's instructions. They can be read and run, but
; never changed.
segment readable executable

; ---- The start, and the main path

start:
    ; Tell Linux to ignore the signal SIGPIPE. Linux sends it when we
    ; write to something that has gone (X, or whoever reads our words),
    ; and it would end noblue without a word. Ignored, the write just
    ; fails, and noblue can say why and answer 1 (seen in the test).
    mov eax, SYS_SIGACTION
    mov edi, SIGPIPE
    lea rsi, [ignored]
    xor edx, edx
    mov r10d, 8
    syscall

    ; Linux leaves these for us, in order: how many words were typed,
    ; then the words, then a 0, then the settings (like DISPLAY).
    mov rcx, [rsp]                      ; how many words, "noblue" itself counted
    lea rax, [rsp+rcx*8+16]             ; where the settings begin
    mov [env], rax
    cmp rcx, 2
    jb .once                            ; just "noblue"
    ja usage                            ; too many words
    mov rsi, [rsp+16]                   ; the second word: is it "off"?
    lea rdi, [off_word]
    call same_z
    je .off
    mov rsi, [rsp+16]                   ; or "watch"?
    lea rdi, [watch_word]
    call same_z
    jne usage                           ; neither: say how to use it
    mov [watching], 1
    jmp .once
.off:
    mov [blue_back], 1

.once:
    call x_open                         ; reach X
    jc failed
    cmp [watching], 0
    jne .watching
    call x_set                          ; set every table (for "off": with blue back)
    jc failed
    cmp [blue_back], 0
    jne .back
    call look                           ; ask Linux what the tables hold
    call say                            ; say it
    jc stop                             ; the check failed: answer 1
    jmp fine                            ; it passed: answer 0

; noblue watch: the same, again and again, until X ends.
.watching:
    call x_watch                        ; ask X to tell us of screen changes
    jc failed
.set:
    call x_set
    jc .trouble
    call look
    mov [quiet], 1                      ; a card that cannot be read is named the first time only
    call found
    call tell                           ; say what was found, if it is news
.wait:
    call x_wait                         ; wait for news from X, one second at most
    jnc .set

; Something went wrong. RSI points at the words that say what. If X has
; gone, or its answers stopped making sense, that is the end. Anything
; else is said, and we try again after the wait: a failed check is just
; when the tables most need setting.
.trouble:
    lea rax, [no_x_words]
    cmp rsi, rax
    je failed
    lea rax, [unsound_words]
    cmp rsi, rax
    je failed
    call tell
    jmp .wait

.back:                                  ; "noblue off" is done: say so, answer 0
    lea rsi, [back_words]
    call put_out
    jmp fine

usage:                                  ; say how to use it, answer 1
    lea rsi, [usage_words]
failed:                                 ; say why (the words at RSI), answer 1
    call put_out
stop:                                   ; answer 1
    mov edi, 1
    jmp quit
fine:                                   ; answer 0
    xor edi, edi
quit:
    mov eax, SYS_EXIT
    syscall

; ---- Talking to X, over its socket

; A word used all through: CF, the carry flag, is the chip's yes-or-no
; mark. A routine here sets CF to say "trouble", and clears it to say
; "fine". With trouble, RSI points at the words that say why.

; x_open: reach X, and get ready to ask it things.
; It finds X's socket from DISPLAY, connects, shows the key, and reads
; X's welcome. From the welcome it learns each screen's root window: the
; window behind all the others, which stands for the screen. These are
; kept in roots, and their count in root_count. Every screen X has is
; taken, whichever one DISPLAY names. Last, it asks X for RandR's
; number, kept in randr. Sets CF, with why at RSI, if any of this fails.
x_open:
    push rbx rbp

    ; DISPLAY must look like :0 or :0.1, a display on this computer.
    ; The figures of its number are copied into display_number.
    lea rsi, [display_setting]
    call setting
    lea rsi, [no_display_words]
    jc .done                            ; no DISPLAY at all
    cmp byte [rax], ':'
    stc
    jne .done                           ; another computer's display: not ours to set
    lea r8, [rax+1]
    lea rdi, [display_number]
    xor ecx, ecx
.digit:
    mov al, [r8+rcx]
    cmp al, '0'
    jb .digits
    cmp al, '9'
    ja .digits
    cmp ecx, 8
    jae .no                             ; a ninth figure: too many
    mov [rdi+rcx], al
    inc ecx
    jmp .digit
.digits:                                ; AL: what comes after the figures
    mov [display_len], ecx
    test ecx, ecx
    jz .no                              ; no figures
    test al, al
    jz .display                         ; the end: fine
    cmp al, '.'                         ; or a dot and a screen's number, figures only.
    jne .no                             ; (All screens are set, so the number is not used.)
    lea r8, [r8+rcx+1]
.after_dot:
    mov al, [r8]
    inc r8
    test al, al
    jz .display
    cmp al, '0'
    jb .no
    cmp al, '9'
    ja .no
    jmp .after_dot
.display:

    ; The socket's name goes into address. It is NOBLUE_SOCKET's, if
    ; that is set (the tests). If not, it is X's own: /tmp/.X11-unix/X
    ; and the display's number.
    lea rsi, [socket_setting]
    call setting
    lea rdi, [address+2]
    jc .own
    mov rsi, rax
    mov ecx, 108                        ; the room Linux gives a socket's name, its ending 0 too
    call put_within
    lea rsi, [too_long_words]
    jc .no
    jmp .named
.own:
    lea rsi, [socket_folder]
    call put_z
    lea rsi, [display_number]
    call put_z
.named:

    ; Make a socket of our own, and connect it to X's.
    mov word [address], AF_UNIX
    mov eax, SYS_SOCKET
    mov edi, AF_UNIX
    mov esi, SOCK_STREAM
    xor edx, edx
    syscall
    test eax, eax
    js .no_x                            ; Linux would not make one
    mov [x], eax
    mov eax, SYS_CONNECT
    mov edi, [x]
    lea rsi, [address]
    mov edx, 110                        ; address's length: 2 bytes, and the name's 108
    syscall
    test eax, eax
    js .no_x                            ; nobody is listening there
    call x_key                          ; find X's key, if there is one

    ; Say hello to X. The hello is: the letter l (it means our numbers
    ; are written low byte first); X's version, 11.0; how long the key's
    ; kind's name is, and how long the key is; then the name and the key.
    lea rdi, [out_buf]
    mov eax, 'l'
    stosw
    mov eax, 11                         ; version 11
    stosw
    xor eax, eax                        ; .0
    stosw
    mov eax, [key_name_len]
    stosw
    mov eax, [key_len]
    stosw
    xor eax, eax                        ; 2 bytes not used
    stosw
    mov rsi, [key_name]
    mov ecx, [key_name_len]
    call put_padded
    mov rsi, [key]
    mov ecx, [key_len]
    call put_padded
    call x_send
    mov [sent], 0                       ; X counts our requests from 1, starting after the hello
    jc .no_x

    ; X's answer, the welcome, starts with 8 bytes. The first is 1 if we
    ; are let in. Bytes 6 and 7 say how much more follows, counted in 4s.
    lea rdi, [in_buf]
    mov ecx, 8
    call x_read
    jc .no_x
    cmp byte [in_buf], 1
    lea rsi, [refused_words]
    jne .no                             ; not let in
    movzx ecx, word [in_buf+6]          ; 65,535 at most, so the rest always fits in_buf
    shl ecx, 2
    mov [welcome_len], ecx
    lea rdi, [in_buf+8]
    call x_read                         ; the rest of the welcome
    jc .no_x

    ; The welcome is laid out like this. First, 40 bytes of fixed facts.
    ; Among them: how long the maker's name is (bytes 24 and 25), how
    ; many screens there are (byte 28), and how many picture formats
    ; (byte 29). Then the maker's name, filled out to a multiple of 4.
    ; Then the formats, 8 bytes each. Then the screens.
    lea rsi, [unsound_words]            ; the words for any trouble here
    cmp [welcome_len], 40 - 8           ; too short to hold the fixed facts
    jb .no                              ; (welcome_len leaves out the first 8 bytes)
    movzx ebx, byte [in_buf+28]         ; how many screens: 255 at most, so roots has room
    test ebx, ebx
    jz .no                              ; no screen at all
    mov [root_count], ebx
    movzx eax, word [in_buf+24]         ; the maker's name's length,
    add eax, 3                          ; rounded up to a multiple of 4
    and eax, not 3
    movzx edx, byte [in_buf+29]         ; how many formats
    lea eax, [eax+edx*8+40]             ; EAX: where the first screen starts, counted from in_buf
    mov edx, [welcome_len]
    add edx, 8                          ; EDX: where the welcome ends. Nothing past it is read.
    xor ebp, ebp                        ; EBP: which screen, from 0

    ; Each screen is 40 bytes. Its root window's number comes first, and
    ; its last byte says how many "depths" follow. Each depth is 8
    ; bytes, then 24 bytes for each kind of picture it lists (how many
    ; is in the depth's bytes 2 and 3). We want only the root window.
    ; The rest is stepped over, to reach the next screen.
.screen:
    lea ecx, [eax+40]
    cmp ecx, edx
    ja .no                              ; the screen would run past the end
    mov ecx, dword [in_buf+rax]
    mov [roots+rbp*4], ecx              ; its root window, kept
    movzx ecx, byte [in_buf+rax+39]     ; ECX: how many depths
    add eax, 40
.depth:
    test ecx, ecx
    jz .screened
    lea r8d, [eax+8]
    cmp r8d, edx
    ja .no                              ; the depth would run past the end
    movzx r8d, word [in_buf+rax+2]      ; how many kinds of picture
    lea r8d, [r8+r8*2]                  ; times 3,
    lea eax, [rax+r8*8+8]               ; times 8: 24 bytes each, and the depth's own 8
    dec ecx
    jmp .depth
.screened:
    inc ebp
    cmp ebp, ebx
    jb .screen

    ; Ask X: do you have the add-on named RANDR? The answer gives the
    ; number X knows it by. That number starts every RandR request.
    lea rdi, [out_buf]
    mov eax, X_EXTENSION or 4 shl 16    ; the request, and its length: 4 fours
    stosd
    mov eax, 5                          ; the name's length
    stosd
    mov eax, 'RAND'
    stosd
    mov eax, 'R'
    stosd
    call x_ask
    jc .done
    cmp byte [in_buf+8], 0
    lea rsi, [no_randr_words]
    je .no                              ; X has no RandR
    movzx eax, byte [in_buf+9]
    mov [randr], eax

    ; Tell RandR we speak its version 1.5, so X takes its newer
    ; requests from us.
    lea rdi, [out_buf]
    mov ah, RR_VERSION
    mov al, byte [randr]
    stosw
    mov eax, 3                          ; the request's length: 3 fours
    stosw
    mov eax, 1
    stosd
    mov eax, 5
    stosd
    call x_ask
    jmp .done

; The ways out of x_open.
.no_x:                                  ; X could not be reached
    lea rsi, [no_x_words]
.no:                                    ; trouble: RSI already says why
    stc
.done:
    pop rbp rbx
    ret

; x_key: find X's key for this display, in the key file (Xauthority).
; The file is a list of entries. Each entry says which computer it is
; for, which display number, what kind of key it holds, and the key.
; We take the first entry that fits all three of these:
;   - it is for this computer, by its name, or for any computer;
;   - it is for our display's number, or for any number;
;   - its key's kind is MIT-MAGIC-COOKIE-1.
; X's own library picks the same way. Entries for other computers, or
; for the network, are passed by.
; The result goes in key_name, key_name_len, key and key_len. With no
; file, or no entry that fits, both lengths stay 0: no key is shown.
x_key:
    push rbx rbp
    mov [key_name_len], 0
    mov [key_len], 0
    mov eax, SYS_UNAME                  ; ask Linux this computer's name: it lands at utsname+65
    lea rdi, [utsname]
    syscall
    xor ecx, ecx                        ; count the name's letters, up to its ending 0: 64 at most
.name:
    cmp byte [utsname+65+rcx], 0
    je .named
    inc ecx
    cmp ecx, 64
    jb .name
.named:
    mov [host_len], ecx

    ; Which file? The one XAUTHORITY names. If that is not set, it is
    ; HOME's folder with "/.Xauthority" added.
    lea rsi, [xauthority_setting]
    call setting
    mov rdi, rax
    jnc .file
    lea rsi, [home_setting]
    call setting
    jc .done                            ; no HOME either: no key
    mov rsi, rax
    lea rdi, [auth_path]
    mov ecx, 4096 - 13                  ; room left for "/.Xauthority" and its 0
    call put_within
    jc .done                            ; too long: no key, as with no file
    lea rsi, [xauthority_name]
    call put_z
    lea rdi, [auth_path]

    ; Open the file, read it into auth_buf in one go, and close it.
.file:
    mov eax, SYS_OPEN
    xor esi, esi                        ; for reading only
    xor edx, edx
    syscall
    test eax, eax
    js .done                            ; no such file: no key
    mov ebx, eax
    mov eax, SYS_READ
    mov edi, ebx
    lea rsi, [auth_buf]
    mov edx, AUTH_ROOM
    syscall
    mov rbp, rax
    mov eax, SYS_CLOSE
    mov edi, ebx
    syscall
    test rbp, rbp
    jle .done                           ; empty, or not readable: no key

    ; Go through the entries. RBX points at the entry being read, and
    ; RBP at the end of what was read. An entry is 2 bytes for its
    ; "family" (the kind of address it has), then four fields: the
    ; address, the display's number, the key's kind, and the key.
    ; Numbers in this file are written high byte first.
    lea rbx, [auth_buf]
    add rbp, rbx
.entry:
    lea rax, [rbx+2]
    cmp rax, rbp
    ja .done                            ; no room for another entry: the end
    movzx r11d, word [rbx]              ; the family,
    rol r11w, 8                         ; its two bytes swapped, to read it
    add rbx, 2
    call field                          ; the address: for our family, a computer's name
    jc .done
    cmp r11d, FAMILY_WILD
    je .computer                        ; for any computer: fine
    cmp r11d, FAMILY_LOCAL
    jne .skip                           ; for a network address: not ours
    cmp ecx, [host_len]
    jne .skip                           ; not exactly as long as this computer's name: not ours
    push rsi rcx
    lea rdi, [utsname+65]
    repe cmpsb                          ; and the same, letter for letter? (No letters: the same.)
    pop rcx rsi
    jne .skip
.computer:
    call field                          ; the display's number: kept in R8, its length in R9
    jc .done
    mov r8, rsi
    mov r9d, ecx
    call field                          ; the key's kind: kept in R10, its length in R11
    jc .done
    mov r10, rsi
    mov r11d, ecx
    call field                          ; the key itself: in RSI, its length in RCX
    jc .done
    cmp r11d, 18                        ; is the kind MIT-MAGIC-COOKIE-1? That is 18 letters,
    jne .entry
    push rsi rcx
    mov rsi, r10
    lea rdi, [cookie_words]
    mov ecx, 18
    repe cmpsb                          ; and these 18
    pop rcx rsi
    jne .entry
    test r9d, r9d
    jz .found                           ; no number in the entry: it is for any display
    cmp r9d, [display_len]              ; else the number must be ours: as long,
    jne .entry
    push rsi rcx
    mov rsi, r8
    lea rdi, [display_number]
    mov ecx, r9d
    repe cmpsb                          ; and the same figures
    pop rcx rsi
    jne .entry
.found:                                 ; this entry fits: remember where its key and kind are
    mov [key], rsi
    mov [key_len], ecx
    mov [key_name], r10
    mov [key_name_len], 18
.done:
    pop rbp rbx
    ret
.skip:                                  ; an entry for another computer: step over its other three fields
    call field
    jc .done
    call field
    jc .done
    call field
    jc .done
    jmp .entry

; field: read the key file's next field.
; A field is 2 bytes saying how long it is (high byte first), then that
; many bytes. RBX points at the field, and RBP at the end of the file.
; Gives back RSI pointing at the field's bytes, and ECX, how many they
; are. Moves RBX on to just after the field. Keeps R8 to R11.
; Sets CF if the field would run past the file's end.
field:
    lea rax, [rbx+2]
    cmp rax, rbp
    ja .short                           ; no room even for the length
    movzx ecx, word [rbx]               ; the length,
    xchg cl, ch                         ; its two bytes swapped, to read it
    lea rsi, [rbx+2]
    lea rbx, [rsi+rcx]
    cmp rbx, rbp
    ja .short                           ; its bytes would run past the end
    clc
    ret
.short:
    stc
    ret

; x_set: set every color table. This is the heart of noblue.
; For each of X's screens, it asks X for the list of screen drivers.
; For each screen driver, it asks how big its color table is, then
; sends a new table of that size: red and green "straight" (each level
; shows as itself), and blue all 0. For "noblue off", blue is straight
; too. Last, it asks X one harmless question. X answers in order, so
; that answer means every table before it was taken, or refused.
; Sets CF, with why at RSI, on any trouble.
x_set:
    push rbx rbp r12 r13
    xor r13d, r13d                      ; R13: which screen, from 0

    ; Ask X for this screen's list of screen drivers.
.screen:
    lea rdi, [out_buf]
    mov ah, RR_RESOURCES
    mov al, byte [randr]
    stosw
    mov eax, 2                          ; the request's length: 2 fours
    stosw
    mov eax, [roots+r13*4]              ; the screen's root window
    stosd
    call x_ask
    jc .done
    movzx ebx, word [in_buf+16]         ; EBX: how many screen drivers X says there are
    lea rsi, [too_many_words]
    cmp ebx, CRTCS_MOST
    ja .no                              ; more than we have room for
    lea rsi, [unsound_words]
    lea eax, [rbx*4]                    ; their numbers take 4 bytes each:
    mov edx, dword [in_buf+4]           ; did X really send that much?
    shl edx, 2
    cmp eax, edx
    ja .no                              ; no: the count lies
    lea rsi, [in_buf+32]                ; copy the numbers to crtc_ids. The next answer
    lea rdi, [crtc_ids]                 ; from X will overwrite in_buf.
    mov ecx, ebx
    rep movsd
    xor ebp, ebp                        ; EBP: which screen driver, from 0

    ; Ask X how big this screen driver's color table is.
.crtc:
    cmp ebp, ebx
    jae .screened                       ; all of this screen's are done
    lea rdi, [out_buf]
    mov ah, RR_GAMMA_SIZE
    mov al, byte [randr]
    stosw
    mov eax, 2                          ; the request's length: 2 fours
    stosw
    mov eax, [crtc_ids+rbp*4]
    stosd
    call x_ask
    jc .done
    movzx r12d, word [in_buf+8]         ; R12: how many entries the table has
    cmp r12d, 2
    jb .next                            ; it has no table. Nothing to set here; if it is
                                        ; showing a screen, Linux's check will fail it.
    lea rsi, [too_big_words]
    cmp r12d, LUT_MOST
    ja .no                              ; bigger than we have room for

    ; Build the request that sets the table: 12 bytes of heading, then
    ; all the red entries, all the green, all the blue, 2 bytes each.
    lea rdi, [out_buf]
    mov ah, RR_SET_GAMMA
    mov al, byte [randr]
    stosw
    lea eax, [r12+r12*2]                ; the request's length in fours: 3 colors,
    lea eax, [rax*2+12+3]               ; 2 bytes an entry, and the 12; rounded up
    shr eax, 2
    stosw
    mov eax, [crtc_ids+rbp*4]
    stosd
    mov eax, r12d
    stosd                               ; the table's size, and 2 bytes not used
    xor ecx, ecx
.red:                                   ; red: straight
    call straight
    stosw
    inc ecx
    cmp ecx, r12d
    jb .red
    xor ecx, ecx
.green:                                 ; green: straight
    call straight
    stosw
    inc ecx
    cmp ecx, r12d
    jb .green
    xor ecx, ecx
.blue:
    xor eax, eax                        ; blue: 0, every entry
    cmp [blue_back], 0
    je .blue_set
    call straight                       ; but for "noblue off": straight, like the others
.blue_set:
    stosw
    inc ecx
    cmp ecx, r12d
    jb .blue
    test r12d, 1
    jz .whole
    xor eax, eax                        ; an odd size leaves the request 2 bytes short
    stosw                               ; of a multiple of 4: two 0 bytes fill it out
.whole:
    call x_send                         ; sent. X gives no answer to this one unless it refuses.
    lea rsi, [no_x_words]
    jc .no
.next:
    inc ebp
    jmp .crtc
.screened:
    inc r13d
    cmp r13d, [root_count]
    jb .screen

    ; The harmless question. Its answer comes after X has dealt with
    ; every table above. A refusal of any of them comes first, and
    ; x_ask reports it.
    lea rdi, [out_buf]
    mov eax, X_INPUT_FOCUS or 1 shl 16
    stosd
    call x_ask
    jmp .done
.no:
    stc
.done:
    pop r13 r12 rbp rbx
    ret

; straight: work out one entry of a straight table.
; A straight table of R12 entries climbs evenly from 0, in its first
; entry, to 65535, the brightest, in its last. Gives back in AX the
; value for entry number ECX. Keeps every other register.
straight:
    push rdx r8
    mov eax, ecx
    imul eax, 65535
    lea r8d, [r12-1]
    xor edx, edx
    div r8d
    pop r8 rdx
    ret

; x_watch: ask X to tell us whenever a screen changes.
; RandR sends such news as "notices". We ask for them on every one of
; X's screens, then ask the harmless question, to learn that X took
; the requests. Sets CF, with why at RSI, if X did not.
x_watch:
    push rbx
    xor ebx, ebx                        ; EBX: which screen, from 0
.screen:
    lea rdi, [out_buf]
    mov ah, RR_SELECT
    mov al, byte [randr]
    stosw
    mov eax, 3                          ; the request's length: 3 fours
    stosw
    mov eax, [roots+rbx*4]              ; the screen's root window
    stosd
    mov eax, RR_CHANGES                 ; the kinds of change we want to hear of
    stosd
    call x_send
    lea rsi, [no_x_words]
    jc .done
    inc ebx
    cmp ebx, [root_count]
    jb .screen
    lea rdi, [out_buf]                  ; the harmless question
    mov eax, X_INPUT_FOCUS or 1 shl 16
    stosd
    call x_ask
.done:
    pop rbx
    ret

; x_wait: wait for news from X, one second at most.
; If news comes, it is read, and so is any more that is already
; waiting; then we go back at once. If none comes within the second, we
; go back too. Either way the tables are then set and checked again.
; Sets CF, with why at RSI, if X has ended or refused something.
x_wait:
    push rbx
    mov ebx, 1000                       ; EBX: how long to wait, in thousandths of a second
.wait:
    mov eax, [x]                        ; ask Linux to wake us when X's socket has
    mov [polled], eax                   ; something to read, or when the time is up
    mov [polled+4], POLLIN
    mov eax, SYS_POLL
    lea rdi, [polled]
    mov esi, 1
    mov edx, ebx
    syscall
    test eax, eax
    jle .done                           ; the time is up, with nothing to read. (CF is clear.)
    call x_next                         ; read what came
    jc .done
    xor ebx, ebx                        ; then look again without waiting, in case
    jmp .wait                           ; more has come already
.done:
    pop rbx
    ret

; x_send: send X the request built in out_buf.
; RDI points just past the request's last byte. The request is also
; counted, in sent: X counts them the same way, and marks each answer
; with its request's count. Sets CF if X has gone.
x_send:
    inc [sent]
    lea rsi, [out_buf]
    mov rdx, rdi                        ; RDX: how many bytes are left to send
    sub rdx, rsi
.more:
    mov eax, SYS_WRITE
    mov edi, [x]
    syscall
    test rax, rax
    jle .gone                           ; Linux could not send: X has gone
    add rsi, rax                        ; Linux may take only a part at a time:
    sub rdx, rax                        ; go on from where it stopped
    jnz .more
    clc
    ret
.gone:
    stc
    ret

; x_ask: send X the request built in out_buf, and wait for its answer.
; The answer lands in in_buf. Other messages may come first, and are
; passed by: notices, and an answer to an earlier request (one can be
; left over when X refused something). We know our answer by its count,
; which must be the count of the request just sent.
; Sets CF, with why at RSI, if X has gone, or refused the request.
x_ask:
    call x_send
    lea rsi, [no_x_words]
    jc .done
.next:
    call x_next
    jc .done
    cmp byte [in_buf], 1
    jne .next                           ; a notice: not what we wait for
    mov eax, [sent]
    cmp ax, word [in_buf+2]
    jne .next                           ; an answer, but to an earlier request
.done:
    ret

; x_next: read X's next message into in_buf.
; Every message starts with 32 bytes, and the first byte says what it
; is: 0 is a refusal, 1 is an answer, and 2 or more is a notice. Only
; an answer can be longer than 32 bytes: its bytes 4 to 7 say how much
; more follows, counted in fours.
; Sets CF, with why at RSI, if X has gone, if the message is a refusal,
; or if an answer is longer than in_buf has room for.
x_next:
    lea rdi, [in_buf]
    mov ecx, 32
    call x_read
    lea rsi, [no_x_words]
    jc .done
    cmp byte [in_buf], 0
    lea rsi, [refused_words]
    je .no                              ; a refusal
    cmp byte [in_buf], 1
    jne .done                           ; a notice: all 32 bytes are read. (CF is clear.)
    mov ecx, dword [in_buf+4]           ; an answer: how much more, in fours. It is checked
    lea rsi, [unsound_words]            ; before it is multiplied by 4, so a huge number
    cmp ecx, (IN_ROOM - 32) / 4         ; cannot wrap round into a small one.
    ja .no                              ; more than we have room for
    shl ecx, 2
    lea rdi, [in_buf+32]
    call x_read
    lea rsi, [no_x_words]
.done:
    ret
.no:
    stc
    ret

; x_read: read exactly ECX bytes from X, into the place RDI points at.
; It waits until all of them have come. Sets CF if X has gone.
x_read:
    mov edx, ecx                        ; EDX: how many bytes are still to come
.more:
    test edx, edx
    jz .done
    mov eax, SYS_READ
    push rdi rdx
    mov rsi, rdi
    mov edi, [x]
    syscall
    pop rdx rdi
    test rax, rax
    jle .gone                           ; nothing more will come: X has gone
    add rdi, rax                        ; Linux may give only a part at a time:
    sub edx, eax                        ; go on from where it stopped
    jmp .more
.done:
    clc
    ret
.gone:
    stc
    ret

; put_padded: copy ECX bytes from RSI into the request being built at
; RDI, then add 0 bytes until the request is a whole number of fours
; long. RDI ends up just past them.
; (The length is measured from out_buf's start, where every request
; begins. An earlier version measured from the wrong place, and sent X
; 2 bytes too many: seen in the test.)
put_padded:
    rep movsb
.pad:
    lea rax, [rdi-out_buf]              ; how long the request is so far
    test al, 3
    jz .done                            ; a whole number of fours: done
    mov byte [rdi], 0
    inc rdi
    jmp .pad
.done:
    ret

; ---- Asking Linux what the tables really hold

; look: check every graphics card. This is step 2, the check.
; Linux lists the cards as files named card0, card1 and so on, in the
; folder /dev/dri (or, for the tests, the folder NOBLUE_DRI names).
; Every such file is looked at, whatever its number. The result is
; three counts:
;   screens   how many screens are in use
;   missing   how many of them have no color table, or one that cannot
;             be read
;   highest   the most blue found in any table
; To pass, screens must be 1 or more, and missing and highest both 0.
look:
    push rbx rbp r12 r13
    xor eax, eax
    mov [screens], eax
    mov [missing], eax
    mov [highest], eax
    lea rsi, [dri_setting]              ; which folder?
    call setting
    jnc .folder
    lea rax, [dri_folder]
.folder:
    mov [dri_name], rax
    mov rdi, rax
    mov eax, SYS_OPEN
    mov esi, O_DIRECTORY
    xor edx, edx
    syscall
    test eax, eax
    js .done                            ; no such folder: no cards, so 0 screens, so the check fails
    mov [dir_fd], eax

    ; Ask Linux for the folder's names, a part at a time. Linux gives
    ; each name in an entry: the entry's length is in its bytes 16 and
    ; 17, and the name begins at its byte 19.
.read:
    mov eax, SYS_GETDENTS
    mov edi, [dir_fd]
    lea rsi, [dents]
    mov edx, DENTS_ROOM
    syscall
    test rax, rax
    jz .close_dir                       ; the end of the list
    jns .names
    inc [screens]                       ; Linux could not read the list to its end. A card may
    inc [missing]                       ; have gone unseen, so a screen with no table is
    jmp .close_dir                      ; counted: the check fails.
.names:
    lea r12, [dents]                    ; R12: the entry being read
    lea r13, [dents+rax]                ; R13: the end of this part
.entry:
    cmp r12, r13
    jae .read                           ; this part is done: ask for the next
    lea rbx, [r12+19]                   ; RBX: the name
    movzx eax, word [r12+16]
    add r12, rax                        ; R12 moves on to the next entry
    cmp dword [rbx], 'card'             ; a card's name is "card" and then a figure
    jne .entry
    mov al, [rbx+4]
    cmp al, '0'
    jb .entry
    cmp al, '9'
    ja .entry
    lea rdi, [card_path]                ; put together the folder, "/" and the name
    mov rsi, [dri_name]
    mov ecx, 100
    call put_within
    jc .unchecked
    mov al, '/'
    stosb
    mov rsi, rbx
    mov ecx, 100
    call put_within
    jc .unchecked
    call card                           ; and check that card
    jmp .entry
.unchecked:                             ; a name too long for its room. The card cannot be tried,
    inc [screens]                       ; so it is counted as a screen with no table: the check
    inc [missing]                       ; fails, as it should when a card went unchecked.
    jmp .entry
.close_dir:
    mov eax, SYS_CLOSE
    mov edi, [dir_fd]
    syscall
.done:
    pop r13 r12 rbp rbx
    ret

; card: check one card, the one named in card_path.
; It asks the card for its screen drivers. For each one that is showing
; a screen, it reads the color table and notes the most blue in it.
; The counts screens, missing and highest are added to.
; A card that cannot be opened, or will not list its screen drivers,
; could still be showing a screen. So it is counted as one screen with
; no table, and named in a line of its own.
card:
    push rbx rbp
    mov eax, SYS_OPEN
    lea rdi, [card_path]
    mov esi, O_RDONLY                   ; for reading only: we ask a card questions, and never change it
    xor edx, edx
    syscall
    test eax, eax
    jns .opened
    cmp eax, -ENOENT
    je .done                            ; it has gone since it was listed: no card, nothing to check
    call unchecked                      ; any other failure: it is there, and we cannot look
    jmp .done

    ; Ask for the list of its screen drivers. The block "resources" is
    ; the form Linux wants filled in: where to put the numbers, and how
    ; many we have room for. Linux writes back how many there are.
.opened:
    mov [fd], eax
    lea rdi, [resources]
    xor eax, eax
    mov ecx, 64 / 8
    rep stosq                           ; the form, all 0 to begin with
    lea rax, [card_crtcs]
    mov qword [resources+8], rax        ; where the numbers are to go
    mov dword [resources+36], CRTCS_MOST ; how many we have room for
    mov esi, GETRESOURCES
    lea rdx, [resources]
    call drm
    jc .unlisted                        ; it will not say
    mov ebx, dword [resources+36]       ; EBX: how many it has
    cmp ebx, CRTCS_MOST
    ja .unlisted                        ; more than our room: Linux gave us none of them
    xor ebp, ebp                        ; EBP: which screen driver, from 0

    ; Ask what this screen driver is showing. Linux fills in the block
    ; "crtc": at its byte 32, 0 means it is showing nothing.
.crtc:
    cmp ebp, ebx
    jae .close
    lea rdi, [crtc]
    xor eax, eax
    mov ecx, 104 / 8
    rep stosq
    mov eax, [card_crtcs+rbp*4]
    mov dword [crtc+12], eax            ; which screen driver we ask about
    mov esi, GETCRTC
    lea rdx, [crtc]
    call drm
    jc .unread
    cmp dword [crtc+32], 0
    je .next_crtc                       ; showing nothing: no screen to check
    inc [screens]                       ; a screen in use
    call lut_blue                       ; read its newer kind of table
    jnc .found                          ; read: EAX is its most blue
    jz .missing                         ; it has that kind, but none is set, so colors pass unchanged
    call gamma_blue                     ; the card has no newer kind: read the older
    jc .missing                         ; none of that either
.found:
    cmp eax, [highest]
    jbe .next_crtc
    mov [highest], eax                  ; more blue than seen so far: remember it
    jmp .next_crtc
.unread:                                ; it will not say what it shows: counted as a screen
    inc [screens]                       ; with no table, to fail the check
.missing:
    inc [missing]
.next_crtc:
    inc ebp
    jmp .crtc
.unlisted:
    call unchecked
.close:
    mov eax, SYS_CLOSE
    mov edi, [fd]
    syscall
.done:
    pop rbp rbx
    ret

; unchecked: a card could not be looked at. Count it as one screen with
; no table, and say so in a line naming the card (card_path). The watch
; says it the first time only (quiet).
unchecked:
    inc [screens]
    inc [missing]
    cmp [quiet], 0
    jne .said                           ; the watch has named its cards already
    lea rdi, [line]                     ; build the line: the card's name, then the words
    lea rsi, [card_path]
    call put_z
    lea rsi, [unread_words]
    call put_z
    lea rsi, [line]
    call put_out
.said:
    ret

; lut_blue: read a screen driver's newer kind of color table, and give
; back in EAX the most blue found in it. The screen driver is the one
; in the block "crtc".
; Linux keeps the newer table as one of the screen driver's "settings",
; the one named GAMMA_LUT. A setting's value here is the number of a
; "blob", a block of data that Linux hands over on request. So there
; are three steps: list the settings, find the one named GAMMA_LUT,
; and fetch its blob.
; If the table cannot be read, CF is set, and ZF (the zero flag,
; another of the chip's yes-or-no marks) says which way:
;   ZF set    the card has this kind of table, but none is set, or
;             something about it could not be read. The screen fails.
;             The older table is not tried: on newer cards it can be
;             out of date.
;   ZF clear  the card has no such setting at all, as old cards. The
;             older table is then read.
lut_blue:
    push rbx rbp

    ; Step 1: list the screen driver's settings. The block "props" is
    ; the form: where the settings' numbers and their values are to go,
    ; and how many we have room for.
    lea rdi, [props]
    xor eax, eax
    mov ecx, 32 / 8
    rep stosq
    lea rax, [prop_ids]
    mov qword [props], rax              ; where the settings' numbers go
    lea rax, [prop_values]
    mov qword [props+8], rax            ; where their values go
    mov dword [props+16], PROPS_MOST    ; how many we have room for
    mov eax, dword [crtc+12]
    mov dword [props+20], eax           ; whose settings: this screen driver's
    mov dword [props+24], OBJECT_CRTC
    mov esi, GETPROPERTIES
    lea rdx, [props]
    call drm
    jc .none                            ; it cannot list settings: an old card
    mov ebx, dword [props+16]           ; EBX: how many settings it has
    cmp ebx, PROPS_MOST
    ja .unset                           ; more than our room: we cannot look through them all
    xor ebp, ebp                        ; EBP: which setting, from 0

    ; Step 2: ask each setting's name, until one is GAMMA_LUT.
.prop:
    cmp ebp, ebx
    jae .none                           ; none is named GAMMA_LUT: the card has no newer table
    lea rdi, [prop]
    xor eax, eax
    mov ecx, 64 / 8
    rep stosq
    mov eax, [prop_ids+rbp*4]
    mov dword [prop+16], eax            ; which setting we ask about
    mov esi, GETPROPERTY
    lea rdx, [prop]
    call drm
    jc .unset                           ; its name cannot be read. It might be GAMMA_LUT: fail.
    lea rsi, [prop+24]                  ; the name Linux wrote
    lea rdi, [lut_name]
    call same_z
    je .lut
    inc ebp                             ; not that one: on to the next
    jmp .prop

    ; Step 3: fetch the blob. It is asked for twice: first with no
    ; room, which makes Linux say only how long it is; then with room,
    ; which makes Linux hand over its bytes.
.lut:
    mov eax, dword [prop_values+rbp*8]  ; the blob's number
    test eax, eax
    jz .unset                           ; 0: no table is set
    mov dword [blob], eax
    mov dword [blob+4], 0               ; the first asking: no room given
    mov qword [blob+8], 0
    mov esi, GETPROPBLOB
    lea rdx, [blob]
    call drm
    jc .unset
    mov ecx, dword [blob+4]             ; ECX: how many bytes long it is
    cmp ecx, LUT_MOST * 8
    ja .unset                           ; more than our room
    test ecx, ecx
    jz .unset                           ; empty
    test ecx, 7
    jnz .unset                          ; not a whole number of 8-byte entries: not a table we can trust
    mov ebx, ecx                        ; EBX: the length, remembered
    lea rax, [lut_entries]
    mov qword [blob+8], rax             ; the second asking: with room, at lut_entries
    mov esi, GETPROPBLOB
    lea rdx, [blob]
    call drm
    jc .unset
    cmp dword [blob+4], ebx             ; is it still as long? If not, the table was swapped
    jne .unset                          ; between the two askings, and Linux gave us no bytes.

    ; The table is a row of entries, 8 bytes each: red, green, blue,
    ; and 2 bytes not used, 2 bytes apiece. Find the biggest blue.
    mov ecx, ebx
    shr ecx, 3                          ; ECX: how many entries
    xor eax, eax                        ; EAX: the biggest blue so far
    xor esi, esi                        ; ESI: which entry, from 0
.entry:
    movzx edx, word [lut_entries+rsi*8+4]
    cmp edx, eax
    jbe .lower
    mov eax, edx
.lower:
    inc esi
    cmp esi, ecx
    jb .entry
    clc                                 ; read: EAX is the answer
    jmp .done
.unset:
    xor eax, eax                        ; this sets ZF: "it has the kind, but it fails"
    stc
    jmp .done
.none:
    or eax, 1                           ; this clears ZF: "no such kind: try the older"
    stc
.done:
    pop rbp rbx
    ret

; gamma_blue: read a screen driver's older kind of color table, and
; give back in EAX the most blue found in it. The screen driver is the
; one in the block "crtc", which also holds the table's size.
; The older table is three separate lists, of red, green and blue.
; Sets CF if there is no such table, or it cannot be read.
gamma_blue:
    mov ecx, dword [crtc+28]            ; ECX: how many entries the table has
    cmp ecx, 2
    jb .none                            ; none
    cmp ecx, LUT_MOST
    ja .none                            ; more than our room
    mov eax, dword [crtc+12]
    mov dword [gamma], eax              ; the form: which screen driver,
    mov dword [gamma+4], ecx            ; how many entries,
    lea rax, [red]
    mov qword [gamma+8], rax            ; and where each of the three lists is to go
    lea rax, [green]
    mov qword [gamma+16], rax
    lea rax, [blue]
    mov qword [gamma+24], rax
    mov esi, GETGAMMA
    lea rdx, [gamma]
    call drm
    jc .none
    mov ecx, dword [gamma+4]
    xor eax, eax                        ; EAX: the biggest blue so far
    xor esi, esi                        ; ESI: which entry, from 0
.blue:
    movzx edx, word [blue+rsi*2]
    cmp edx, eax
    jbe .lower
    mov eax, edx
.lower:
    inc esi
    cmp esi, ecx
    jb .blue
    clc
    ret
.none:
    stc
    ret

; drm: ask the open card one question.
; ESI is the question's number, and RDX points at its form. Linux
; fills the form in. Sets CF if Linux refused.
drm:
    mov eax, SYS_IOCTL
    mov edi, [fd]
    syscall
    cmp rax, 1                          ; Linux answers 0 for "done" and a negative number for "refused".
    cmc                                 ; These two lines set CF for anything but 0.
    ret

; ---- Words: saying what was found

; good: did the check pass?
; It passed only if there was at least one screen, none of them lacked
; a table, and no table had any blue. Clears CF for a pass, and sets it
; for a fail.
good:
    cmp [screens], 0
    je .bad                             ; no screen at all: nothing was checked, so no pass
    mov eax, [missing]
    or eax, [highest]                   ; both must be 0
    jnz .bad
    clc
    ret
.bad:
    stc
    ret

; say: print what look found, as one line. CF comes back as from good.
say:
    call found
    call put_out
    jmp good

; tell: print the words at RSI, unless they are the same words as last
; time. The watch uses this, so that it speaks only when something has
; changed, and not every second. The last words printed are kept in
; "last".
tell:
    push rbx
    mov rbx, rsi
    lea rdi, [last]
    call same_z
    je .told                            ; the same as last time: say nothing
    mov rsi, rbx
    lea rdi, [last]
    call put_z                          ; remember them,
    mov rsi, rbx
    call put_out                        ; and print them
.told:
    pop rbx
    ret

; found: put what look found into words, like
;   1 screen, 0 with no color table, blue at most 0
; The words are built in "line", and RSI comes back pointing at them.
found:
    lea rdi, [line]
    mov eax, [screens]
    call put_number
    lea rsi, [screens_words]            ; " screens, "
    cmp [screens], 1
    jne .screens
    lea rsi, [screen_words]             ; but for just one: " screen, "
.screens:
    call put_z
    mov eax, [missing]
    call put_number
    lea rsi, [missing_words]
    call put_z
    mov eax, [highest]
    call put_number
    mov byte [rdi], 0                   ; a 0 marks the end of the words
    lea rsi, [line]
    ret

; put_out: print one line: "noblue: ", then the words at RSI, then the
; end of the line. It goes to standard output: the screen, or wherever
; noblue's words were sent.
put_out:
    push rbx
    mov rbx, rsi
    lea rdi, [out_line]
    lea rsi, [name_words]               ; "noblue: "
    call put_z
    mov rsi, rbx
    call put_z                          ; the words
    mov byte [rdi], 10                  ; 10 is the mark for a line's end
    inc rdi
    lea rsi, [out_line]
    mov rdx, rdi
    sub rdx, rsi                        ; RDX: how many bytes the line is
    mov eax, SYS_WRITE
    mov edi, 1                          ; 1 is standard output
    syscall
    pop rbx
    ret

; put_number: write the number in EAX as figures, at RDI. RDI ends up
; just past them.
; Figures come out last one first: dividing by 10 leaves the last
; figure as the remainder. So they are written backwards into
; "figures", from its end, and then copied out in the right order.
put_number:
    lea r9, [figures+20]
    mov r10d, 10
.figure:
    xor edx, edx
    div r10d                            ; EAX: the number without its last figure; EDX: that figure
    add dl, '0'                         ; from a number to the letter for it
    dec r9
    mov [r9], dl
    test eax, eax
    jnz .figure                         ; more figures to come
    lea rcx, [figures+20]
    sub rcx, r9                         ; RCX: how many figures there are
    mov rsi, r9
    rep movsb
    ret

; put_z: copy the words at RSI to RDI.
; Words here end with a 0 byte (the z is for zero). The 0 is copied
; too, but RDI ends up pointing at it, so that more words can follow.
put_z:
    lodsb
    stosb
    test al, al
    jnz put_z
    dec rdi
    ret

; put_within: copy the words at RSI to RDI, but only if they fit.
; ECX is how many bytes there is room for, the ending 0 counted. Like
; put_z, RDI ends up at the 0. Sets CF if they do not fit; at most ECX
; bytes are written even then.
put_within:
    jecxz .long                         ; no room at all
.copy:
    lodsb
    stosb
    test al, al
    jz .done                            ; the ending 0 fitted: done
    loop .copy                          ; one byte less room; go on while there is some
.long:
    stc
    ret
.done:
    dec rdi
    clc
    ret

; same_z: are the words at RSI and at RDI the same, to their ending 0?
; Sets ZF if they are.
same_z:
    mov al, [rsi]
    cmp al, [rdi]
    jne .done                           ; a difference: not the same (ZF is clear)
    test al, al
    jz .done                            ; both ended together: the same (ZF is set)
    inc rsi
    inc rdi
    jmp same_z
.done:
    ret

; setting: find one of the settings Linux gave this program, like
; DISPLAY. RSI points at its name with "=" after it, as "DISPLAY=".
; Gives back RAX pointing at the setting's value. Sets CF if there is
; no such setting.
; The settings are a list of words like "DISPLAY=:0", ended by a 0.
setting:
    mov r8, [env]
.next:
    mov rdi, [r8]                       ; the next setting in the list
    test rdi, rdi
    jz .none                            ; the list's end: not there
    add r8, 8
    mov r9, rsi
.letter:
    mov al, [r9]
    test al, al
    jz .found                           ; the whole name matched: what follows is the value
    cmp al, [rdi]
    jne .next                           ; a difference: not this one
    inc r9
    inc rdi
    jmp .letter
.found:
    mov rax, rdi
    clc
    ret
.none:
    stc
    ret

; ---- The words themselves. Each ends with a 0 byte.

watch_word          db 'watch', 0
off_word            db 'off', 0
back_words          db 'off: blue is back. Every color table is plain again. Not checked.', 0
display_setting     db 'DISPLAY=', 0
socket_setting      db 'NOBLUE_SOCKET=', 0
dri_setting         db 'NOBLUE_DRI=', 0
xauthority_setting  db 'XAUTHORITY=', 0
home_setting        db 'HOME=', 0
xauthority_name     db '/.Xauthority', 0
socket_folder       db '/tmp/.X11-unix/X', 0
cookie_words        db 'MIT-MAGIC-COOKIE-1'
dri_folder          db '/dev/dri', 0
unread_words        db ' cannot be opened, or will not list its screens: counted as a screen with no color table', 0
lut_name            db 'GAMMA_LUT', 0
name_words          db 'noblue: ', 0
screens_words       db ' screens, ', 0
screen_words        db ' screen, ', 0
missing_words       db ' with no color table, blue at most ', 0
usage_words         db 'use it as: noblue, noblue watch, or noblue off', 0
no_display_words    db 'no display: DISPLAY must name this computer', 39, 's own, like :0', 0
no_x_words          db 'X cannot be reached, or has ended', 0
refused_words       db 'X refused (its key, or a request)', 0
unsound_words       db 'X', 39, 's answer does not add up', 0
too_long_words      db 'the socket', 39, 's name is too long (NOBLUE_SOCKET)', 0
no_randr_words      db 'X has no RandR, so no color tables', 0
too_many_words      db 'more screen drivers than noblue has room for', 0
too_big_words       db 'a color table bigger than noblue has room for', 0

; ---- What noblue keeps while it runs
; From here: places that hold numbers and words while noblue works.
; They can be read and written, but never run as instructions; and the
; instructions above can be run, but never written. So nothing sent to
; noblue can be made to run as a program.
; dq, dd: a place of 8 bytes, or of 4, with a starting value.
; rb, rw, rd, rq: room set aside, counted in units of 1, 2, 4 or 8
; bytes. Linux hands it over filled with 0s.
segment readable writeable
align 8

; What Linux is told to do with the signal SIGPIPE: 1 means "ignore
; it"; the three 0s are options not used.
ignored             dq 1, 0, 0, 0

; Where things are.
env                 dq 0                ; the settings Linux gave us
dri_name            dq 0                ; the name of the folder of cards
key_name            dq 0                ; the name of the key's kind, in the key file
key                 dq 0                ; the key, in the key file

; Choices and counts.
watching            dd 0                ; 1 for "noblue watch"
blue_back           dd 0                ; 1 for "noblue off"
quiet               dd 0                ; 1 once the watch has named the cards it could not read
sent                dd 0                ; how many requests we have sent X
x                   dd 0                ; Linux's number for our socket to X
fd                  dd 0                ; Linux's number for the card that is open
dir_fd              dd 0                ; Linux's number for the folder of cards
root_count          dd 0                ; how many screens X has
randr               dd 0                ; X's number for RandR
display_len         dd 0                ; how many figures in the display's number
host_len            dd 0                ; how many letters in this computer's name
welcome_len         dd 0                ; how long X's welcome is, after its first 8 bytes
key_name_len        dd 0                ; how long the key's kind's name is: 18, or 0 for no key
key_len             dd 0                ; how long the key is
screens             dd 0                ; the check's three counts: screens in use,
missing             dd 0                ; those with no table we could read,
highest             dd 0                ; and the most blue in any table
polled              dd 0, 0             ; the form for waiting: which socket, and what for

; Rooms for names.
display_number      rb 12               ; the display's number, as figures: 8 at most, and an ending 0
address             rb 112              ; the socket's address: 2 bytes for its kind, then its name, 108 at most
auth_path           rb 4096             ; the key file's name
card_path           rb 208              ; a card's name: the folder and the file, 100 bytes each at most
utsname             rb 392              ; Linux's answer about this computer: six names of 65 bytes, and 2 spare

; The forms for questions to a card. Linux fixes each one's size and layout.
resources           rb 64               ; the list of screen drivers (Linux's name: drm_mode_card_res)
crtc                rb 104              ; what one screen driver shows (drm_mode_crtc)
gamma               rb 32               ; an older color table (drm_mode_crtc_lut)
props               rb 32               ; the list of settings (drm_mode_obj_get_properties)
prop                rb 64               ; one setting's name (drm_mode_get_property)
blob                rb 16               ; one block of data (drm_mode_get_blob)

; Rooms for lists.
card_crtcs          rd CRTCS_MOST       ; a card's screen drivers, from Linux
crtc_ids            rd CRTCS_MOST       ; a screen's screen drivers, from X
roots               rd 255              ; each X screen's root window: X can have 255 at most
prop_ids            rd PROPS_MOST       ; a screen driver's settings,
prop_values         rq PROPS_MOST       ; and their values

; Rooms for words.
figures             rb 20               ; a number's figures, while they are worked out
line                rb 300              ; a line being built
last                rb 300              ; the last line the watch printed
out_line            rb 400              ; a line on its way out: "noblue: ", the line, and its end

; The big rooms.
dents               rb DENTS_ROOM       ; a part of the folder's list of names
red                 rw LUT_MOST         ; an older color table's three lists
green               rw LUT_MOST
blue                rw LUT_MOST
lut_entries         rq LUT_MOST         ; a newer color table
auth_buf            rb AUTH_ROOM        ; the key file
in_buf              rb IN_ROOM          ; what X sent us
out_buf             rb OUT_ROOM         ; what we are sending X

; The stack is the scratch area Linux gives every program. This line
; marks it like the rooms above: read and written, never run. Newer
; Linux does that anyway; older Linux does only if told.
segment gnustack readable writeable
