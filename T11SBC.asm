            PAGE 0                           ; suppress page headings in ASW listing file

            cpu T-11                         ; DEC DC310

;******************************************************************************************************
; Serial Monitor for T-11 Single Board Computer
;
; Serial I/O at 19200 bps, N-8-1.
;
; Assemble with the Macro Assembler AS V1.42 http://john.ccac.rwth-aachen.de:8000/as/
;
; Memory Map:
; 0000-7FFFH 32KB RAM
; 8000-EFFFH 28KB EPROM
; FE00H      6850 ACIA
; FF00H      6522 VIA
;  
; Monitor Commands:  B - resume after Breakpoint
;                    C - Call subroutine
;                    D - Dump a page of memory
;                    F - Fill block of RAM
;                    H - Intel Hex file download
;                    I - display Instructions (disassemble)
;                    J - Jump to address
;                    M - Modify RAM contents
;                    N - single-step Next instruction
;                    R - modify Registers
;                    S - Single-step
;                    U - print Uptime
;
; "Octal? We ain't got no octal! We don't need no octal! I don't have to show you any stinkin' octal!"
;
;******************************************************************************************************

; constants
CR          EQU   0x0D
LF          EQU   0x0A
ESC         EQU   0x1B

; VT100 escape sequences
CLS         EQU   "\e[2J\e[H"       ; clear screen and home cursor
CLRLINE     EQU   "\e[2K\e[1G"      ; clear line, move cursor to column 1
SGR0        EQU   "\e[0m"           ; character attributes off
SGR1        EQU   "\e[1m"           ; bold mode on
SGR2        EQU   "\e[2m"           ; low intensity mode on
SGR4        EQU   "\e[4m"           ; underline mode on
SGR5        EQU   "\e[5m"           ; blinking mode on
SGR7        EQU   "\e[7m"           ; reverse video on
SGR8        EQU   "\e[8m"           ; invisible text on 

; addresses
ACIA        EQU   0xFE00            ; 6850 ACIA
VIA         EQU   0xFF00            ; 6522 VIA
ORB         EQU   VIA               ; VIA Output Register B
ORA         EQU   VIA+1             ; VIA Output Register A
DDRB        EQU   VIA+2             ; VIA Data Direction Register B
DDRA        EQU   VIA+3             ; VIA Data Direction Register A
T1CL        EQU   VIA+4             ; VIA Timer 1 Counter low byte
T1CH        EQU   VIA+5             ; VIA Timer 1 Counter high byte
T1LL        EQU   VIA+6             ; VIA Timer 1 Latch low byte
T1LH        EQU   VIA+7             ; VIA Timer 1 Latch high byte
ACR         EQU   VIA+11            ; VIA Auxiliary Control Register
PCR         EQU   VIA+12            ; VIA Peripheral Control Register
IFR         EQU   VIA+13            ; VIA Interrupt Flag Register
IER         EQU   VIA+14            ; VIA Interrupt Enable Register

; variables are stored starting at the bottom of RAM page 0x7E and work up
BUFF        EQU   0x7E00            ; 16 byte serial input buffer
INPTR       EQU   0x7E10            ; serial buffer input pointer
OUTPTR      EQU   0x7E11            ; serial buffer output pointer
BLINK       EQU   0x7E12            ; blink orange LED flag
TICKS       EQU   0x7E13            ; timer interrupt ticks counter
SECS        EQU   0x7E14            ; uptime seconds count
MINS        EQU   0x7E15            ; uptime minutes count
HRS         EQU   0x7E16            ; uptime hours count
LINECOUNT   EQU   0x7E17            ; line counter for disassembly
ESCCOUNT    EQU   0x7E18            ; ESC key counter
FLAGS       EQU   0x7E19            ; various flags
DLCOUNT     EQU   0x7E1A            ; number of bytes downloaded
OPCODE      EQU   0x7E1C            ; copy of the instruction being disassembled
OPMODE      EQU   0x7E1E            ; addressing mode for the operand being disassembled
SAVED_R0    EQU   0x7E20            ; registers, SP, PC and PS are saved in RAM here. 
SAVED_R1    EQU   0x7E22
SAVED_R2    EQU   0x7E24
SAVED_R3    EQU   0x7E26
SAVED_R4    EQU   0x7E28
SAVED_R5    EQU   0x7E2A
SAVED_SP    EQU   0x7E2C
SAVED_PC    EQU   0x7E2E
SAVED_PS    EQU   0x7E30

; useful macros...

; call a subroutine at 'address'
CALL        macro address
            JSR   PC,@#address
            endm

; print the character 'char' to the console
TYPE        macro char
            PUSH  R4
            MOVB  #char,R4
            CALL  PUTC
            POP   R4
            endm
            
; print the zero-terminated string at 'address' to the console
PRINT       macro address
            MOV   #address,R5
            CALL  PUTS  
            endm
           
; push 'register' onto the stack            
PUSH        macro register
            MOV   register,-(SP)
            endm
            
; pop 'register' from the stack            
POP         macro register
            MOV   (SP)+,register
            endm
            
; return from subroutine            
RETURN      macro
            RTS   PC
            endm

;=======================================================================
; power-on-reset jumps here
;=======================================================================
            ORG   0x8000
            JMP   @#INIT

; HALT instruction jumps here
            ORG   0x8004
            JMP   @#HALTED
            
; cold start initialization starts here
INIT:       MOV   #0x7FFE,SP        ; initialize SP    
            MOV   #VECTORS,R0       ; address of the VECTORS table
            MOV   #0x0008,R1        ; destination address for VECTORS in RAM
            MOVB  #52,R2            ; number of words to copy
            
; copy the VECTORS table to RAM
INIT1:      MOV   (R0)+,(R1)+       ; copy 
            DECB  R2
            BNE   INIT1
            MOVB  #50,@#TICKS       ; initialize tick counter
            CLRB  @#FLAGS           ; clear flags
            CLRB  @#ESCCOUNT        ; clear the ESC key counter
            CLRB  @#SECS            ; reset seconds counter
            CLRB  @#MINS            ; reset minutes counter
            CLRB  @#HRS             ; reset hours counter
           ;CLRB  @#BLINK           ; clear flag to disable flashing orange LED
            MOVB  #0xFF,@#BLINK     ; set flag to enable flashing orange LED

            ; initialize ACIA
            MOVB  #0x03,@#ACIA      ; reset 6850 ACIA
            MOVB  #0x96,@#ACIA      ; divide 1.2288 MHz by 64 (19200 bps), N-8-1, RTS low, receive interrupt enabled
            CLRB  @#INPTR           ; clear buffer pointers
            CLRB  @#OUTPTR
            
            ; initialize VIA port B
            MOVB  #0xFF,@#DDRB      ; initialize VIA's DDRB to make all Port B pins outputs
            MOVB  #0x00,@#ORB       ; turn off all yellow LEDS connected to Port B pins
            MOVB  #0xCC,@#PCR       ; turn off red LED connected to CA2 and orange LED connected to CB2

            ; initialize VIA Timer 1
            MOVB  #0xFE,@#T1CL
            MOVB  #0xBF,@#T1CH      ; divide 2.4576 MHz clk by 49152-2 to interrupt 50 times per second
            MOVB  #0x40,@#ACR       ; continuous interrupts, disable PB7 square wave output
           ;MOVB  #0xC0,@#ACR       ; continuous interrupts, enable PB7 square wave output
            MOVB  #0xC0,@#IER       ; set the interrupt enable flag for Timer 1

            ; global interrupt enable
            MTPS  #0x80             ; set priority bits in PS to enable interrupts priority 5 and above
            
            PRINT BANNERTXT         ; print the banner
PRINTMENU:  CALL CRLF
            PRINT MENUTXT           ; print the menu

; loop here processing commands from the console...
GETCMD:     PRINT PROMPTTXT         ; prompt for a command
GETCMD1:    CALL  GETC              ; get a command character from the console
            CALL  UPPER             ; convert the command character to upper case
            MOV   #CMDTABLE,R0      ; address of the table of commands and functions
GETCMD2:    CMPB  R4,(R0)           ; compare the command character from the console to the table entry
            BEQ   GETCMD5           ; branch if the command character from the console matches the table entry
            INC   R0                ; else, increment R0 to point to the next table entry
            INC   R0
            INC   R0
            INC   R0
            TST   (R0)              ; have we reached the end of the table?
            BNE   GETCMD2           ; not yet, go back and try again for a match
            
; reached the end of 'CMDTABLE' without finding a match            
            CMPB  #ESC,R4           ; was the command the ESC key?
            BNE   GETCMD3
            INCB  @#ESCCOUNT        ; if so, increment the counter
            BR    GETCMD1           ; then go back for another key

GETCMD3:    CMPB  #'?',R4           ; was the command the '?' key?
            BNE   GETCMD4
            CMPB  @#ESCCOUNT,#2     ; was it ESC, ESC followed by '?'
            BNE   GETCMD4
            PRINT BUILTBYTXT        ; if so, display the 'Built by' message
GETCMD4:    CLRB  @#ESCCOUNT  
            BR    PRINTMENU         ; if yes, go back and re-print the menu            
            
; branch here if the command from the console matches an entry in 'CMDTABLE'
GETCMD5:    INC   R0                ; increment R0 to point to the address following the command character
            INC   R0
            MOV   (R0),R1           ; load the address into R1
            JMP   (R1)              ; jump to the address to execute the function

CMDTABLE:   WORD  'D'
            WORD  DUMP              ; address of 'dump memory' function
            WORD  'M'
            WORD  MODIFY            ; address of 'examine/modify memory' function
            WORD  'U'
            WORD  UPTIME            ; address of 'print uptime' function
            WORD  'F'
            WORD  FILL              ; address of 'fill memory' function
            WORD  'R'
            WORD  REGISTERS         ; address of 'modify registers' function
            WORD  'H'
            WORD  HEXDL             ; address of 'hex file download' function
            WORD  'C'
            WORD  CALLSUB           ; address of 'call subroutine' function
            WORD  'S'
            WORD  STEP              ; address of 'single step' function
            WORD  'N'
            WORD  NEXT              ; address of 'single step next instruction' function
            WORD  'R'
            WORD  RESUME            ; address of 'resume execution after breakpoint' function
            WORD  'J'
            WORD  JUMP              ; address of 'jump' function
            WORD  'I'
            WORD  DISASSEM          ; address of 'disassembler' function 
            WORD  0x02              ; ^B
            WORD  BPTTEST           ; address of 'BPT' test function 
            WORD  0x13              ; ^S
            WORD  STEPTEST          ; address of 'single-step' test function 
            WORD  0x14              ; ^T
            WORD  TRAPTEST          ; address of 'TRAP' test function 
            WORD  0
            
;=======================================================================
; disassemble one screen of instructions.
; 'SPACE' disassembles the next screen. 'ESC' exits.
;=======================================================================            
DISASSEM:   PRINT DISASSEMTXT
            CALL  GET4HEX           ; get the starting memory address into R1
            BCS   DISASSEM7         ; 'ESC' key cancels
            BVS   DISASSEM7         ; 'SPACE' exits
            BIC   #0x0001,R1        ; make sure it's an even address
            CALL  CRLF
DISASSEM0:  MOV   R1,R4             ; starting address into R4
            CLRB  @#LINECOUNT
DISASSEM1:  CALL  INSTA             ; disassemble the next instruction
            CALL  CRLF
            INCB  @#LINECOUNT
            CMPB  @#LINECOUNT,#22   ; have we reached the end of the screen?
            BLOS  DISASSEM1         ; and keep going until we're done
            MOV   R4,R1             
            PRINT NEXTTXT
            CALL  GETC              ; wait for a key
            PRINT CLRLINETXT        ; clear line and move cursor to position 1
            CMPB  #' ',R4           ; is it 'SPACE'?
            BNE   DISASSEM7
            BR    DISASSEM0
DISASSEM7:  JMP   @#GETCMD          ; else, exit
           
;=======================================================================
; examine/modify register. display contents of R0-R5, SP, PC and PS. 
; the SP display shows the value of stack pointer before this function was
; called. the PC display shows the address of the caller of this function
; (GETCMD). PS is displayed as an eight binary number. pause to allow 
; entry (in hex) of new register values for R0-R5. 'SPACE' skips the current
; register and increments to the next register. 'ESC' exits.
;=======================================================================
REGISTERS:  PRINT REGTXT          
            CALL  SHOWREGS          ; print what was contained in the registers
            MOV   #SAVED_R0,R0      ; R0 now points to the memory location where R0 was saved
            MOVB  #'0',R3
REGISTERS1: CALL  CRLF
            MOVB  #'R',R4
            CALL  PUTC              ; print 'R'
            MOVB  R3,R4
            CALL  PUTC              ; print the register number
            MOV   #'=',R4
            CALL  PUTC
            MOV   (R0),R1           ; get the saved register contents
            CALL  PRINT4HEX         ; print the contents
            PRINT ARROWTXT          ; print '-->'
            CALL  GET4HEX           ; get the new value for the register
            BCS   REGISTERS3        ; branch if 'ESC'
            BVC   REGISTERS2        ; branch if not 'SPACE'
            MOV   (R0),R1           ; if 'SPACE' use the saved register contents unaltered
            CALL  PRINT4HEX         ; print it
REGISTERS2: MOV   R1,(R0)           ; update memory
            INC   R0                ; point to the next memory location
            INC   R0
            INCB  R3
            CMPB  #'6',R3
            BNE   REGISTERS1        ; loop through registers '0'-'5'
            ; update the registers
            MOV   @#SAVED_R0,R0     ; update R0 with new value
            MOV   @#SAVED_R1,R1     ; update R1 with new value
            MOV   @#SAVED_R2,R2     ; update R2 with new value
            MOV   @#SAVED_R3,R3     ; update R3 with new value
            MOV   @#SAVED_R4,R4     ; update R4 with new value
            MOV   @#SAVED_R5,R5     ; update R5 with new value
REGISTERS3: JMP   @#GETCMD
            
;=======================================================================
; single-step. prompt for an address. execute one instruction at that address.
; display registers and PS then return to GETCMD.
;=======================================================================
STEP:       PRINT STEPTXT           ; prompt for address
            CALL  GET4HEX           ; get the starting memory address into R1
            BCS   STEP2             ; 'ESC' key exits
            BVS   STEP2             ; 'SPACE' key exits
STEP1:      PUSH  R1                ; save the address
            MOV   R1,R4             ; address into R4
            CALL  CRLF
            CALL  INSTA             ; disassemble the instruction at R4
            CALL  CRLF
            POP   R1                ; recall the address
            MFPS  R0                ; retrieve PS into R0
            BIS   #0x0010,R0        ; set T bit
            PUSH  R0                ; push R0 as though it were PS
            PUSH  R1                ; push the step address in R1 as though it were PC
            BISB  #0x80,@#FLAGS     ; set the single-step flag
            RTT                     ; simulate return from TRAP
            
; 'ESC' or 'SPACE' branches here
STEP2:      JMP   @#GETCMD

;=======================================================================
; single step - execute the next instruction
;=======================================================================
NEXT:       MOV   @#SAVED_PC,R4
            CALL  CRLF
            CALL  INSTA             ; disassemble the next instruction at R4
            CALL  CRLF
            MOV   @#SAVED_R0,R0     ; restore R0 with its original value
            MOV   @#SAVED_R1,R1     ; restore R1 with its original value
            MOV   @#SAVED_R2,R2     ; restore R2 with its original value
            MOV   @#SAVED_R3,R3     ; restore R3 with its original value
            MOV   @#SAVED_R4,R4     ; restore R4 with its original value
            MOV   @#SAVED_R5,R5     ; restore R5 with its original value
            MOV   @#SAVED_SP,SP     ; restore SP with its original value
            BIS   #0x0010,@#SAVED_PS; set the T bit
            PUSH  SAVED_PS          ; push PS
            PUSH  SAVED_PC          ; push PC
            RTT

;=======================================================================
; execute next instruction after breakpoint
;=======================================================================
RESUME:     MOV   @#SAVED_R0,R0     ; restore R0 with its original value
            MOV   @#SAVED_R1,R1     ; restore R1 with its original value
            MOV   @#SAVED_R2,R2     ; restore R2 with its original value
            MOV   @#SAVED_R3,R3     ; restore R3 with its original value
            MOV   @#SAVED_R4,R4     ; restore R4 with its original value
            MOV   @#SAVED_R5,R5     ; restore R5 with its original value
            MOV   @#SAVED_SP,SP     ; restore SP with its original value
            BIC   #0x0010,@#SAVED_PS; clear the T bit
            PUSH  SAVED_PS          ; push PS
            PUSH  SAVED_PC          ; push PC
            RTT

;=======================================================================
; dump one page of memory in hex and ASCII
;=======================================================================
DUMP:       PRINT DUMP1TXT          ; prompt for address
            CALL  GET4HEX           ; get the starting memory address into R1
            BCS   DUMP7             ; 'ESC' key cancels
            BVS   DUMP7             ; 'SPACE' exits
            BIC   #0x00FF,R1        ; mask out the least significant bits of the starting address
            MOV   R1,R0             ; starting address into R2
DUMP0:      CALL  CRLF
            PRINT DUMP2TXT
            MOVB  #16,R5            ; 16 lines per page  
DUMP1:      MOV   R0,R1
            CALL  BOLDON            ; turn on bold attribute
            CALL  PRINT4HEX         ; print the starting address
            CALL  BOLDOFF
            CALL  SPACE
            CALL  SPACE
            MOVB  #16,R3            ; 16 bytes per line
DUMP2:      MOVB  (R0)+,R1          ; load the byte into R1
            CALL  PRINT2HEX         ; print the byte
            CALL  SPACE
            DECB  R3                ; decrement the byte counter
            BNE   DUMP2             ; loop until 16 bytes have been printed
            CALL  SPACE
            SUB   #16,R0            ; reset the address back to the start of the line
            MOVB  #16,R3            ; re-load the byte counter
DUMP3:      MOVB  (R0)+,R4          ; load the character from memory into R4
            CMPB  R4,#0x20
            BHIS  DUMP4             ; branch if is above 0x20
            MOVB  #'.',R4           ; else substitute '.' for an unprintable character
            BR    DUMP5             ; go print the '.'
            
DUMP4:      CMPB  R4,#0x7F
            BLO   DUMP5             ; branch if below 0x7F
            MOVB  #'.',R4           ; else substitute '.' for an unprintable character
DUMP5:      CALL  PUTC              ; print the character
            DECB  R3                ; decrement the byte counter
            BNE   DUMP3             ; loop until 16 characters have been printed
            CALL  CRLF              ; new line
            DECB  R5                ; decrement the line counter
            BNE   DUMP1             ; loop until 16 lines have been printed
            CALL  CRLF              ; new line
            PRINT DUMP3TXT          ; prompt for input
            CALL  GETC              ; wait for a key
            CALL  CRLF              ; new line
            CMPB  #'+',R4           ; is it '+'?
            BEQ   DUMP0             ; branch to display next page of memory
            CMPB  #'-',R4           ; is it '-'
            BNE   DUMP7             ; exit if neither '+' nor '-'
            SUB   #512,R0           ; else, back up two pages
            BR    DUMP0             ; go display previous page
            
DUMP7:      JMP   @#GETCMD

;=======================================================================
; examine/modify memory contents. display the current contents of the memory
; location. pause to allow entry (in hex) of a new value. 'SPACE' skips the
; current memory location and increments to the next memory location. 'ESC' exits.
;=======================================================================
MODIFY:     PRINT MODIFYTXT         ; prompt for address
            CALL  GET4HEX           ; get the starting memory address into R1
            BCS   MODIFY3           ; 'ESC' key exits
            BVS   MODIFY3           ; 'SPACE' exits
            CALL  CRLF
MODIFY1:    CALL  CRLF              ; new line
            CALL  PRINT4HEX         ; print the memory address
            MOV   R1,R2             ; save the memory address in R2
            MOV   #'=',R4
            CALL  PUTC
            MOVB  (R2),R1           ; get the byte from memory addressed by R2 into R1
            CALL  PRINT2HEX         ; print the data byte
            PRINT ARROWTXT          ; print '-->'
            CALL  GET2HEX           ; get the new memory value into R1
            BCS   MODIFY3           ; branch if 'ESC'
            BVC   MODIFY2           ; branch if not 'SPACE'
            CALL  PRINT2HEX         ; else, print the present byte 
MODIFY2:    MOVB  R1,(R2)           ; store the new value in R1 at the address R2
            INC   R2                ; next memory address
            MOV   R2,R1
            BR    MODIFY1
            
; 'ESC' or 'SPACE' branches here            
MODIFY3:    CALL  CRLF
            JMP   @#GETCMD

;=======================================================================
; print the uptime as HH:MM:SS
;=======================================================================
UPTIME:     PRINT UPTIMETXT
            MOV   #0xFF,R5          ; do NOT suppress leading zeros
            MOVB  @#HRS,R1
            MOV   #10,R3
            CALL  DIGIT             ; print the hours tens digit
            ADD   #0x30,R1
            MOVB  R1,R4
            CALL  PUTC              ; print the hours units digit
            MOVB  #':',R4
            CALL  PUTC              ; print the ':' separator
            MOVB  @#MINS,R1
            MOV   #10,R3
            CALL  DIGIT             ; print the minutes tens digit
            ADD   #0x30,R1
            MOVB  R1,R4
            CALL  PUTC              ; print the minutes units digit
            MOVB  #':',R4
            CALL  PUTC              ; print the ':' separator
            MOVB  @#SECS,R1
            MOV   #10,R3
            CALL  DIGIT             ; print the seconds tens digit
            ADD   #0x30,R1
            MOVB  R1,R4
            CALL  PUTC              ; print the seconds units digit
            CALL  CRLF
            JMP   @#GETCMD

;=======================================================================
; fill a block of memory with a byte. prompt for entry (in hex) of starting
; address, byte count and fill byte.
;=======================================================================
FILL:       PRINT FILLTXT           ; prompt for address
            CALL  GET4HEX           ; get the memory address into R1
            BCS   FILL3             ; 'ESC' key exits
            BVS   FILL3             ; 'SPACE' exits
            MOV   R1,R2             ; save the address in R2
            CALL  CRLF              ; new line
            PRINT COUNTTXT          ; prompt for the byte count
            CALL  GET4HEX           ; get the byte count into R1
            BCS   FILL3             ; 'ESC' key exits
            BVS   FILL3             ; 'SPACE' exits
            MOV   R1,R3             ; save the byte count in R3
            CALL  CRLF              ; new line
            PRINT VALUETXT          ; prompt for the byte to fill memory
            CALL  GET2HEX           ; get the fill byte into R1
            BCS   FILL3             ; 'ESC' key exits
            BVS   FILL3             ; 'SPACE' exits
            MOVB  R1,R4             ; save the fill value in R4
FILL2:      MOVB  R4,(R2)+          ; store the value (in R4) at the address in R2
            DEC   R3                ; decrement the byte count
            BNE   FILL2             ; loop back until the byte count is zero
FILL3:      CALL  CRLF              ; new line
            JMP   @#GETCMD

;=======================================================================
; jump to an address
;=======================================================================
JUMP:       PRINT JUMPTXT           ; prompt for memory address
            CALL  GET4HEX           ; get the memory address into R1
            BCS   JUMP1             ; 'ESC' key exits
            BVS   JUMP1             ; 'SPACE' exits
            CALL  CRLF
            BIC   0x0001,R1         ; must be an even address
            JMP   (R1)              ; jump to the address now in R1
            
; 'ESC' or 'SPACE' branches here
JUMP1:      CALL  CRLF
            JMP   @#GETCMD
            
;=======================================================================
; call a subroutine
;=======================================================================
CALLSUB:    PRINT CALLTXT           ; prompt for address
            CALL  GET4HEX           ; get the subroutine address into R1
            BCS   JUMP1             ; 'ESC' key exits
            BVS   JUMP1             ; 'SPACE' exits
            BIC   0x0001,R1         ; must be an even address
            CALL  CRLF
            CALL  CRLF            
            JSR   PC,(R1)           ; call the subroutine whose address is now in R1
            JMP   @#GETCMD

;=======================================================================
; Download Intel HEX file
; A record (line of text) consists of six fields that appear in order from left to right:
;   1. Start code: one character, an ASCII colon ':'.
;   2. Byte count: two hex digits, indicating the number of bytes in the data field.
;   3. Address: four hex digits, representing the 16-bit beginning memory address offset of the data.
;   4. Record type: two hex digits (00=data, 01=end of file), defining the meaning of the data field.
;   5. Data: a sequence of n bytes of data, represented by 2n hex digits.
;   6. Checksum: two hex digits, a computed value (starting with the byte count) used to verify record data.
;
; Note: when using TeraTerm to 'send' an Intel hex file, make sure that
; TeraTerm is configured for a transmit delay of 1 msec/char.
;=======================================================================
HEXDL:      CLRB  R3                ; clear the checksum error count
            CLR   @#DLCOUNT         ; clear the downloaded bytes counter
            CMP   #':',R4           ; has the start of record character already been received?
            BEQ   HEXDL3            ; if so, skip the prompt
            PRINT HEXDLTXT          ; else, prompt for hex download
HEXDL1:     CALL  GETC              ; get the first character of the record
            CMPB  #ESC,R4
            BEQ   HEXDL8            ; 'ESC' exits
            CMP   #':',R4           ; start of record character?
            BNE   HEXDL1            ; if not, go back for another character

; start of record character ':' received...
HEXDL3:     CALL  CRLF
            MOVB  #':',R4
            CALL  PUTC              ; print the ':' start of record character
            CALL  GET2HEX           ; get the record's byte count
            MOVB  R1,R2             ; save the byte count in R2
            MOVB  R1,R0             ; save the byte count as the checksum
            CALL  GET4HEX           ; get the record's address
            MOV   R1,R5             ; save the address in R5
            SWAB  R1
            ADD   R1,R0             ; add the address high byte to the checksum
            SWAB  R1
            ADD   R1,R0             ; add the address low byte to the checksum
            CALL  GET2HEX           ; get the record type
            ADD   R1,R0             ; add the record type to the checksum
            CMP   #0x01,R1          ; is this record the end of file?
            BEQ   HEXDL5            ; branch if end of file record
HEXDL4:     CALL  GET2HEX           ; get a data byte
            ADD   R1,R0             ; add the data byte to the checksum
            MOVB  R1,(R5)+          ; store the data byte in memory
            INC   @#DLCOUNT
            DECB  R2                ; decrement the byte count
            BNE   HEXDL4            ; if not zero, go back for another data byte

; Since the record's checksum byte is the two's complement and therefore the additive inverse
; of the data checksum, the verification process can be reduced to summing all decoded byte
; values, including the record's checksum, and verifying that the LSB of the sum is zero.
            CALL  GET2HEX           ; else, get the record's checksum
            ADD   R1,R0             ; add the record's checksum to the computed checksum
            CMPB  #0x00,R0
            BEQ   HEXDL1            ; no errors, go back for the next record
            INCB  R3                ; else, increment the error count
            BR    HEXDL1            ; go back for the next record

; end of file record
HEXDL5:     CALL  GET2HEX           ; get the last record's checksum
            CALL  GETC              ; get the CR at the end of the last record
            CALL  CRLF
            MOV   @#DLCOUNT,R1
            CALL  PRNDECWORD        ; print the count of downloaded bytes
            PRINT DLCNTTXT
            TSTB  R3
            BNE   HEXDL6            ; branch if there are checksum errors
            PRINT NOERRTXT         ; else, print "no checksum errors"
            BR    HEXDL8
            
HEXDL6:     MOVB  R3,R1
            CALL  PRNDECBYTE       ; print the number if checksum errors
            PRINT CKSERRTXT
HEXDL8:     JMP   @#GETCMD
            
;-------------------------------------------------------------------
; display the contents of the registers as 4 digit hex numbers (except for
; PS which is displayed as an 8 bit binary number).
;-------------------------------------------------------------------
SHOWREGS:   MOV   (SP),@#SAVED_PC   ; save the return address of the caller
            SUB   #4,@#SAVED_PC     ; 'SAVED_PC' now has the PC that called the 'REGISTERS' function
            MOV   SP,@#SAVED_SP     ; save SP
            ADD   #2,@#SAVED_SP     ; 'SAVED_SP' now has the SP value before this function was called
            MOV   R5,@#SAVED_R5     ; save R5
            MOV   R4,@#SAVED_R4     ; save R4
            MOV   R3,@#SAVED_R3     ; save R3
            MOV   R2,@#SAVED_R2     ; save R2
            MOV   R1,@#SAVED_R1     ; save R1
            MOV   R0,@#SAVED_R0     ; save R0
            MFPS  @#SAVED_PS        ; save PS            
SHOWREGS0:  MOVB  #'0',R3
            MOV   #SAVED_R0,R0      ; R0 points to the first memory location where the registers are saved
SHOWREGS1:  MOV   (R0),R1           ; get the saved register contents into R1
            MOV   #'R',R4
            CALL  PUTC              ; print 'R'
            MOV   R3,R4
            CALL  PUTC              ; print '0'-'6' for the register number
            MOV   #'=',R4
            CALL  PUTC              ; print '='
            CALL  PRINT4HEX         ; print the saved register contents
            CALL  SPACE             ; print a space between contents
            INC   R0                ; point to the next memory location where registers were saved
            INC   R0
            INCB  R3                ; increment the register number
            CMPB  #'6',R3
            BNE   SHOWREGS1         ; print contents of all registers R0-R5
            PRINT SPTXT             ; print 'SP='
            MOV   @#SAVED_SP,R1
            CALL  PRINT4HEX         ; print the contents of SP
            CALL  SPACE
            PRINT PCTXT             ; print 'PC='
            MOV   @#SAVED_PC,R1
            CALL  PRINT4HEX         ; print the contents of PC
            CALL  SPACE
            PRINT PSWTXT            ; print 'PS='
            MOV   @#SAVED_PS,R1
            CALL  PRINT8BIN         ; print the contents of PS in binary
            RETURN
            
;-------------------------------------------------------------------
; get a maximum of five decimal digits from the console. leading zeros
; need not be entered. press <ENTER> if fewer than five digits. return 
; with carry set if 'ESC'. else return with carry clear and the 
; unsigned binary number in R1.
; CAUTION: no error checking for numbers greater than 65535!
;-------------------------------------------------------------------
GET5DEC:    PUSH  R2                ; push R2
            PUSH  R5                ; push R5
            CLR   R1                ; start with zero
            MOVB  #5,R2             ; R2 is the digit counter
GET5DEC1:   CALL  GETC              ; wait for input from the console
            CMPB  #CR,R4            ; is it 'ENTER'?
            BEQ   GET5DEC2          ; branch if 'ENTER'
            CMPB  #ESC,R4           ; is it 'ESC'?
            BEQ   GET5DEC3          ; branch if 'ESC'
            CMPB  R4,#'0'           ; else, is the digit less than '0'?
            BCS   GET5DEC1          ; branch if R4 is less than '0'
            CMPB  R4,#'9'+1         ; is the digit higher than '9'?
            BCC   GET5DEC1          ; go back for another character if higher than '9'
            CALL  PUTC              ; since it's a legit decimal digit, echo the digit
            SUB   #0x30,R4          ; convert the ASCII digit in R4 to binary
            MOV   R1,R5             ; copy R1 to R5
            ADD   R1,R1             ; double R1 (effectively multiplying R1 by 2)
            ADD   R1,R1             ; double R1 again (effectively multiplying R1 by 4)
            ADD   R5,R1             ; add in original R1 value (effectively multiplying R1 by 5)
            ADD   R1,R1             ; double R1 again. (effectively multiplying R1 by 10)
            ADD   R4,R1             ; finally add in the last digit entered
            DECB  R2                ; decrement the digit count
            BNE   GET5DEC1          ; go back for the next decimal digit if fewer than 5 digits entered
GET5DEC2:   POP   R5                ; pop R5
            POP   R2                ; pop R2
            CLC
            RETURN
; 'ESC'            
GET5DEC3:   POP   R5                ; pop R5
            POP   R2                ; pop R2
            SEC
            RETURN

;-------------------------------------------------------------------
; get six octal digits 000000-177777 from the console. echo valid
; octal digits. return with carry set if 'ESC'. else return with
; carry clear and the word in R1.
;-------------------------------------------------------------------
GET6OCT:    PUSH  R0                ; push R0
            PUSH  R4                ; push R4
            MOVB  #6,R0             ; six digits
            CLR   R1                ; result 'accumulator'
GET6OCT1:   CALL  GETC              ; get the first octal digit
            CMPB  #ESC,R4           ; is it 'ESC'?
            BEQ   GET6OCT5          ; branch if 'ESC'
            CMPB  #'0',R4
            BEQ   GET6OCT3          ; branch if the first digit is '0'
            CMP   #'1',R4
            BEQ   GET6OCT3          ; branch if the first digit is '1'
            BR    GET6OCT1          ; else, try again for the first digit. first digit must be '0' or '1'
            
GET6OCT2:   CALL  GETC              ; get the next digit
            CMPB  #ESC,R4           ; is it 'ESC'?
            BEQ   GET6OCT5          ; branch if 'ESC'
            CMPB  R4,#'0'           ; else, is the digit less than '0'?
            BCS   GET6OCT2          ; branch if the digit is less than '0'
            CMPB  R4,#'7'+1         ; is the digit higher than '7'?
            BCC   GET6OCT2          ; go back for another character if the digit is higher than '7'
GET6OCT3:   CALL  PUTC              ; else, echo the digit
            ASL   R1                ; multiply the 'accumulator' by 8
            ASL   R1
            ASL   R1
            SUB   #'0',R4           ; convert the ASCII octal digit to binary
            ADD   R4,R1             ; add the new digit to the 'accumulator'
            DECB  R0                ; decrement the digit count
            BNE   GET6OCT2          ; branch if fewer an six digits have been entered
            POP   R4                ; pop R4
            POP   R0                ; pop R0
            CLC                     ; clear carry            
            RETURN
            
; 'ESC' branches here           
GET6OCT5:   POP   R4                ; pop R4
            POP   R0                ; pop R0
            SEC                     ; set carry            
            RETURN
            
;-------------------------------------------------------------------
; get three octal digits 000-377 from the console.  leading zeros need not
; be entered. echo valid octal digits. return with carry set if 'ESC'. 
; return with overflow set if 'SPACE'. else return with carry and 
; overflow clear and the byte in R1.
;-------------------------------------------------------------------            
GET3OCT:    PUSH  R4                ; push R4
            PUSH  R0                ; push R0
            CLRB  R1
            MOVB  #3,R0             ; three digits
GET3OCT2:   CALL  GETC              ; get the next digit
            CMPB  #ESC,R4           ; is it 'ESC'?
            BEQ   GET3OCT4          ; branch if 'ESC'
            CMPB  #' ',R4           ; is it 'SPACE'?
            BEQ   GET3OCT5          ; branch if 'SPACE'
            CMPB  R4,#'0'           ; else, is the digit less than '0'?
            BCS   GET3OCT2          ; branch if the digit is less than '0'
            CMPB  #3,R0             ; is this the first digit?
            BNE   GET3OCT2A
            CMPB  R4,#'3'+1         ; is the first digit higher than 3?
            BCC   GET3OCT2          ; go back for another character if the first digit is higher than '3'
GET3OCT2A:  CMPB  R4,#'7'+1         ; is the digit higher than '7'?
            BCC   GET3OCT2          ; go back for another character if the digit is higher than '7'
            CALL  PUTC              ; else, echo the digit
            ASL   R1                ; multiply the 'accumulator' by 8
            ASL   R1
            ASL   R1
            SUB   #'0',R4           ; convert the ASCII octal digit to binary
            ADD   R4,R1             ; add the new digit to the 'accumulator'
            DECB  R0                ; decrement the digit count
            BNE   GET3OCT2          ; branch if fewer than three digits have been entered
            POP   R0                ; pop R0            
            POP   R4                ; pop R4            
            CLC                     ; clear carry
            RETURN
            
; 'ESC' branches here            
GET3OCT4:   POP   R0                ; pop R0            
            POP   R4                ; pop R4            
            SEC                     ; set carry
            RETURN
            
; 'SPACE' branches here           
GET3OCT5:   POP   R0                ; pop R0            
            POP   R4                ; pop R4        
            CLC                     ; clear carry
            SEV                     ; set overflow
            RETURN           
            
;-------------------------------------------------------------------
; get two hex digits 00-FF from the console.  leading zeros need not be
; entered. echo valid hex digits. return with carry set if 'ESC'. 
; return with overflow set if 'SPACE'. else return with carry and 
; overflow clear and the byte in R1.
;-------------------------------------------------------------------
GET2HEX:    PUSH  R4                ; push R4
GET2HEX1:   CALL  HEXDIGIT          ; get the first ASCII hex digit into R4
            CMPB  #CR,R4            ; 'ENTER'?
            BEQ   GET2HEX1          ; branch back for another character if 'ENTER'
            CMPB  #ESC,R4           ; 'ESC'?
            BEQ   GET2HEX3          ; branch if 'ESC'
            CMP   #' ',R4
            BEQ   GET2HEX4          ; branch if 'SPACE'
            CALL  ASCII2HEX         ; else, convert to the first digit to binary
            MOVB  R4,R1             ; save the first digit in R1
            CALL  HEXDIGIT          ; get the second ASCII hex digit into R4
            CMPB  #ESC,R4           ; 'ESC'?
            BEQ   GET2HEX4          ; branch if 'SPACE'            
            CMPB  #CR,R4            ; 'ENTER'?
            BEQ   GET2HEX2          ; exit after one digit
            CALL  NEWDIGIT          ; else, add the second digit to R1
GET2HEX2:   POP   R4                ; pop R4            
            CLC                     ; clear carry
            RETURN
            
; 'ESC' branches here          
GET2HEX3:   POP   R4                ; pop R4            
            SEC                     ; set carry
            RETURN
            
; 'SPACE' branches here           
GET2HEX4:   POP   R4                ; pop R4            
            CLC                     ; clear carry
            SEV                     ; set overflow      
            RETURN            

;-------------------------------------------------------------------
; get four hex digits 0000-FFFF from the console. leading zeros need not be
; entered. echo valid hex digits. return with carry set if 'ESC'. 
; return with overflow set if 'SPACE'. else return with carry and 
; overclow clear and the word in R1
;-------------------------------------------------------------------
GET4HEX:    PUSH  R4                ; push R4
GET4HEX1:   CALL  HEXDIGIT          ; get the first ASCII hex digit into R4
            CMP   #CR,R4            ; 'ENTER'?
            BEQ   GET4HEX1          ; go back for another digit if 'ENTER'                    
            CMP   #ESC,R4           ; 'ESC'?
            BEQ   GET4HEX6          ; exit if 'ESC'
            CMP   #' ',R4           ; 'SPACE'?
            BEQ   GET4HEX7          ; exit if 'SPACE'                    
            CALL  ASCII2HEX         ; convert to the first digit to binary
            MOVB  R4,R1             ; save the first digit in R1
GET4HEX2:   CALL  HEXDIGIT          ; get the second ASCII hex digit into R4
            CMP   #ESC,R4           ; 'ESC'?
            BEQ   GET4HEX6          ; exit if 'ESC'
            CMP   #' ',R4           ; 'SPACE'?
            BEQ   GET4HEX2          ; go back for another digit if 'SPACE'                    
            CMPB  #CR,R4            ; 'ENTER'?
            BEQ   GET4HEX5          ; exit after one digit
            CALL  NEWDIGIT          ; else, add the second digit to R1
GET4HEX3:   CALL  HEXDIGIT          ; get the third ASCII hex digit into R4
            CMP   #ESC,R4           ; 'ESC'?
            BEQ   GET4HEX6          ; exit if 'ESC'
            CMP   #' ',R4           ; 'SPACE'?
            BEQ   GET4HEX3          ; branch if 'SPACE'                    
            CMPB  #CR,R4            ; 'ENTER'?
            BEQ   GET4HEX5          ; exit after two digits
            CALL  NEWDIGIT          ; else, add the third digit to R1
GET4HEX4:   CALL  HEXDIGIT          ; get the fourth ASCII hex digit into R4
            CMP   #ESC,R4           ; 'ESC'?
            BEQ   GET4HEX6          ; exit if 'ESC'
            CMP   #' ',R4           ; 'SPACE'?
            BEQ   GET4HEX4          ; go back for another digit if 'SPACE'                    
            CMPB  #CR,R4            ; 'ENTER'?
            BEQ   GET4HEX5          ; exit after three digits
            CALL  NEWDIGIT          ; else, add the fourth digit to R1
GET4HEX5:   POP   R4                ; pop R4
            CLC                     ; clear carry
            RETURN
            
; 'ESC' branches here           
GET4HEX6:   POP   R4                ; pop R4
            SEC                     ; set carry
            RETURN            
            
; 'SPACE' branches here            
GET4HEX7:   POP   R4                ; pop R4
            CLC                     ; clear carry
            SEV                     ; set overflow
            RETURN            
            
; adds new hex digit in R4 to R1
; called by GET2HEX and GET4HEX functions
NEWDIGIT:   CALL  ASCII2HEX         ; convert the hex digit in R4 from ASCII to binary
            ASL   R1                ; shift the digits in R1 left to make room for the new digit in R4
            ASL   R1
            ASL   R1
            ASL   R1
            ADD   R4,R1             ; add the new digit in R4 to R1
            RETURN

; convert the ASCII hex digit 0-9, A-F in R4 to binary
; called by GET2HEX, GET4HEX and NEWDIGIT functions
ASCII2HEX:  SUB   #0x30,R4          ; convert to binary
            CMPB  R4,#0x0A          ; is it A-F?
            BCS   ASCII2HEX1        ; branch if less than 0x0A
            SUB   #0x07,R4          ; else, subtract an additional 0x07 to convert to 0x0A-0x0F
            BICB  #0xF0,R4          ; mask out all but least significant bits
ASCII2HEX1: RETURN

; get an ASCII hex digit 0-9, A-F from the console.
; echo valid hex digits. return the ASCII hex digit in R4.
; called by GET2HEX and GET4HEX functions
HEXDIGIT:   CALL  GETC              ; wait for a character from the console. character returned in R4
            CMPB  #CR,R4            ; is it 'ENTER'?
            BEQ   HEXDIGIT3         ; exit if 'ENTER'
            CMPB  #ESC,R4           ; is it 'ESC'?
            BEQ   HEXDIGIT3         ; exit if 'ESC'
            CMPB  #' ',R4           ; is it 'SPACE'?
            BEQ   HEXDIGIT3         ; exit if 'SPACE'
            CMPB  R4,#'Z'           ; is it upper case?
            BCS   HEXDIGIT1         ; branch if less than 'Z' (already upper case)
            SUB   #0x20,R4          ; else, convert lower to upper case
HEXDIGIT1:  CMPB  R4,#'0'           ; is the digit less than '0'?
            BCS   HEXDIGIT          ; go back for another character if less than '0'
            CMPB  R4,#'F'+1         ; is the digit higher than 'F'?
            BCC   HEXDIGIT          ; go back for another character if higher than 'F'
            CMPB  R4,#'9'+1         ; is the character '9' or lower?
            BCS   HEXDIGIT2         ; continue if character is '9' or below
            CMPB  R4,#'A'           ; is the character below 'A'?
            BCS   HEXDIGIT          ; go back for another if the character is below 'A'
HEXDIGIT2:  CALL  PUTC              ; since it's a legit hex digit, echo the character
HEXDIGIT3:  RETURN
            
;-------------------------------------------------------------------
; print the unsigned word in R1 to the console as five decimal digits.
; leading zeros are suppressed. preserves R1.
;-------------------------------------------------------------------
PRNDECWORD: PUSH  R1                ; push R1
            PUSH  R3                ; push R3
            PUSH  R4                ; push R4
            PUSH  R5                ; push R5
            CLR   R5                ; clear the 'print zero' flag
            MOV   #10000,R3
            CALL  DIGIT             ; print the ten thousands digit
            MOV   #1000,R3
            CALL  DIGIT             ; print the thousands digit
            MOV   #100,R3
            CALL  DIGIT             ; print the hundreds digit
            MOV   #10,R3
            CALL  DIGIT             ; print the tens digit
            ADD   #0x30,R1          ; what remains in R1 is the units digit. convert to ASCII
            MOVB  R1,R4
            CALL  PUTC              ; print the units digit
            POP   R5                ; pop R5
            POP   R4                ; pop R4
            POP   R3                ; pop R3
            POP   R1                ; pop R1
            RETURN

;-------------------------------------------------------------------
; print the unsigned byte in R1 to the console as three decimal digits.
; leading zeros are suppressed. preserves R1.
;-------------------------------------------------------------------
PRNDECBYTE: PUSH  R1                ; push R1
            PUSH  R3                ; push R3
            PUSH  R4                ; push R4
            PUSH  R5                ; push R5
            CLR   R5                ; clear the 'print zero' flag
            MOV   #100,R3
            CALL  DIGIT             ; print the hundreds digit
            MOV   #10,R3
            CALL  DIGIT             ; print the tens digit
            ADD   #0x30,R1          ; what remains in R1 is the units digit. convert to ASCII
            MOVB  R1,R4
            CALL  PUTC              ; print the units digit
            POP   R5                ; pop R5
            POP   R4                ; pop R4
            POP   R3                ; pop R3
            POP   R1                ; pop R1
            RETURN

; count and print the number of times the power of ten in R3 can be subtracted from R1 without underflow
; called by PRNDECWORD and PRNDECBYTE functions
DIGIT:      MOV   #'0'-1,R4         ; R4 is the counter for the digit
DIGIT1:     INCB  R4                ; increment the counter
            SUB   R3,R1             ; subtract power of ten in R3 from the number in R1
            BCC   DIGIT1            ; keep subtracting until there is an underflow
            ADD   R3,R1             ; underflow, now add power of ten in R3 back to the number in R1
            CMPB  #'0',R4           ; is the counter a zero?
            BNE   DIGIT2            ; branch if the counter is not zero
            CMPB  #0xFF,R5          ; else, is the 'print zero' flag set?
            BNE   DIGIT3            ; branch if the 'print zero' flag is not set
DIGIT2:     MOVB  #0xFF,R5          ; set the 'print zero' flag
            CALL  PUTC              ; else, print the tens digit
DIGIT3:     RETURN

;-------------------------------------------------------------------
; print the word in R1 to the console as six octal digits 000000-177777.
; preserves R1.
;-------------------------------------------------------------------
PRNOCTWORD: PUSH  R1                ; push R1
            PUSH  R4                ; push R4
            PUSH  R2                ; push R2
            ROL   R1                ; shift upper bit into carry
            BCC   PRNOCTWORD1
            MOVB  #'1',R4
            BR    PRNOCTWORD2
            
PRNOCTWORD1:MOVB  #'0',R4
PRNOCTWORD2:CALL  PUTC              ; print the most significant digit (always 0 or 1)
            MOVB  #5,R2             ; do 5 more digits, in groups of 3 bits each
PRNOCTWORD3:ROL   R1                ; rotate thru carry
            ROL   R1
            ROL   R1
            ROL   R1
            MOV   R1,R4
            ROR   R1                ; put carry back
            BIC   #0xFFF8,R4        ; mask off all but the lower 3 bits
            ADD   #'0',R4           ; convert to ASCII
            CALL  PUTC
            DECB  R2                ; done all 5 digits yet?
            BNE   PRNOCTWORD3       ; no, continue with next digit
            POP   R2                ; pop R2
            POP   R4                ; pop R4
            POP   R1                ; pop R1            
            RETURN
            
;-------------------------------------------------------------------
; print the byte in R1 to the console as three octal digits 000-377.
; preserves R1.
;-------------------------------------------------------------------            
PRNOCTBYTE: PUSH  R4                ; push R4
            MOV   R1,R4             ; first digit
            ROLB  R4                ; rotate into 3 least significant bits position
            ROLB  R4
            ROLB  R4
            BICB  #0xF8,R4          ; mask out all but 3 least significant bits
            ADD   #'0',R4           ; convert to ASCII
            CALL  PUTC              ; print the first digit
            MOV   R0,R4             ; second digit
            RORB  R4                ; rotate into 3 least significant bits position
            RORB  R4
            RORB  R4
            BIC   #0xF8,R4          ; mask out all but 3 least significant bits
            ADD   #'0',R4           ; convert to ASCII
            CALL  PUTC              ; print the second digit
            MOV   R0,R4             ; third digit
            BIC   #0xF8,R4          ; mask out all but 3 least significant bits
            ADD   #'0',R4           ; convert to ASCII
            CALL  PUTC              ; print the third digit
            POP   R4                ; pop R4
            RETURN
            
;-------------------------------------------------------------------
; print the word in R1 to the console as four ASCII hex digits 0000-FFFF.
; preserves R1.
;-------------------------------------------------------------------
PRINT4HEX:  PUSH  R1                ; push R1
            PUSH  R1                ; push R1 again
            SWAB  R1                ; swap hi and low bytes of R1
            BIC   #0xFF00,R1        ; mask out all but least significant bits
            CALL  PRINT2HEX         ; print the most significant byte of R1 as 2 hex digits
            POP   R1                ; pop original R1
            BIC   #0xFF00,R1        ; mask out all but least significant bits
            CALL  PRINT2HEX         ; print the least significant byte of R1 as 2 hex digits
            POP   R1                ; pop R1
            RETURN

;-------------------------------------------------------------------
; print the word in R1 to the console as four ASCII hex digits with the 'H' suffix: 0000H-FFFFH.
; preserves R1.
;-------------------------------------------------------------------
PRINT4HEXH: CALL  PRINT4HEX
            TYPE  'H'
            RETURN       
            
;-------------------------------------------------------------------
; print the byte in R1 to the console as two ASCII hex digits 00-FF.
; preserves R1.
;-------------------------------------------------------------------
PRINT2HEX:  PUSH  R1                ; push R1
            PUSH  R4                ; push R4
            PUSH  R1                ; push R1 again
            ASRB  R1
            ASRB  R1
            ASRB  R1
            ASRB  R1
            BICB  #0xF0,R1          ; mask out all but least significant bits
            MOVB  R1,R4
            CALL  HEX2ASCII
            CALL  PUTC              ; print the most significant hex digit
            POP   R1                ; pop R1
            BICB  #0xF0,R1          ; mask out all but least significant bits
            MOVB  R1,R4
            CALL  HEX2ASCII
            CALL  PUTC              ; print the least significant hex digit
            POP   R4                ; pop R4
            POP   R1                ; pop R1
            RETURN
            
;-------------------------------------------------------------------
; print the byte in R1 to the console as two ASCII hex digits with the 'H' suffix: 00H-FFH.
; preserves R1.
;-------------------------------------------------------------------            
PRINT2HEXH: CALL  PRINT2HEX
            TYPE  'H'
            RETURN   
            
; convert the nybble in R4 to ASCII hex digit
; called by PRINT2HEX function
HEX2ASCII:  BICB  #0xF0,R4          ; mask out everything except the lower nybble
            CMPB  R4,#10
            BCS   HEX2ASCII1        ; branch if the number in R0 is less than 10
            ADD   #7,R4             ; else, add 7 to convert to 10-15 to A-F
HEX2ASCII1: ADD   #0x30,R4          ; convert binary to ASCII
            RETURN

;-------------------------------------------------------------------
; print the byte in R1 to the console as eight binary digits.
; preserves R1.
;-------------------------------------------------------------------
PRINT8BIN:  PUSH  R1                ; push R1
            PUSH  R0                ; push R0
            PUSH  R4                ; push R4         
            MOVB  #8,R0             ; 8 bits
            
PRINT8BIN1: ASLB  R1
            BCS   PRINT8BIN2
            MOV   #'0',R4
            BR    PRINT8BIN3
PRINT8BIN2: MOV   #'1',R4            
PRINT8BIN3: CALL  PUTC
            DECB  R0
            BNE   PRINT8BIN1        ; do all 8 bits
            
            POP   R4                ; pop R4
            POP   R0                ; pop R0            
            POP   R1                ; pop R1
            RETURN

;-------------------------------------------------------------------
; print carriage return and line feed to the console.
;-------------------------------------------------------------------
CRLF:       PUSH  R4                ; push R4
            MOVB  #CR,R4
            CALL  PUTC
            MOVB  #LF,R4
            CALL  PUTC
            POP   R4                ; pop R4
            RETURN

;-------------------------------------------------------------------
; print 'SPACE' to the console.
;-------------------------------------------------------------------
SPACE:      PUSH   R4                ; push R4
            MOVB  #' ',R4
            CALL  PUTC
            POP   R4                ; pop R4
            RETURN

;-------------------------------------------------------------------
; print 'TAB' to the console.
;-------------------------------------------------------------------
TAB:        PUSH   R4                ; push R4
            MOVB  #0x09,R4
            CALL  PUTC
            POP   R4                ; pop R4
            RETURN

;-------------------------------------------------------------------
; print the character in R4 to the console.
;-------------------------------------------------------------------
PUTC:       BITB  #0x02,@#ACIA      ; test Transmit Data Register Empty bit in the ACIA Status Register
            BEQ   PUTC              ; branch if TDRE is not set
            MOVB  R4,@#ACIA+1       ; else, write the character in R4 to the ACIA's Transmit Data Register
            RETURN

;-------------------------------------------------------------------
; print to the console the zero terminated string whose address is in R5
;-------------------------------------------------------------------
PUTS:       PUSH  R4                ; push R4
PUTS1:      MOVB  (R5)+,R4          ; retrieve the character from the string
            BEQ   PUTS2             ; branch if zero
            CALL  PUTC              ; else, print it
            BR    PUTS1             ; go back for the next character
            
PUTS2:      POP   R4                ; pop R4
            RETURN

;-------------------------------------------------------------------
; wait for a character from the console. return the character in R4.
; if the 'blink' flag is set, flash the orange LED connected to the VIA CB2 pin
; once per seconf while waiting for a character. ^Z toggles the 'blink' flag.
;-------------------------------------------------------------------
GETC:       CMPB  @#INPTR,@#OUTPTR  ; check if there are any characters available
            BEQ   GETC2             ; branch if no characters available
            PUSH  R5                ; else, push R5
            MOVB  @#OUTPTR,R5       ; get the buffer output pointer
            MOVB  BUFF(R5),R4       ; get the next character from the buffer into R4
            INCB  @#OUTPTR          ; update the output pointer
            BICB  #0xF0,@#OUTPTR    ; mask out all but the 4 least significant bits of the pointer
            POP   R5                ; pop R5
            CMPB  #0x1A,R4          ; is the character ^Z? (toggle 'blink' flag)
            BEQ   GETC1             ; branch if ^Z
            RETURN                  ; else, return with the character in R4
            
; branch here if ^Z
GETC1:      COMB  @#BLINK           ; toggle the 'blink' flag
            TSTB  @#BLINK           ; test the 'blink' flag
            BNE   GETC              ; branch if the 'blink' flag is set
            BICB  #0x20,@#PCR       ; else, clear bit 5 of the PCR to turn the orange LED off
            BR    GETC              ; go back for another character

; no characters available. if the 'blink' flag is set, flash the orange LED once per second
; while waiting for a character to necome available
GETC2:      TSTB  @#BLINK           ; test the 'blink' flag
            BEQ   GETC              ; branch if the flag is clear (blinking LED disabled)
            CMPB  @#TICKS,#25       ; else check the tick counter
            BLOS  GETC3             ; branch if the tick counter is 0-25
            BICB  #0x20,@#PCR       ; else, clear bit 5 of the PCR to turn the orange LED off
            BR    GETC
            
GETC3:      BISB  #0x20,@#PCR       ; set bit 5 of the PCR to turn the orange LED on
            BR    GETC            
            
;-------------------------------------------------------------------
; turn on BOLD character attributes
;-------------------------------------------------------------------
BOLDON:     PUSH  R5
            PRINT BOLDONTXT    
            POP   R5
            RETURN

;-------------------------------------------------------------------
; turn off BOLD character attributes
;-------------------------------------------------------------------
BOLDOFF:    PUSH  R5
            PRINT BOLDOFFTXT   
            POP   R5
            RETURN
            
;-------------------------------------------------------------------
; convert the character in R4 to UPPER CASE
;-------------------------------------------------------------------
UPPER:      CMPB  R4,#'a'
            BLO   UPPER1            ; branch if the character in R4 is lower then 'a'
            CMPB  R4,#'z'+1
            BHIS  UPPER1            ; branch if the character in R4 is higher than 'z'
            SUB   #0x20,R4          ; convert from lower to upper case
UPPER1:     RETURN

;-------------------------------------------------------------------
; Disassembler code from Bob Armstrong's 'boots11.asm' for the SBCT11.
;
; This is a fairly capable PDP-11 disassembler.  It knows the mnemonics for
; all the opcodes (or at least all that are known by the DCT11) and it knows
; how to decode all the operand formats.  Register names and addressing modes
; (autoincrement, autodecrement, indexed, deferred, etc) are printed out as
; you'd expect.  Operands are printed in hexadecimal, however relative addressing
; modes (PC relative addressing modes, immediate, absolute, and conditional
; branch instructions,etc) are computed relative to the instruction address
; and the actual target address is printed.  Undefined or illegal opcodes are
; simply printed as 16 bit hexadecimal words.
;
; The address of the instruction to be disassembled is passed in R4.  The
; INSTA entry point first prints the address, a "/" and a tab, and then
; disassembles the instruction.  The INSTW entry point just disassembles the
; instruction without any address.  In either case, R4 will point to the first
; word of the NEXT instruction on return.
;-------------------------------------------------------------------
; type the address first ...
INSTA:      MOV   R4,R1             ; get the instruction address
            CALL	PRINT4HEXH        ; print the address in hex
            CALL  TAB

; fetch the instruction pointed to by R4 ...
INSTW:      MOV   R4,R2             ; get the address of the instruction
            MOV   (R2),R1           ; and get the opcode
            TST   (R4)+             ; bump R4 past the opcode
            MOV   R1,OPCODE         ; save the opcode for future reference

; start decode the instruction in R4
            MOV   OPCODE,R0         ; get the current opcode
            ASL   R0                ; isolate just bits 6 through 11
            ASL   R0                ; ...
            SWAB  R0                ; ...
            BIC   #0xFFC0,R0        ; ...
            MOV   R0,OPMODE         ; store them for later decoding
            PUSH  OPCODE            ; save the original opcode
            TST   OPCODE            ; is this possibly a byte mode instruction?
            BPL   INSTW50           ; branch if it can't be a byte instruction
            BIC   #0x8000,OPCODE    ; try to lookup the opcode w/o the byte mode bit
            CALL  OPSRCH            ; ...
            TSTB  OPTYPE(R3)        ; then see if this opcode allows a byte mode
            BPL   INSTW50           ; nope - not a byte mode

; here for a byte mode (ADDB, MOVB, ASLB, RORB, etc) instruction...
            POP   OPCODE            ; restore the original opcode
            MOV   R3,R1             ; copy the opcode index
            ASL   R1                ; and make index to the name (two RAD50 words!)
            ADD   #OPNAME,R1        ; point to the opcode name
            MOV   (R1),R1           ; and get just the first three letters!
            CALL  R50W              ; type that
            TYPE  'B'               ; then type "B"
            BR    INSTW60           ; and finish decoding the rest

; here for a "word" (i.e. NOT a byte mode) instruction ...
INSTW50:    POP   OPCODE            ; restore the original opcode
            CALL  OPSRCH            ; ... just in case we didn't before
            MOV   R3,R2             ; copy the opcode index
            ASL   R2                ; point to the opcode name
            ADD   #OPNAME,R2        ; ...
            TST   (R2)              ; is the name blank?
            BEQ   INSTW61           ; yes - skip it and the tab
            CALL  R50W2             ; no - type it
            BIT   #0x0F,OPTYPE(R3)  ; is the operand type CCC ?
            BEQ   INSTW61           ; yes - skip the tab
INSTW60:    TYPE  0x09              ; type a tab before the operand
INSTW61:    MOV   OPTYPE(R3),R1     ; get the operand type code
            ASL   R1                ; convert to a word index
            BIC   #0xFFE1,R1        ; ...
            JMP   @OPTBL(R1)        ; type the operands and return

; This little routine searches the OPBASE table for an entry that matches the
; value in OPCODE.  The OPBASE table is sorted in order by ascending binary
; opcode values,and we start searching from the end and work backwards towards
; the beginning.  As soon as we find a table entry that is LESS than the OPCODE,
; we quit.  Note that there's no error return - something will always match!
; The resulting index is returned in R3 ...
OPSRCH:     MOV   #OPBLEN,R3        ; load the table length
OPSRCH10:   CMP   OPCODE,OPBASE(R3) ; compare opcode to base value
            BHIS  OPSRCH20          ; branch if match
            TST   -(R3)             ; nope - bump the index
            BR    OPSRCH10          ; ... and keep looking
OPSRCH20:   RETURN                  ; found it!

; This table gives the address of a routine that knows how to type the operand(s) 
; for this instruction. The index into this table comes from the OPTYPE table 
OPTBL:      WORD OPCCC              ; condition code (CVZN)
            WORD OPINV              ; invalid
            WORD OPNON              ; no operands
            WORD OPTRP              ; EMT and TRAP
            WORD OPDSP              ; 8-bit displacement (branch!)
            WORD OPRDD              ; R,DD
            WORD OPONE              ; SS or DD
            WORD OPTWO              ; SS,DD
            WORD OPREG              ; R
            WORD OPSOB              ; 6-bit negative displacement (SOB!)

; Here if the instruction has no operand - that's easy!
OPNON:     RETURN

; Here for instructions that take only a register name as the first operand
; but then allow a full six bit mode and register for the second operand.  I
; believe the only two examples of this are JSR and XOR ...
OPRDD:      CALL  OPRNM             ; 1st operand is already in OPMODE
            BR    SRDS1             ; type a comma and then the second operand

; Here for an instruction that takes a full six bit mode and register for the
; first (source) operand AND ALSO for the second (destination) operand ...
OPTWO:     CALL  OPSIX              ; 1st operand is already in OPMODE
SRDS1:     TYPE  ','                ; then type a comma
                                    ; ... and fall into OPONE below

; Here for an instruction that takes a full six bit mode and register for the
; destination operand.  The source operand,if any,might be anything and is
; assumed to have already been handled before we get here!
OPONE:      MOVB  OPCODE,OPMODE     ; get the original opcode back again
            BICB  #0xC0,OPMODE      ; and then isolate the destination only
                                    ; fall into OPSIX below and we're done ...

; This routine types a "full" PDP11 SS or DD operand.  It handles all possible
; addressing modes,including the PC ones (immediate,relative and absolute).
; The operand should be passed in OPMODE and R4 points to the next word AFTER
; the original opcode.  If the addressing mode requries fetching any additional
; words,then R4 will be incremented accordingly.
OPSIX:      MOVB  OPMODE,R2         ; get the addressing mode for the operand
            BIT   #0x08,R2          ; deferred?
            BEQ   OPSIX10           ; no
            TYPE  '@'               ; yes - type "@"
OPSIX10:    CMPB  R2,#0x10          ; mode 0 or 1?
            BLO   OPRNM             ; yes,just type the register name
            CMPB  R2,#0x30          ; mode 6 or 7?
            BHIS  OPSIX20           ; yes,indexed
            CMPB  R2,#0x17          ; immediate?
            BEQ   OPSIX30           ; branch if yes
            CMPB  R2,#0x1F          ; or absolute?
            BEQ   OPSIX30           ; yes
            CMPB  R2,#0x20          ; autodecrement?
            BLO   OPSIX40           ; nope
            TYPE  '-'               ; yes - type "-"
OPSIX40:    CALL  OPIDX             ; type the register name in parenthesis
            CMPB  R2,#0x20          ; autoincrement?
            BHIS  OPSIX99           ; nope,we're done
            TYPE  '+'               ; yes - type "+"
OPSIX99:    RETURN                  ; and that's all

; Here for immediate or absolute (the "@" has already been typed!) ...
OPSIX30:    TYPE  '#'               ; type the "#"
OPSIX35:    MOV   R4,R2             ; get the RAM address to read
            MOV   (R2),R1           ; and get the operand from user RAM
            TST   (R4)+             ; bump R4 over the operand
            JMP   @#PRINT4HEXH      ; type the operand and return

; Here for some form of indexed addressing ...
OPSIX20:    CMPB  R2,#0x37          ; is it PC relative?
            BEQ   OPSIX50           ; yes
            CMPB  R2,#0x3F          ; or relative deferred?
            BEQ   OPSIX50           ; yes
            CALL  OPSIX35           ; no - type the next location
            BR    OPIDX             ; and type the register name in parenthesis

; Here for PC relative or relative deferred (the "@" is already typed!) ...
OPSIX50:    MOV   R4,R2             ; read the operand from user RAM
            MOV   (R2),R1           ; ...
            TST   (R4)+             ; bump R4 over the operand
            ADD   R4,R1             ; compute the target address
            JMP   @#PRINT4HEXH      ; type that and return

; Here for the EMT and TRAP instructions. The argument is a single 8 bit value
; without sign extension...
OPTRP:      MOV   OPCODE,R1         ; get the lower 8 bits without sign extension
            BIC   #0xFF00,R1        ; ...
            JMP	@#PRINT4HEXH	   ; type it in hex and we're done

; Here for the SOB instruction.  This one is unique for two reasons - #1 it
; takes a single register as the first argument and,#2 it uses a six bit
; displacement (regular branch instructions use 8) BUT this one is assumed to be
; a backward branch.
OPSOB:      CALL  OPRNM             ; first type the register name
            TYPE  ','               ; and the usual separator
            MOV   OPCODE,R1         ; get the lower 6 bits
            BIC   #0xFFC0,R1        ; ...
            ASL   R1                ; make it a byte displacement
            NEG   R1                ; and it's always a backwards branch
            BR    BRDS1             ; type the target address and we're done

; Here to figure out the target address for all the branch type instructions.
; Get the lower 8 bits of the opcode; sign extend it and add it to the address
; of the instruction to compute the destination.  Note that by the time we get
; here R4,which holds the address of the instruction,has already been
; incremented by 2 just as the PC would have been!
OPDSP:      MOVB  OPCODE,R1         ; get the lower 8 bits with sign extension
            ASL   R1                ; covert word displacement to bytes
BRDS1:      ADD   R4,R1             ; and add in the instruction location
            JMP	@#PRINT4HEXH	   ; type that in hex and we're done

; Here if the opcode takes only a single register as the argument ...
; (I believe RTS is the only instruction that qualifies here!)
OPREG:      MOV   OPCODE,R0         ; get the opcode back
            BR    OPRN1             ; and type the 3 LSBs as a register name

; Type the register from OPMODE as an index register - i.e. (Rn) ...
OPIDX:      TYPE  '('               ; type the left paren
            CALL  OPRNM             ; type the register name
            TYPE  ')'               ; type the closing parens
            RETURN

; Type the register name (R0-R6,SP,or PC) from OPMODE ...
OPRNM:      MOVB  OPMODE,R0         ; get bits 0 through 2
OPRN1:      BIC   #0xFFF8,R0        ; ...
            ASL   R0                ; convert to a REGTAB index
            MOV   REGTAB(R0),R1     ; and get the register name
            JMP   @#R50W            ; type that and we're done

; Type the argument for the CLx or SEx opcodes.  This is one or more of the
; letters C,V,Z,or N.  It might not be obvious (it wasn't to me!) but it's
; possible to combine one or more of these flags in either the SEx or CLx
; instructions.
OPCCC:      MOV   OPCODE,R1         ; get the opcode back again
            ASR   R1                ; is the C bit set?
            BCC   OPCCC1            ; no
            TYPE  'C'               ; yes - type that one
OPCCC1:     ASR   R1                ; and repeat for the V bit ...
            BCC   OPCCC2            ; ...
            TYPE  'V'               ; ...
OPCCC2:     ASR   R1                ; and the Z bit ...
            BCC   OPCCC3            ; ...
            TYPE  'Z'               ; ...
OPCCC3:     ASR   R1                ; and the N bit ...
            BCC   OPCCC4            ; ...
            TYPE  'N'               ; ...
OPCCC4:     RETURN                  ; ...

; Here for opcodes which aren't valid DCT11 instructions.  Just type the
; 16 bit value in hex and give up ...
OPINV:      MOV   OPCODE,R1         ; get the original opcode back again
            JMP   @#PRINT4HEXH      ; type in hex and quit

; Type three RADIX-50 characters packed into R1.  Note that this always
; types three characters, including any trailing spaces...
R50W:       PUSH R2                 ; save R2 for working space
            MOV   #0x28,R2          ; and divisor in R2
            CALL  DIV16             ; divide
            MOV   R0,-(SP)          ; stack the remainder for a moment
            CALL  DIV16             ; divide again
            MOV   R0,-(SP)          ; and save this remainder too
            MOV   R1,R0             ; the last quotient is the first letter
            CALL  R50CH             ; type that
            MOV   (SP)+,R0          ; get the middle character
            BEQ   R50W10            ; trim trailing spaces
            CALL  R50CH             ; type it
R50W10:     MOV   (SP)+,R0          ; and finally the last character
            BEQ   R50W20            ; trim trailing spaces
            CALL  R50CH             ; ...
R50W20:     POP  R2                 ; restore R2 and R1
            RETURN                  ; and we're done

; R50W2 types the six character RADIX-50 word pointed to by R2.  It always
; types exactly two words and no special terminator is needed.
R50W2:      MOV   (R2),R1          ; get the first word
            CALL  R50W              ; type that
            MOV   2(R2),R1         ; and then the next
            BNE   R50W              ; type it only if it's not blank
            RETURN   

; R50CH types the single RADIX-50 character contained in R0.  This uses a
; translation table to convert from RADIX-50 to ASCII.
R50CH:      CMP   R0,#0x28          ; make sure the value is in range
            BLT   R50CH1            ; it is - continue
            CLR   R0                ; nope - print a space instead
R50CH1:     MOVB  R50ASC(R0),R0     ; translate to ASCII
            PUSH  R4
            MOV   R0,R4
            CALL  PUTC              ; and type it
            POP   R4
            RETURN

; 16x16 unsigned divide of R1/R2->R1, remainder in R0 ...
DIV16:      MOV   #17,-(SP)         ; keep a loop counter on the stack
            CLR   R0                ; clear the remainder
            CLC                     ; ... and the first quotient bit
DIV16a:     ROL   R1                ; shift dividend MSB -> C, C -> quotient LSB
            DEC   (SP)              ; decrement the loop counter
            BEQ   DIV16c            ; we're done when it reaches zero
            ROL   R0                ; shift dividend MSB into remainder
            SUB   R2,R0             ; and try to subtract
            BLT   DIV16b            ; if it doesn't fit, then restore
            SEC                     ; it fits - shift a 1 into the quotient
            BR    DIV16a            ; and keep dividing
            
DIV16b:     ADD   R2,R0             ; divisor didn't fit - restore remainder
            CLC                     ; and shift a 0 into the quotient
            BR    DIV16a            ; and keep dividing
            
DIV16c:     TST   (SP)+             ; fix the stack
            RETURN                  ; and we're done
         
; Disassembler Tables

; These tables are used by the disassembler to decode PDP11 instructions.
; There's a table of the binary value for each opcode, a table of the opcode
; names and a table of flags used to decode the instruction's operand(s).

; OPNAME is a table of the opcode names, in RADIX-50...
OPNAME:     WORD 0x3234,0x7D00      ; HALT
            WORD 0x8FF1,0x7D00      ; WAIT
            WORD 0x73A9,0x0000      ; RTI
            WORD 0x0F14,0x0000      ; BPT
            WORD 0x3AAC,0x0000      ; IOT
            WORD 0x715B,0x2260      ; RESET
            WORD 0x73B4,0x0000      ; RTT
            WORD 0x5240,0x7D00      ; MFPT
            WORD 0x4098,0x0000      ; JMP
            WORD 0x73B3,0x0000      ; RTS
            WORD 0x0000,0x0000
            WORD 0x59E8,0x0000      ; NOP
            WORD 0x14A0,0x0000      ; CL
            WORD 0x133B,0x0000      ; CCC
            WORD 0x0000,0x0000
            WORD 0x7788,0x0000      ; SE
            WORD 0x773B,0x0000      ; SCC
            WORD 0x7A59,0x0C80      ; SWAB
            WORD 0x0F50,0x0000      ; BR
            WORD 0x0EB5,0x0000      ; BNE
            WORD 0x0D59,0x0000      ; BEQ
            WORD 0x0D9D,0x0000      ; BGE
            WORD 0x0E74,0x0000      ; BLT
            WORD 0x0DAC,0x0000      ; BGT
            WORD 0x0E65,0x0000      ; BLE
            WORD 0x418A,0x0000      ; JSR
            WORD 0x14B2,0x0000      ; CLR
            WORD 0x1525,0x0000      ; COM
            WORD 0x3A73,0x0000      ; INC
            WORD 0x19CB,0x0000      ; DEC
            WORD 0x584F,0x0000      ; NEG
            WORD 0x06E3,0x0000      ; ADC
            WORD 0x7713,0x0000      ; SBC
            WORD 0x800C,0x0000      ; TST
            WORD 0x72EA,0x0000      ; ROR
            WORD 0x72E4,0x0000      ; ROL
            WORD 0x094A,0x0000      ; ASR
            WORD 0x0944,0x0000      ; ASL
            WORD 0x0000,0x0000
            WORD 0x7A94,0x0000      ; SXT
            WORD 0x0000,0x0000
            WORD 0x53AE,0x0000      ; MOV
            WORD 0x14D8,0x0000      ; CMP
            WORD 0x0DFC,0x0000      ; BIT
            WORD 0x0DEB,0x0000      ; BIC
            WORD 0x0DFB,0x0000      ; BIS
            WORD 0x06E4,0x0000      ; ADD
            WORD 0x0000,0x0000
            WORD 0x986A,0x0000      ; XOR
            WORD 0x0000,0x0000
            WORD 0x791A,0x0000      ; SOB
            WORD 0x0F0C,0x0000      ; BPL
            WORD 0x0E91,0x0000      ; BMI
            WORD 0x0DC9,0x0000      ; BHI
            WORD 0x0E6F,0x76C0      ; BLOS
            WORD 0x0FF3,0x0000      ; BVC
            WORD 0x1003,0x0000      ; BVS
            WORD 0x0CFB,0x0000      ; BCC
            WORD 0x0DC9,0x76C0      ; BHIS
            WORD 0x0D0B,0x0000      ; BCS
            WORD 0x0E6F,0x0000      ; BLO
            WORD 0x215C,0x0000      ; EMT
            WORD 0x7FD1,0x6400      ; TRAP
            WORD 0x0000,0x0000
            WORD 0x5470,0x76C0      ; MTPS
            WORD 0x0000,0x0000
            WORD 0x5240,0x76C0      ; MFPS
            WORD 0x0000,0x0000
            WORD 0x7A0A,0x0000      ; SUB
            WORD 0x0000,0x0000

; OPBASE is a table of the opcode base values (i.e. the bit pattern of this instruction without any operands!)...
OPBASE:     WORD 0x0000             ; HALT
            WORD 0x0001             ; WAIT
            WORD 0x0002             ; RTI
            WORD 0x0003             ; BPT
            WORD 0x0004             ; IOT
            WORD 0x0005             ; RESET
            WORD 0x0006             ; RTT
            WORD 0x0007             ; MFPT
            WORD 0x0040             ; JMP
            WORD 0x0080             ; RTS
            WORD 0x0088
            WORD 0x00A0             ; NOP
            WORD 0x00A1             ; CL
            WORD 0x00AF             ; CCC
            WORD 0x00B0
            WORD 0x00B1             ; SE
            WORD 0x00BF             ; SCC
            WORD 0x00C0             ; SWAB
            WORD 0x0100             ; BR
            WORD 0x0200             ; BNE
            WORD 0x0300             ; BEQ
            WORD 0x0400             ; BGE
            WORD 0x0500             ; BLT
            WORD 0x0600             ; BGT
            WORD 0x0700             ; BLE
            WORD 0x0800             ; JSR
            WORD 0x0A00             ; CLR
            WORD 0x0A40             ; COM
            WORD 0x0A80             ; INC
            WORD 0x0AC0             ; DEC
            WORD 0x0B00             ; NEG
            WORD 0x0B40             ; ADC
            WORD 0x0B80             ; SBC
            WORD 0x0BC0             ; TST
            WORD 0x0C00             ; ROR
            WORD 0x0C40             ; ROL
            WORD 0x0C80             ; ASR
            WORD 0x0CC0             ; ASL
            WORD 0x0D00
            WORD 0x0DC0             ; SXT
            WORD 0x0E00
            WORD 0x1000             ; MOV
            WORD 0x2000             ; CMP
            WORD 0x3000             ; BIT
            WORD 0x4000             ; BIC
            WORD 0x5000             ; BIS
            WORD 0x6000             ; ADD
            WORD 0x7000 
            WORD 0x7800             ; XOR
            WORD 0x7A00
            WORD 0x7E00             ; SOB
            WORD 0x8000             ; BPL
            WORD 0x8100             ; BMI
            WORD 0x8200             ; BHI
            WORD 0x8300             ; BLOS
            WORD 0x8400             ; BVC
            WORD 0x8500             ; BVS
            WORD 0x8600             ; BCC
            WORD 0x8600             ; BHIS
            WORD 0x8700             ; BCS
            WORD 0x8700             ; BLO
            WORD 0x8800             ; EMT
            WORD 0x8900             ; TRAP
            WORD 0x8A00
            WORD 0x8D00             ; MTPS
            WORD 0x8D40
            WORD 0x8DC0             ; MFPS
            WORD 0x8E00
            WORD 0xE000             ; SUB
            WORD 0xF000

OPBLEN      EQU 0x008A

; And OPTYPE is a table of the opcode types and flags...
OPTYPE:     WORD 0x0002             ; HALT
            WORD 0x0002             ; WAIT
            WORD 0x0002             ; RTI
            WORD 0x0002             ; BPT
            WORD 0x0002             ; IOT
            WORD 0x0002             ; RESET
            WORD 0x0002             ; RTT
            WORD 0x0002             ; MFPT
            WORD 0x0006             ; JMP
            WORD 0x0008             ; RTS
            WORD 0x0001
            WORD 0x0002             ; NOP
            WORD 0x0000             ; CL
            WORD 0x0002             ; CCC
            WORD 0x0001
            WORD 0x0000             ; SE
            WORD 0x0002             ; SCC
            WORD 0x0006             ; SWAB
            WORD 0x0004             ; BR
            WORD 0x0004             ; BNE
            WORD 0x0004             ; BEQ
            WORD 0x0004             ; BGE
            WORD 0x0004             ; BLT
            WORD 0x0004             ; BGT
            WORD 0x0004             ; BLE
            WORD 0x0005             ; JSR
            WORD 0x0086             ; CLR
            WORD 0x0086             ; COM
            WORD 0x0086             ; INC
            WORD 0x0086             ; DEC
            WORD 0x0086             ; NEG
            WORD 0x0086             ; ADC
            WORD 0x0086             ; SBC
            WORD 0x0086             ; TST
            WORD 0x0086             ; ROR
            WORD 0x0086             ; ROL
            WORD 0x0086             ; ASR
            WORD 0x0086             ; ASL
            WORD 0x0001
            WORD 0x0006             ; SXT
            WORD 0x0001
            WORD 0x0087             ; MOV
            WORD 0x0087             ; CMP
            WORD 0x0087             ; BIT
            WORD 0x0087             ; BIC
            WORD 0x0087             ; BIS
            WORD 0x0007             ; ADD
            WORD 0x0001
            WORD 0x0005             ; XOR
            WORD 0x0001
            WORD 0x0009             ; SOB
            WORD 0x0004             ; BPL
            WORD 0x0004             ; BMI
            WORD 0x0004             ; BHI
            WORD 0x0004             ; BLOS
            WORD 0x0004             ; BVC
            WORD 0x0004             ; BVS
            WORD 0x0004             ; BCC
            WORD 0x0004             ; BHIS
            WORD 0x0004             ; BCS
            WORD 0x0004             ; BLO
            WORD 0x0003             ; EMT
            WORD 0x0003             ; TRAP
            WORD 0x0001
            WORD 0x0006             ; MTPS
            WORD 0x0001
            WORD 0x0006             ; MFPS
            WORD 0x0001
            WORD 0x0007             ; SUB
            WORD 0x0001

; This is a table of register names in RADIX-50
REGTAB:     WORD 0x7530             ; R0
            WORD 0x7558             ; R1
            WORD 0x7580             ; R2
            WORD 0x75A8             ; R3
            WORD 0x75D0             ; R4
            WORD 0x75F8             ; R5
REGTSP:     WORD 0x7940             ; SP
REGTPC      WORD 0x6478             ; PC
REGTPS:     WORD 0x66F8             ; PS
            WORD 0x0000
         
; RADIX-50 to ASCII lookup table ...
R50ASC:     BYTE   " ABCDEFGHIJKLMNOPQRSTUVWXYZ$.%0123456789"         

;-------------------------------------------------------------------
; code used to test the single-step function
;-------------------------------------------------------------------
STEPTEST    MOV   #STEPTEST1,R1     ; single-step test
            JMP   @#STEP1

STEPTEST1:  MOVB  #0x01,R0
STEPTEST2:  MOVB  R0,@#ORB          ; turn on yellow LEDS
            INCB  R0
            BR    STEPTEST2

;-------------------------------------------------------------------
; code used to test the BPT handler
;-------------------------------------------------------------------
BPTTEST:    BPT
            MOV   #0x0000,R0
            BPT
            MOV   #0x0001,R1
            BPT
            MOV   #0x0002,R2
            BPT
            MOV   #0x0003,R3
            BPT
            MOV   #0x0004,R4
            BPT
            MOV   #0x0005,R5
            BPT
            JMP   @#GETCMD

;-------------------------------------------------------------------
; code used to test the TRAP handler
;-------------------------------------------------------------------
TRAPTEST:   TRAP  0x02
            NOP
            TRAP  0x10
            NOP
            TRAP  0x20
            NOP
            JMP   @#GETCMD
            
;=======================================================================
; Interrupt Service Routine for ACIA RX and VIA Timer 1 interrupts
;=======================================================================
ISR:        BITB  #0x80,@#ACIA      ; test IRQ bit in the ACIA's Status Register
            BEQ   ISR1              ; branch if the ACIA'S IRQ bit is not set
            PUSH  R4                ; else, push R4
            MOVB  @#INPTR,R4        ; retrieve the input buffer pointer
            MOVB  @#ACIA+1,BUFF(R4) ; put the character from the ACIA's Receive Data Register into the buffer
            INCB  @#INPTR           ; increment the pointer
            BIC   #0xF0,@#INPTR     ; mask out all but the 4 least significant bits of the pointer
            POP   R4                ; pop R4

ISR1:       BITB  #0x80,@#IFR       ; test IRQ bit in the VIA's Interrupt Flag Register
            BEQ   ISR3              ; exit if the VIA's IRQ flag is not set
            PUSH  R4                ; else, push R4
            MOVB  @#T1CL,R4         ; read T1CL to clear the Timer 1 interrupt flag
            POP   R4                ; pop R4
            DECB  @#TICKS           ; decrement the tick counter
            BNE   ISR3              ; branch if the tick counter is not zero
            MOVB  #50,@#TICKS       ; else, one second has elapsed. re-initialize the tick counter
            INCB  @#SECS            ; update seconds count
            CMPB  @#SECS,#60
            BNE   ISR3
            CLRB  @#SECS
            INCB  @#MINS            ; update minutes count
            CMPB  @#MINS,#60
            BNE   ISR3
            CLRB  @#MINS
            INCB  @#HRS             ; update hours count
ISR3:       RTI                     ; return from interrupt

;=======================================================================
; jump here on BPT instruction or after single-stepping.
; print the contents of the registers and PS then return to GETCMD.
;=======================================================================
BREAK:      MOV   (SP)+,@#SAVED_PC  ; save PC from before the interrupt
            MOV   (SP)+,@#SAVED_PS  ; save PS from before the interrupt
            MOV   SP,@#SAVED_SP     ; save SP
            MOV   R0,@#SAVED_R0     ; save R0
            MOV   R1,@#SAVED_R1     ; save R1
            MOV   R2,@#SAVED_R2     ; save R2
            MOV   R3,@#SAVED_R3     ; save R3
            MOV   R4,@#SAVED_R4     ; save R4
            MOV   R5,@#SAVED_R5     ; save R5
            
            ; print what was saved from the registers
            CALL  CRLF
            CALL  SHOWREGS0

            ; restore the saved values to the registers
BREAK1:     MOV   @#SAVED_R0,R0     ; restore R0
            MOV   @#SAVED_R1,R1     ; restore R1
            MOV   @#SAVED_R2,R2     ; restore R2
            MOV   @#SAVED_R3,R3     ; restore R3
            MOV   @#SAVED_R4,R4     ; restore R4
            MOV   @#SAVED_R5,R5     ; restore R50
            MOV   @#SAVED_SP,SP     ; restore SP
            BIC   #0x0010,@#SAVED_PS; clear the T bit
            PUSH  SAVED_PS          ; push PS
            PUSH  #GETCMD           ; push PC (return to GETCMD)
            CALL  CRLF               
            CALL  CRLF               
            RTI

;=======================================================================
; jump here on HALT instruction. flash the yellow LEDs to let us know something happened.
;=======================================================================
HALTED:     MOVB  #0xFF,@#DDRB      ; initialize VIA's DDRB to make all Port B pins outputs
            MOVB  #0x00,@#ORB       ; turn off all yellow LEDS connected to Port B pins
            MOVB  #0xCE,@#PCR       ; turn off the orange LED and turn on the red error LED
            MOVB  #0x01,@#ORB       ; light one yellow LED
HALTED1:    MOV   #8096,R0          ; initialize the delay counter            
HALTED2:    SOB   R0,HALTED2        ; delay
            MOVB  @#ORB,R5          ; load Output Register B into R5
            ROLB  R5                ; rotate the bit right
            MOVB  R5,@#ORB          ; load R5 into Output Register B
            BR    HALTED1

;=======================================================================
; jump here on unhandled interrupts. flash the yellow LEDs to let us know something happened.
;=======================================================================
HANG:       MOVB  #0xFF,@#DDRB      ; initialize VIA's DDRB to make all Port B pins outputs
            MOVB  #0x00,@#ORB       ; turn off all yellow LEDS connected to Port B pins
            MOVB  #0xCE,@#PCR       ; turn off the orange LED and turn on the red error LED
HANG0:      MOVB  #0x55,@#ORB       ; light alternate yellow LEDs
            MOV   #16384,R0         ; initialize the delay counter
HANG1:      SOB   R0,HANG1          ; delay
            MOVB  #0xAA,@#ORB       ; flip the yellow LEDs
            MOV   #16382,R0
HANG2:      SOB   R0,HANG2
            BR    HANG0

;=======================================================================
; jump here on TRAP instruction.
;=======================================================================
TRAPPER:    MOV   R0,@#SAVED_R0     ; save R0
            MOV   R1,@#SAVED_R1     ; save R1
            MOV   (SP),R0           ; get the return address from the stack into R0
            SUB   #2,R0             ; subtract 2 to get the address of the TRAP instruction
            MOV   (R0),R1           ; load the actual TRAP instruction into R1
            BIC   #0xFF00,R1        ; mask out the upper byte so that R1 now holds the TRAP instruction parameter (0x00-0xFF)

            ; for now, just print the TRAP instruction operand
            CALL  CRLF
            CALL  PRINT2HEX
            CALL  CRLF

            MOV   @#SAVED_R1,R1      ; restore R1
            MOV   @#SAVED_R0,R0      ; restore R0
            RTT            
            
;-----------------------------------------------------------------------            
; interrupt/TRAP vectors to be copied from EPROM into RAM at 0x0008
;-----------------------------------------------------------------------            
;                 PC       PS        Octal  
VECTORS:    WORD  HANG,    0xE0     ; 010 - Illegal instruction trap
            WORD  BREAK,   0xE0     ; 014 - BPT - Breakpoint Trap
            WORD  HANG,    0xE0     ; 020 - IOT - Input/Output Trap
            WORD  HANG,    0xE0     ; 024 - Power Fail
            WORD  HANG,    0xE0     ; 030 - EMT - Emulator Trap
            WORD  TRAPPER, 0xE0     ; 034 - TRAP
            WORD  0000,    0000 
            WORD  0000,    0000
            WORD  0000,    0000
            WORD  0000,    0000
            WORD  HANG,    0xE0     ; 060 - Int  3, Priority 4
            WORD  HANG,    0xE0     ; 064 - Int  2, Priority 4 - CP1
            WORD  HANG,    0xE0     ; 070 - Int  1, Priority 4 - CP0
            WORD  0000,    0000
            WORD  HANG,    0xE0     ; 100 - Int 13, Priority 6
            WORD  HANG,    0xE0     ; 104 - Int 12, Priority 6
            WORD  HANG,    0xE0     ; 110 - Int 11, Priority 6
            WORD  ISR,     0xE0     ; 114 - Int 10, Priority 6 - CP3: ACIA receive interrupt
            WORD  HANG,    0xE0     ; 120 - Int  7, Priority 5
            WORD  HANG,    0xE0     ; 124 - Int  6, Priority 5
            WORD  HANG,    0xE0     ; 130 - Int  5, Priority 5
            WORD  ISR,     0xE0     ; 134 - Int  4, Priority 5 - CP2: VIA Timer 1 interrupt
            WORD  HANG,    0xE0     ; 140 - Int 17, Priority 7
            WORD  HANG,    0xE0     ; 144 - Int 16, Priority 7
            WORD  HANG,    0xE0     ; 150 - Int 15, Priority 7
            WORD  ISR,     0xE0     ; 154 - Int 14, Priority 7 - CP3 and CP2: ACIA and Timer 1 simultaneously            
            
;-----------------------------------------------------------------------
CLRLINETXT  BYTE  CLRLINE,0
BUILTBYTXT  BYTE  "DEC T-11 SBC Built by Jim Loos\r\n",0
BANNERTXT   BYTE  CLS,"T-11 SBC Serial Monitor\r\n"
            BYTE  "Assembled on ",DATE," at ",TIME,"\r\n",0
MENUTXT     BYTE  "B - resume after Breakpoint\r\n"
            BYTE  "C - Call subroutine\r\n"
            BYTE  "D - Dump a page of memory\r\n"
            BYTE  "F - Fill block of RAM\r\n"
            BYTE  "H - Intel Hex file download\r\n"
            BYTE  "I - display Instructions (disassemble)\r\n"
            BYTE  "J - Jump to address\r\n"            
            BYTE  "M - Modify RAM contents\r\n"
            BYTE  "N - single-step Next instruction\r\n"            
            BYTE  "R - modify Registers\r\n"
            BYTE  "S - Single-step\r\n"            
            BYTE  "U - print Uptime\r\n",0
PROMPTTXT   BYTE  "\r\n>>",0
DISASSEMTXT BYTE  "Disassemble from address: ",0
DUMP1TXT    BYTE  "Dump memory at address: ",0
DUMP2TXT    BYTE  "\n\n\n\n\n      ",SGR1,"00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F\r\n",SGR0,0
DUMP3TXT    BYTE  "'+' for next page, '-' for previous page. Any other key to exit...",0
NEXTTXT     BYTE  "SPACE for next page. Any other key to exit...",0
MODIFYTXT   BYTE  "Examine/Modify memory at address: ",0
UPTIMETXT   BYTE  "Uptime: ",0
ARROWTXT    BYTE  " --> ",0
FILLTXT     BYTE  "Fill memory block at address: ",0
COUNTTXT    BYTE  "Count: (in HEX) ",0
VALUETXT    BYTE  "Value: (in HEX) ",0
JUMPTXT     BYTE  "Jump to address: ",0
CALLTXT     BYTE  "Call subroutine at address: ",0
HEXDLTXT    BYTE  "Waiting for hex download...",0
DLCNTTXT:   BYTE  " bytes downloaded\r\n",0
CKSERRTXT   BYTE  " checksum errors!\r\n",0
NOERRTXT    BYTE  "No checksum errors\r\n",0
STEPTXT     BYTE  "Single step at address: ",0
NXTINSTXT   BYTE  "SPACE for next instruction. Any other key to exit...",0
REGTXT      BYTE  "Registers:\r\n\n",0
SPTXT       BYTE  "SP=",0
PCTXT       BYTE  "PC=",0
PSWTXT      BYTE  "PS=",0
BOLDONTXT   BYTE  SGR1,0
BOLDOFFTXT  BYTE  SGR0,0

           ;BYTE 0xF000-* DUP (0)         ; fill the empty space with zeros  
            
            END