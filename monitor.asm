            PAGE 0                           ; suppress page headings in ASW listing file

            cpu T-11                         ; DEC DC310

;*********************************************************************************************************************************
; Serial Monitor for T-11 Single Board Computer
;---------------------------------------------------------------------------------------------------------------------------------
; Copyright 2025 Jim Loos
;
; Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files
; (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge,
; publish, distribute, sub-license, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do
; so, subject to the following conditions:
;
; The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
;
; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
; OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
; LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
; IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
;---------------------------------------------------------------------------------------------------------------------------------
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
; Monitor Commands:  D - Dump the contents of a page of memory in hex and ASCII
;                    F - Fill a block of RAM
;                    M - Modify RAM contents
;                    R - modify Register contents
;                    H - Intel Hex file download
;                    U - print the Uptime
;                    C - Call a subroutine
;                    J - Jump to address
;                    S - Single-step
;                    N - single-step Next instruction
;                    B - resume code execution after Breakpoint
;
; Thanks to Peter McCollum for his help with both hardware and software.
;
; "Octal? We ain't got no octal! We don't need no octal! I don't have to show you any stinkin' octal!"
;
;*********************************************************************************************************************************

CR          EQU   0x0D
LF          EQU   0x0A
ESC         EQU   0x1B
CLS         EQU   "\e[2J\e[H"       ; VT100 escape sequence to to clear screen and home cursor
LOOPCNT     EQU   8192              ; used by flashing yellow LEDs, lower value makes LEDs flash faster

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

; stack starts at the top of RAM and grows down
STACK       EQU   0x7FFE

; variables are stored starting at the bottom of RAM page 0x7E and work up
BUFF        EQU   0x7E00            ; 16 byte serial input buffer
INPTR       EQU   0x7E10            ; buffer input pointer
OUTPTR      EQU   0x7E11            ; buffer output pointer
COUNT       EQU   0x7E12            ; word for flashing yellow LEDs - must be an even address
BLINK       EQU   0x7E14            ; blink orange LED flag
TICKS       EQU   0x7E15            ; timer interrupt ticks counter
SECS        EQU   0x7E16            ; uptime seconds count
MINS        EQU   0x7E17            ; uptime minutes count
HRS         EQU   0x7E18            ; uptime hours count
LASTSECS    EQU   0x7E19            ; seconds count last time thru the loop
DLCOUNT     EQU   0x7E1A            ; word for number of bytes downloaded - must be an even address

SAVEDR0     EQU   0x7F00            ; registers and PS are saved in RAM here. 
SAVEDR1     EQU   0x7F02
SAVEDR2     EQU   0x7F04
SAVEDR3     EQU   0x7F06
SAVEDR4     EQU   0x7F08
SAVEDR5     EQU   0x7F0A
SAVEDR6     EQU   0x7F0C
SAVEDR7     EQU   0x7F0E
SAVEDPS     EQU   0x7F10

; power-on-reset jumps here
            ORG   0x8000
            JMP   @#COLD

; HALT instruction jumps here
            ORG   0x8004
            JMP   @#HALTED
            
; cold start initialization starts here
COLD:       MOV   #VECTORS,R0       ; address of the VECTORS table
            MOV   #0x0008,R1        ; destination address in RAM for VECTORS
            MOVB  #52,R2            ; number of words to copy
            
; copy the VECTORS table to RAM
COLD1:      MOV   (R0)+,(R1)+  
            DECB  R2
            BNE   COLD1
            
            MOV   #STACK,SP         ; initialize SP
            MOV   #LOOPCNT,@#COUNT  ; initialize loop counter
            MOVB  #50,@#TICKS       ; initialize tick counter
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
            MOVB  #0x00,@#T1CL
            MOVB  #0xC0,@#T1CH      ; divide 2.4576 MHz clk by 49152 to interrupt 50 times per second
            MOVB  #0x40,@#ACR       ; continuous interrupts, disable PB7 square wave output
           ;MOVB  #0xC0,@#ACR       ; continuous interrupts, enable PB7 square wave output
            MOVB  #0xC0,@#IER       ; set the interrupt enable flag for Timer 1

            ; global interrupt enable
            MTPS  #0x80             ; set priority bits in PS to enable interrupts priority 5 and above

            MOV   #BANNERTXT,R5     ; print the banner
            JSR   PC,@#PUTS

PRINTMENU:  MOV   #MENUTXT,R5        ; print the menu
            JSR   PC,@#PUTS            

; loop here waiting for commands from the console...
MONITOR:    MOV   #PROMPTTXT,R5     ; print the prompt
            JSR   PC,@#PUTS
            JSR   PC,@#GETC         ; get a character from the console
            JSR   PC,@#UPPER        ; convert the character to upper case

MONITOR1:   CMPB  #'D',R4
            BNE   MONITOR2
            JSR   PC,@#DUMP         ; dump a page of memory
            BR    MONITOR

MONITOR2:   CMPB  #'M',R4
            BNE   MONITOR3
            JSR   PC,@#MODIFY       ; examine/modify memory
            BR    MONITOR

MONITOR3:   CMPB  #'U',R4
            BNE   MONITOR4
            JSR   PC,@#PRINTTIME    ; print the uptime
            BR    MONITOR
            
MONITOR4:   CMPB  #'F',R4
            BNE   MONITOR5
            JSR   PC,@#FILL         ; fill memory
            BR    MONITOR

MONITOR5:   CMPB  #'R',R4
            BNE   MONITOR6
            JSR   PC,@#REGISTERS    ; modify registers
            BR    MONITOR            

MONITOR6:   CMPB  #'H',R4
            BNE   MONITOR7
            JSR   PC,@#HEXDL        ; hex file download
            BR    MONITOR

MONITOR7:   CMPB  #':',R4
            BNE   MONITOR8
            JSR   PC,@#HEXDL        ; hex file download
            BR    MONITOR

MONITOR8:   CMPB  #'C',R4
            BNE   MONITOR9
            JSR   PC,@#CALLSUB      ; call a subroutine
            BR    MONITOR

MONITOR9:   CMPB  #'S',R4
            BNE   MONITOR10
            JSR   PC,@#STEP         ; single step
            BR    MONITOR

MONITOR10:  CMPB  #'N',R4
            BNE   MONITOR11
            JSR   PC,@#NEXT         ; single step next instruction
            BR    MONITOR

MONITOR11:  CMPB  #'B',R4
            BNE   MONITOR12
            JMP   @#RESUME          ; resume execution after breakpoint

MONITOR12:  CMPB  #'J',R4
            BNE   MONITOR99
            JMP   @#JUMP            ; jump to an address

MONITOR99:  JSR   PC,@#CRLF
            BR    PRINTMENU         ; go back for another command

;=======================================================================
; examine/modify register. for registers R0-R5: display current register value,
; pause to allow entry (in hex) of new register value. 'SPACE' skips the current
; register and increments to the next register. 'ESC' exits.
;=======================================================================
REGISTERS:  MOV   R0,@#SAVEDR0      ; save the contents of R0
            MOV   R1,@#SAVEDR1      ; save the contents of R1
            MOV   R2,@#SAVEDR2      ; save the contents of R2
            MOV   R3,@#SAVEDR3      ; save the contents of R3
            MOV   R4,@#SAVEDR4      ; save the contents of R4
            MOV   R5,@#SAVEDR5      ; save the contents of R5
            
            MOV   #REGTXT,R5
            JSR   PC,@#PUTS
            MOV   #SAVEDR0,R0       ; R0 now points to the memory location where R0 was saved
            MOVB  #'0',R3
REGISTERS1: JSR   PC,@#CRLF
            MOVB  #'R',R4
            JSR   PC,@#PUTC         ; print 'R'
            MOVB  R3,R4
            JSR   PC,@#PUTC         ; print the register number
            MOV   #ARROWTXT,R5      
            JSR   PC,@#PUTS         ; print '-->'
            MOV   (R0),R1           ; get the saved register contents
            JSR   PC,@#PRINT4HEX    ; print the contents
            JSR   PC,@#SPACE
            JSR   PC,@#GET4HEX      ; get the new value for the register
            BCS   REGISTERS3        ; branch if 'ESC'
            BVC   REGISTERS2        ; branch if not 'SPACE'
            MOV   (R0),R1           ; if 'SPACE' use the saved register contents unaltered
            JSR   PC,@#PRINT4HEX    ; print it
REGISTERS2: MOV   R1,(R0)           ; update memory
            INC   R0                ; point to the next memory location
            INC   R0
            INCB  R3
            CMPB  #'6',R3
            BNE   REGISTERS1        ; loop through registers '0'-'5'

            ; update the registers
            MOV   @#SAVEDR0,R0      ; update R0 with new value
            MOV   @#SAVEDR1,R1      ; update R1 with new value
            MOV   @#SAVEDR2,R2      ; update R2 with new value
            MOV   @#SAVEDR3,R3      ; update R3 with new value
            MOV   @#SAVEDR4,R4      ; update R4 with new value
            MOV   @#SAVEDR5,R5      ; update R5 with new value
REGISTERS3: JSR   PC,@#CRLF
            JSR   PC,@#CRLF
            RTS   PC
            
;=======================================================================
; single step. execute one instruction, return to monitor and display
; registers and PS.
;=======================================================================
STEP:       MOV   #STEPTXT,R5
            JSR   PC,@#PUTS         ; prompt for address
            JSR   PC,@#GET4HEX      ; get the starting memory address into R1
            BCS   STEP1             ; 'ESC' key cancels
            BVS   STEP1             ; 'SPACE' exits
            MFPS  R0                ; retrieve PS into R0
            BIS   #0x0010,R0        ; set T bit
            MOV   R0,-(SP)          ; push R0 as though it were PS
            MOV   R1,-(SP)          ; push R1 as though it were PC
            RTT                     ; simulate return from TRAP

STEP1:      JSR   PC,@#CRLF
            JSR   PC,@#CRLF
            RTS   PC

;=======================================================================
; single step - execute the next instruction
;=======================================================================
NEXT:       MOV   @#SAVEDR0,R0      ; restore R0 with its original value
            MOV   @#SAVEDR1,R1      ; restore R1 with its original value
            MOV   @#SAVEDR2,R2      ; restore R2 with its original value
            MOV   @#SAVEDR3,R3      ; restore R3 with its original value
            MOV   @#SAVEDR4,R4      ; restore R4 with its original value
            MOV   @#SAVEDR5,R5      ; restore R5 with its original value
            MOV   @#SAVEDR6,SP      ; restore SP with its original value
            BIS   #0x0010,@#SAVEDPS ; set the T bit
            MOV   @#SAVEDPS,-(SP)   ; push PS
            MOV   @#SAVEDR7,-(SP)   ; push PC
            RTT

;=======================================================================
; execute next instruction after breakpoint
;=======================================================================
RESUME:     MOV   @#SAVEDR0,R0      ; restore R0 with its original value
            MOV   @#SAVEDR1,R1      ; restore R1 with its original value
            MOV   @#SAVEDR2,R2      ; restore R2 with its original value
            MOV   @#SAVEDR3,R3      ; restore R3 with its original value
            MOV   @#SAVEDR4,R4      ; restore R4 with its original value
            MOV   @#SAVEDR5,R5      ; restore R5 with its original value
            MOV   @#SAVEDR6,SP      ; restore SP with its original value
            BIC   #0x0010,@#SAVEDPS ; clear the T bit
            MOV   @#SAVEDPS,-(SP)   ; push PS
            MOV   @#SAVEDR7,-(SP)   ; push PC
            RTT

;=======================================================================
; dump one page of memory in hex and ASCII
;=======================================================================
DUMP:       MOV   #DUMP1TXT,R5
            JSR   PC,@#PUTS         ; prompt for address
            JSR   PC,@#GET4HEX      ; get the starting memory address into R1
            BCS   DUMP7             ; 'ESC' key cancels
            BVS   DUMP7             ; 'SPACE' exits
            BIC   #0x00FF,R1        ; mask out the least significant bits of the starting address
DUMP0:      JSR   PC,@#CRLF
            MOV   #DUMP2TXT,R5
            JSR   PC,@#PUTS
            MOVB  #16,R5            ; 16 lines per page            
DUMP1:      JSR   PC,@#PRINT4HEX    ; print the starting address
            JSR   PC,@#TAB
            MOVB  #16,R3            ; 16 bytes per line
DUMP2:      MOVB  (R1)+,R0          ; load the byte into R1
            JSR   PC,@#PRINT2HEX    ; print the byte
            JSR   PC,@#SPACE
            DECB  R3                ; decrement the byte counter
            BNE   DUMP2             ; loop until 16 bytes have been printed
            JSR   PC,@#SPACE
            SUB   #16,R1            ; reset the address back to the start of the line
            MOVB  #16,R3            ; re-load the byte counter
DUMP3:      MOVB  (R1)+,R4          ; load the character from memory into R4
            CMPB  R4,#0x20
            BHIS  DUMP4             ; branch if is above 0x20
            MOVB  #'.',R4           ; else substitute '.' for an unprintable character
            BR    DUMP5
DUMP4:      CMPB  R4,#0x7F
            BLO   DUMP5             ; branch if below 0x7F
            MOVB  #'.',R4           ; else substitute '.' for an unprintable character
DUMP5:      JSR   PC,@#PUTC         ; print the character
            DECB  R3                ; decrement the byte counter
            BNE   DUMP3             ; loop until 16 characters have been printed
            JSR   PC,@#CRLF         ; new line
            DECB  R5                ; decrement the line counter
            BNE   DUMP1             ; loop until 16 lines have been printed
DUMP6:      JSR   PC,@#CRLF         ; new line
            MOV   #NEXTTXT,R5
            JSR   PC,@#PUTS         ; prompt for input
            JSR   PC,@#GETC         ; wait for a key
            JSR   PC,@#CRLF         ; new line
            CMPB  #' ',R4           ; is it 'SPACE'?
            BEQ   DUMP0             ; branch to display next page of memory
DUMP7:      JSR   PC,@#CRLF         ; else, exit
            RTS   PC

;=======================================================================
; examine/modify memory contents. display the current contents of the memory
; location. pause to allow entry (in hex) of a new value. 'SPACE' skips the
; current memory location and increments to the next memory location. 'ESC' exits.
;=======================================================================
MODIFY:     MOV   #MODIFYTXT,R5
            JSR   PC,@#PUTS         ; prompt for address
            JSR   PC,@#GET4HEX      ; get the starting memory address into R1
            BCS   MODIFY3           ; 'ESC' key exits
            BVS   MODIFY3           ; 'SPACE' exits
            JSR   PC,@#CRLF
MODIFY1:    JSR   PC,@#CRLF         ; new line
            JSR   PC,@#PRINT4HEX    ; print the memory address
            MOV   R1,R2             ; save the memory address in R2
            MOV   #ARROWTXT,R5
            JSR   PC,@#PUTS         ; print '-->'
            MOVB  (R2),R0           ; get the byte from memory addressed by R2 into R0
            JSR   PC,@#PRINT2HEX    ; print the data byte
            JSR   PC,@#SPACE
            JSR   PC,@#GET2HEX      ; get the new memory value into R1
            BCS   MODIFY3           ; branch if 'ESC'
            BVC   MODIFY2           ; branch if not 'SPACE'
            JSR   PC,@#PRINT2HEX    ; else, print the present byte 
            MOVB  R0,R1             ; skip the update, use existing byte
MODIFY2:    MOVB  R1,(R2)           ; store the new value in R1 at the address R2
            INC   R2                ; next memory address
            MOV   R2,R1
            BR    MODIFY1
MODIFY3:    JSR   PC,@#CRLF
            JSR   PC,@#CRLF
            RTS   PC

;=======================================================================
; print the uptime as HH:MM:SS
;=======================================================================
PRINTTIME:  MOV   #UPTIMETXT,R5
            JSR   PC,@#PUTS
            MOV   #0xFF,R5          ; do NOT suppress leading zeros
            MOVB  @#HRS,R1
            MOV   #10,R3
            JSR   PC,@#DIGIT        ; print the hours tens digit
            ADD   #0x30,R1
            MOVB  R1,R4
            JSR   PC,@#PUTC         ; print the hours units digit
            MOVB  #':',R4
            JSR   PC,@#PUTC         ; print the ':' separator
            MOVB  @#MINS,R1
            MOV   #10,R3
            JSR   PC,@#DIGIT        ; print the minutes tens digit
            ADD   #0x30,R1
            MOVB  R1,R4
            JSR   PC,@#PUTC         ; print the minutes units digit
            MOVB  #':',R4
            JSR   PC,@#PUTC         ; print the ':' separator
            MOVB  @#SECS,R1
            MOV   #10,R3
            JSR   PC,@#DIGIT        ; print the seconds tens digit
            ADD   #0x30,R1
            MOVB  R1,R4
            JSR   PC,@#PUTC         ; print the seconds units digit
            JSR   PC,@#CRLF
            JSR   PC,@#CRLF
            RTS   PC

;=======================================================================
; fill a block of memory with a byte. prompt for entry (in hex) of starting
; address, byte count and fill byte.
;=======================================================================
FILL:       MOV   #FILLTXT,R5
            JSR   PC,@#PUTS         ; prompt for address
            JSR   PC,@#GET4HEX      ; get the memory address into R1
            BCS   FILL3             ; 'ESC' key exits
            BVS   FILL3             ; 'SPACE' exits
            MOV   R1,R2             ; save the address in R2
            JSR   PC,@#CRLF         ; new line
            MOV   #COUNTTXT,R5
            JSR   PC,@#PUTS         ; prompt for the byte count
            JSR   PC,@#GET4HEX      ; get the byte count into R1
            BCS   FILL3             ; 'ESC' key exits
            BVS   FILL3             ; 'SPACE' exits
            MOV   R1,R3             ; save the byte count in R3
            JSR   PC,@#CRLF         ; new line
            MOV   #VALUETXT,R5
            JSR   PC,@#PUTS         ; prompt for the byte to fill memory
            JSR   PC,@#GET2HEX      ; get the fill byte into R1
            BCS   FILL3             ; 'ESC' key exits
            BVS   FILL3             ; 'SPACE' exits
            MOVB  R1,R4             ; save the fill value in R4
FILL2:      MOVB  R4,(R2)+          ; store the value (in R4) at the address in R2
            DEC   R3                ; decrement the byte count
            BNE   FILL2             ; loop back until the byte count is zero
FILL3:      JSR   PC,@#CRLF         ; new line
            JSR   PC,@#CRLF         ; another new line
            RTS   PC

;=======================================================================
; jump to an address
;=======================================================================
JUMP:       MOV   #JUMPTXT,R5
            JSR   PC,@#PUTS         ; prompt for memory address
            JSR   PC,@#GET4HEX      ; get the memory address into R1
            BCS   JUMP1             ; 'ESC' key exits
            BVS   JUMP1             ; 'SPACE' exits
            JSR   PC,@#CRLF
            BIC   0x0001,R1         ; must be an even address
            JMP   (R1)              ; jump to the address now in R1

JUMP1:      JSR   PC,@#CRLF
            JSR   PC,@#CRLF
            JMP   @#MONITOR
            
;=======================================================================
; call a subroutine
;=======================================================================
CALLSUB:    MOV   #CALLTXT,R5
            JSR   PC,@#PUTS         ; prompt for address
            JSR   PC,@#GET4HEX      ; get the subroutine address into R1
            BCS   CALLSUB1          ; 'ESC' key exits
            BVS   CALLSUB1          ; 'SPACE' exits
            BIC   0x0001,R1         ; must be an even address
            JSR   PC,(R1)           ; call the subroutine whose address is now in R1
CALLSUB1:   JSR   PC,@#CRLF
            JSR   PC,@#CRLF
            RTS   PC

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
            CLRB  @#DLCOUNT         ; clear the counter
            CMP   #':',R4           ; has the start of record character already been received?
            BEQ   HEXDL3            ; if so, skip the prompt
            MOV   #HEXDLTXT,R5
            JSR   PC,@#PUTS         ; else, prompt for hex download
HEXDL1:     JSR   PC,@#GETC         ; get the first character of the record
            CMPB  #ESC,R4
            BEQ   HEXDL8            ; 'ESC' exits
HEXDL2:     CMP   #':',R4           ; start of record character?
            BNE   HEXDL1            ; if not, go back for another character

; start of record character ':' received...
HEXDL3:     JSR   PC,@#CRLF
            MOVB  #':',R4
            JSR   PC,@#PUTC         ; print the ':' start of record character
            JSR   PC,@#GET2HEX      ; get the record's byte count
            MOVB  R1,R2             ; save the byte count in R2
            MOVB  R1,R0             ; save the byte count as the checksum
            JSR   PC,@#GET4HEX      ; get the record's address
            MOV   R1,R5             ; save the address in R5
            SWAB  R1
            ADD   R1,R0             ; add the address high byte to the checksum
            SWAB  R1
            ADD   R1,R0             ; add the address low byte to the checksum
            JSR   PC,@#GET2HEX      ; get the record type
            ADD   R1,R0             ; add the record type to the checksum
            CMP   #0x01,R1          ; is this record the end of file?
            BEQ   HEXDL5            ; branch if end of file record
HEXDL4:     JSR   PC,@#GET2HEX      ; get a data byte
            ADD   R1,R0             ; add the data byte to the checksum
            MOVB  R1,(R5)+          ; store the data byte in memory
            INC   @#DLCOUNT
            DECB  R2                ; decrement the byte count
            BNE   HEXDL4            ; if not zero, go back for another data byte

; Since the record's checksum byte is the two's complement and therefore the additive inverse
; of the data checksum, the verification process can be reduced to summing all decoded byte
; values, including the record's checksum, and verifying that the LSB of the sum is zero.
            JSR   PC,@#GET2HEX      ; else, get the record's checksum
            ADD   R1,R0             ; add the record's checksum to the computed checksum
            CMPB  #0x00,R0
            BEQ   HEXDL1            ; no errors, go back for the next record
            INCB  R3                ; else, increment the error count
            BR    HEXDL1            ; go back for the next record

; end of file record
HEXDL5:     JSR   PC,@#GET2HEX      ; get the last record's checksum
            JSR   PC,@#GETC         ; get the CR at the end of the last record
            JSR   PC,@#CRLF
            MOV   @#DLCOUNT,R1
            JSR   PC,@#PRINTWDEC
            MOV   #DLCNTTXT,R5
            JSR   PC,@#PUTS
            TSTB  R3
            BNE   HEXDL6            ; branch if there are checksum errors
            MOV   #NOERRTXT,R5      ; else, print "no checksum errors"
            BR    HEXDL7
HEXDL6:     MOVB  R3,R1
            JSR   PC,@#PRINTBDEC    ; print the number if checksum errors
            MOV   #CKSERRTXT,R5
HEXDL7:     JSR   PC,@#PUTS
HEXDL8:     JSR   PC,@#CRLF
            RTS   PC

;-------------------------------------------------------------------
; get up to a maximum of five decimal digits from the console (or
; until terminated with 'ENTER' or 'ESC'). returns with the
; unsigned binary number in R1 and the last digit in R4.
; CAUTION: no error checking for numbers greater than 65535!
;-------------------------------------------------------------------
GETDEC:     MOV   R2,-(SP)          ; push R2
            MOV   R5,-(SP)          ; push R5
            CLR   R1                ; start with zero
            MOVB  #5,R2             ; R2 is the digit counter
GETDEC1:    JSR   PC,@#GETC         ; wait for input from the console
            CMPB  #CR,R4            ; is it 'ENTER'?
            BEQ   GETDEC2           ; branch if 'ENTER'
            CMPB  #ESC,R4           ; is it 'ESC'?
            BEQ   GETDEC2           ; branch if 'ESC'
            CMPB  R4,#'0'           ; else, is the digit less than '0'?
            BCS   GETDEC1           ; branch if R4 is less than '0'
            CMPB  R4,#'9'+1         ; is the digit higher than '9'?
            BCC   GETDEC1           ; go back for another character if higher than '9'
            JSR   PC,@#PUTC         ; since it's a legit decimal digit, echo the digit
            SUB   #0x30,R4          ; convert the ASCII digit in R4 to binary
            MOV   R1,R5             ; copy R1 to R5
            ADD   R1,R1             ; double R1 (effectively multiplying R1 by 2)
            ADD   R1,R1             ; double R1 again (effectively multiplying R1 by 4)
            ADD   R5,R1             ; add in original value (effectively multiplying R1 by 5)
            ADD   R1,R1             ; double R3 again. (effectively multiplying R1 by 10)
            ADD   R4,R1             ; finally add in the last digit entered
            DECB  R2                ; decrement the digit count
            BNE   GETDEC1           ; go back for the next decimal digit if fewer than 5 digits entered
GETDEC2:    MOV   (SP)+,R5          ; pop R5
            MOV   (SP)+,R2          ; pop R2
            RTS   PC

;-------------------------------------------------------------------
; print the unsigned word in R1 as five decimal digits.
; leading zeros are suppressed.
; preserves the word in R1.
;-------------------------------------------------------------------
PRINTWDEC:  MOV   R1,-(SP)          ; push R1
            MOV   R3,-(SP)          ; push R3
            MOV   R4,-(SP)          ; push R4
            MOV   R5,-(SP)          ; push R5
            CLR   R5                ; clear the 'print zero' flag
            MOV   #10000,R3
            JSR   PC,@#DIGIT        ; print the ten thousands digit
            MOV   #1000,R3
            JSR   PC,@#DIGIT        ; print the thousands digit
            MOV   #100,R3
            JSR   PC,@#DIGIT        ; print the hundreds digit
            MOV   #10,R3
            JSR   PC,@#DIGIT        ; print the tens digit
            ADD   #0x30,R1          ; what remains in R1 is the units digit. convert to ASCII
            MOVB  R1,R4
            JSR   PC,@#PUTC         ; print the units digit
            MOV   (SP)+,R5          ; pop R5
            MOV   (SP)+,R4          ; pop R4
            MOV   (SP)+,R3          ; pop R3
            MOV   (SP)+,R1          ; pop R1
            RTS   PC

;-------------------------------------------------------------------
; print the unsigned byte in R1 as three decimal digits.
; leading zeros are suppressed.
; preserves the byte in R1.
;-------------------------------------------------------------------
PRINTBDEC:  MOV   R1,-(SP)          ; push R1
            MOV   R3,-(SP)          ; push R3
            MOV   R4,-(SP)          ; push R4
            MOV   R5,-(SP)          ; push R5
            CLR   R5                ; clear the 'print zero' flag
            MOV   #100,R3
            JSR   PC,@#DIGIT        ; print the hundreds digit
            MOV   #10,R3
            JSR   PC,@#DIGIT        ; print the tens digit
            ADD   #0x30,R1          ; what remains in R1 is the units digit. convert to ASCII
            MOVB  R1,R4
            JSR   PC,@#PUTC         ; print the units digit
            MOV   (SP)+,R5          ; pop R5
            MOV   (SP)+,R4          ; pop R4
            MOV   (SP)+,R3          ; pop R3
            MOV   (SP)+,R1          ; pop R1
            RTS   PC

; count and print the number of times the power of ten in R3 can be subtracted from R1 without underflow
; called by PRINTWDEC and PRINTBDEC functions
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
            JSR   PC,@#PUTC         ; else, print the tens digit
DIGIT3:     RTS   PC

;-------------------------------------------------------------------
; print the word in R1 as four ASCII hex digits
; preserves the word in R1.
;-------------------------------------------------------------------
PRINT4HEX:  MOV   R0,-(SP)          ; push R0
            MOV   R1,-(SP)          ; push R1
            MOV   R1,-(SP)          ; push R1 again
            SWAB  R1                ; swap hi and low bytes of R1
            BIC   #0xFF00,R1        ; mask out all but least significant bits
            MOVB  R1,R0
            JSR   PC,@#PRINT2HEX    ; print the most significant byte of R1 as 2 hex digits
            MOV   (SP)+,R1          ; pop original R1
            BIC   #0xFF00,R1        ; mask out all but least significant bits
            MOVB  R1,R0
            JSR   PC,@#PRINT2HEX    ; print the least significant byte of R1 as 2 hex digits
            MOV   (SP)+,R1          ; pop R1
            MOV   (SP)+,R0          ; pop R0
            RTS   PC

;-------------------------------------------------------------------
; print the byte in R0 as two ASCII hex digits.
; preserves the byte in R0.
;-------------------------------------------------------------------
PRINT2HEX:  MOV   R0,-(SP)          ; push R0
            MOV   R4,-(SP)          ; push R4
            MOV   R0,-(SP)          ; push R0
            ASRB  R0
            ASRB  R0
            ASRB  R0
            ASRB  R0
            BICB  #0xF0,R0          ; mask out all but least significant bits
            MOVB  R0,R4
            JSR   PC,@#HEX2ASCII
            JSR   PC,@#PUTC         ; print the most significant hex digit
            MOV   (SP)+,R0          ; pop R0
            BICB  #0xF0,R0          ; mask out all but least significant bits
            MOVB  R0,R4
            JSR   PC,@#HEX2ASCII
            JSR   PC,@#PUTC         ; print the least significant hex digit
            MOV   (SP)+,R4          ; pop R4
            MOV   (SP)+,R0          ; pop R0
            RTS   PC

; convert the nybble in R4 to ASCII hex digit
; called by PRINT2HEX function
HEX2ASCII:  BICB  #0xF0,R4          ; mask out everything except the lower nybble
            CMPB  R4,#10
            BCS   HEX2ASCII1        ; branch if the number in R0 is less than 10
            ADD   #7,R4             ; else, add 7 to convert to 10-15 to A-F
HEX2ASCII1: ADD   #0x30,R4          ; convert binary to ASCII
            RTS   PC

;-------------------------------------------------------------------
; get 2 hex digits from the console. return with carry set if 'ESC' key
; return with overflow set if 'SPACE' key. else return with carry and
; overflow clear and the byte in R1
;-------------------------------------------------------------------
GET2HEX:    MOV   R4,-(SP)          ; push R4
GET2HEX1:   JSR   PC,@#HEXDIGIT     ; get the first ASCII hex digit into R4
            CMPB  #CR,R4            ; 'ENTER'?
            BEQ   GET2HEX1          ; branch back for another character if 'ENTER'
            CMPB  #ESC,R4           ; 'ESC'?
            BEQ   GET2HEX4          ; branch if 'ESC'
            CMP   #' ',R4
            BEQ   GET2HEX5          ; branch if 'SPACE'
            JSR   PC,@#ASCII2HEX    ; else, convert to the first digit to binary
            MOVB  R4,R1             ; save the first digit in R1
            JSR   PC,@#HEXDIGIT     ; get the second ASCII hex digit into R4
            CMPB  #ESC,R4           ; 'ESC'?
            BEQ   GET2HEX4
            CMPB  #CR,R4            ; 'ENTER'?
            BEQ   GET2HEX3          ; exit after one digit
            JSR   PC,@#NEWDIGIT     ; else, add the second digit to R1
GET2HEX3:   MOV   (SP)+,R4          ; pop R4
            CLC                     ; clear carry
            CLV                     ; clear overflow
            RTS   PC
; 'ESC'            
GET2HEX4:   MOV   (SP)+,R4          ; pop R4
            SEC                     ; set carry
            CLV                     ; clear overflow
            RTS   PC
; 'SPACE'            
GET2HEX5:   MOV   (SP)+,R4          ; pop R4
            CLC                     ; clear carry
            SEV                     ; set overflow
            RTS   PC            

;-------------------------------------------------------------------
; get 4 hex digits from the console. return with carry set if 'ESC'.
; return with overflow set if 'SPACE' key. else return with carry 
; and overflow clear and the word in R1
;-------------------------------------------------------------------
GET4HEX:    MOV   R4,-(SP)          ; push R4
GET4HEX1:   JSR   PC,@#HEXDIGIT     ; get the first ASCII hex digit into R4
            CMP   #CR,R4            ; 'ENTER'?
            BEQ   GET4HEX1          ; if so, go back for another character
            CMP   #ESC,R4           ; 'ESC'?
            BEQ   GET4HEX3          ; branch if 'ESC'
            CMP   #' ',R4           ; 'SPACE'?
            BEQ   GET4HEX4          ; branch if 'SPACE'  
            JSR   PC,@#ASCII2HEX    ; convert to the first digit to binary
            MOVB  R4,R1             ; save the first digit in R1
            JSR   PC,@#HEXDIGIT     ; get the second ASCII hex digit into R4
            CMP   #ESC,R4           ; 'ESC'?
            BEQ   GET4HEX3          ; exit if 'ESC'
            CMPB  #CR,R4            ; 'ENTER'?
            BEQ   GET4HEX2          ; exit after one digit
            JSR   PC,@#NEWDIGIT     ; else, add the second digit to R1
            JSR   PC,@#HEXDIGIT     ; get the third ASCII hex digit into R4
            CMP   #ESC,R4           ; 'ESC'?
            BEQ   GET4HEX3          ; exit if 'ESC'
            CMPB  #CR,R4            ; 'ENTER'?
            BEQ   GET4HEX2          ; exit after two digits
            JSR   PC,@#NEWDIGIT     ; else, add the third digit to R1
            JSR   PC,@#HEXDIGIT     ; get the fourth ASCII hex digit into R4
            CMP   #ESC,R4           ; 'ESC'?
            BEQ   GET4HEX3          ; exit if 'ESC'
            CMPB  #CR,R4            ; 'ENTER'?
            BEQ   GET4HEX2          ; exit after three digits
            JSR   PC,@#NEWDIGIT     ; else, add the fourth digit to R1
GET4HEX2:   MOV   (SP)+,R4          ; pop R4
            CLC                     ; clear carry
            CLV                     ; clear overflow
            RTS   PC
; 'ESC' key            
GET4HEX3:   CLR   R1
            MOV   (SP)+,R4          ; pop R4
            SEC                     ; set carry
            CLV                     ; clear overflow
            RTS   PC
; 'SPACE'
GET4HEX4:   CLR   R1
            MOV   (SP)+,R4          ; pop R4
            CLC                     ; clear carry
            SEV                     ; set overflow
            RTS   PC            

; adds new hex digit in R4 to R1
; called by GET2HEX and GET4HEX functions
NEWDIGIT:   JSR   PC,@#ASCII2HEX    ; convert the hex digit in R4 from ASCII to binary
            ASL   R1                ; shift the digits in R1 left to make room for the new digit in R4
            ASL   R1
            ASL   R1
            ASL   R1
            ADD   R4,R1             ; add the new digit in R4 to R1
            RTS   PC

; convert the ASCII hex digit 0-9, A-F in R4 to binary
; called by GET2HEX, GET4HEX and NEWDIGIT functions
ASCII2HEX:  SUB   #0x30,R4          ; convert to binary
            CMPB  R4,#0x0A          ; is it A-F?
            BCS   ASCII2HEX1        ; branch if less than 0x0A
            SUB   #0x07,R4          ; else, subtract an additional 0x07 to convert to 0x0A-0x0F
            BICB  #0xF0,R4          ; mask out all but least significant bits
ASCII2HEX1: RTS   PC

; get an ASCII hex digit 0-9, A-F from the console.
; echo valid hex digits. return the ASCII hex digit in R4.
; called by GET2HEX and GET4HEX functions
HEXDIGIT:   JSR   PC,@#GETC         ; wait for a character from the console. character returned in R4
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
HEXDIGIT2:  JSR   PC,@#PUTC         ; since it's a legit hex digit, echo the character
HEXDIGIT3:  RTS   PC

;-------------------------------------------------------------------
; print carriage return and line feed to the console.
;-------------------------------------------------------------------
CRLF:       MOV   R4,-(SP)          ; push R4
            MOVB  #CR,R4
            JSR   PC,@#PUTC
            MOVB  #LF,R4
            JSR   PC,@#PUTC
            MOV   (SP)+,R4          ; pop R4
            RTS   PC

;-------------------------------------------------------------------
; print 'SPACE' to the console.
;-------------------------------------------------------------------
SPACE:      MOV   R4,-(SP)          ; push R4
            MOVB  #' ',R4
            JSR   PC,@#PUTC
            MOV   (SP)+,R4          ; pop R4
            RTS   PC

;-------------------------------------------------------------------
; print 'TAB' to the console.
;-------------------------------------------------------------------
TAB:        MOV   R4,-(SP)          ; push R4
            MOVB  #0x09,R4
            JSR   PC,@#PUTC
            MOV   (SP)+,R4          ; pop R4
            RTS   PC

;-------------------------------------------------------------------
; print the character in R4 to the console.
;-------------------------------------------------------------------
PUTC:       BITB  #0x02,@#ACIA      ; test Transmit Data Register Empty bit in the ACIA Status Register
            BEQ   PUTC              ; branch if TDRE is not set
            MOVB  R4,@#ACIA+1       ; else, write the character in R4 to the ACIA's Transmit Data Register
            RTS   PC

;-------------------------------------------------------------------
; wait for a character from the console. return the character in R4.
; if the 'blink' flag is set, flash the orange LED connected to the VIA CB2 pin.
; control B (0x02) toggles the 'blink' flag.
;-------------------------------------------------------------------
GETC:       CMPB  @#INPTR,@#OUTPTR  ; check if there are any characters available
            BEQ   GETC2
            MOV   R5,-(SP)          ; push R5
            MOVB  @#OUTPTR,R5       ; get the buffer output pointer
            MOVB  BUFF(R5),R4       ; get the next character from the buffer into R4
            INCB  @#OUTPTR          ; update the output pointer
            BICB  #0xF0,@#OUTPTR    ; mask out all but the 4 least significant bits of the pointer
            MOV   (SP)+,R5          ; pop R5
            CMPB  #0x02,R4          ; is the character just received ^B?
            BNE   GETC1
            COMB  @#BLINK           ; toggle the 'blink' flag
            TSTB  @#BLINK           ; test the 'blink' flag
            BNE   GETC              ; branch if the 'blink' flag is set
            BICB  #0x20,@#PCR       ; else, clear bit 5 of the PCR to turn the orange LED off
            BR    GETC              ; go back for another characger
GETC1:      RTS   PC                ; return with the character in R4

; if the 'blink' flag is set, flash the orange LED once per second while waiting for a character
GETC2:      CMPB  @#SECS,@#LASTSECS
            BEQ   GETC              ; branch if one second has not yet elapsed
            MOVB  @#SECS,@#LASTSECS ; else, update LASTSECS
            TSTB  @#BLINK           ; test the 'blink' flag
            BEQ   GETC              ; branch if the flag is clear
            BITB  #0x20,@#PCR       ; else, test bit 5 of the VIA's Peripheral Control Register
            BEQ   GETC3             ; branch if bit 5 of the PCR is zero
            BICB  #0x20,@#PCR       ; else, clear bit 5 of the PCR to turn the orange LED off
            BR    GETC
GETC3:      BISB  #0x20,@#PCR       ; set bit 5 of the PCR to turn the orange LED on
            BR    GETC

;-------------------------------------------------------------------
; convert the character in R4 to upper case
;-------------------------------------------------------------------
UPPER:      CMPB  R4,#'a'
            BLO   UPPER1            ; branch if the character in R4 is lower then 'a'
            CMPB  R4,#'z'+1
            BHIS  UPPER1            ; branch if the character in R4 is higher than 'z'
            SUB   #0x20,R4          ; convert from lower to upper case
UPPER1:     RTS   PC

;-------------------------------------------------------------------
; print to the console the zero terminated string whose address is in R5
;-------------------------------------------------------------------
PUTS:       MOV   R4,-(SP)          ; push R4
PUTS1:      MOVB  (R5)+,R4          ; retrieve the character from the string
            BEQ   PUTS2             ; branch if zero
            JSR   PC,@#PUTC         ; else, print it
            BR    PUTS1             ; go back for the next character
PUTS2:      MOV   (SP)+,R4          ; pop R4
            RTS   PC

;-------------------------------------------------------------------
; code used to test the single-step function
;-------------------------------------------------------------------
STEPTEST:   MOVB  #0x01,R0
STEPTEST1:  MOVB  R0,@#ORB          ; turn on yellow LEDS
            INCB  R0
            BNE   STEPTEST1
            RTS   PC

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
            RTS   PC

;-------------------------------------------------------------------
; code used to test the TRAP handler
;-------------------------------------------------------------------
TRAPTEST:   TRAP  0xAA
            RTS   PC
            
;=======================================================================
; Interrupt Service Routine for ACIA RX and VIA Timer 1 interrupts
;=======================================================================
ISR:        BITB  #0x80,@#ACIA      ; test IRQ bit in the ACIA's Status Register
            BEQ   ISR1              ; branch if the ACIA'S IRQ bit is not set
            MOV   R4,-(SP)          ; else, push R4
            MOVB  @#INPTR,R4        ; retrieve the input buffer pointer
            MOVB  @#ACIA+1,BUFF(R4) ; put the character from the ACIA's Receive Data Register into the buffer
            INCB  @#INPTR           ; increment the pointer
            BIC   #0xF0,@#INPTR     ; mask out all but the 4 least significant bits of the pointer
            MOV   (SP)+,R4          ; pop R4

ISR1:       BITB  #0x80,@#IFR       ; test IRQ bit in the VIA's Interrupt Flag Register
            BEQ   ISR2              ; exit if the VIA's IRQ flag is not set
            MOV   R4,-(SP)          ; else, push R4
            MOVB  @#T1CL,R4         ; read T1CL to clear the Timer 1 interrupt flag
            MOV   (SP)+,R4          ; pop R4
            DECB  @#TICKS           ; decrement the tick counter
            BNE   ISR2              ; branch if the tick counter is not zero
            MOVB  #50,@#TICKS       ; else, one second has elapsed. re-initialize the tick counter
            INCB  @#SECS            ; update seconds count
            CMPB  @#SECS,#60
            BNE   ISR2
            CLRB  @#SECS
            INCB  @#MINS            ; update minutes count
            CMPB  @#MINS,#60
            BNE   ISR2
            CLRB  @#MINS
            INCB  @#HRS             ; update hours count
ISR2:       RTI                     ; return from interrupt

;=======================================================================
; jump here on BPT instruction or after single-stepping.
; print the contents of the registers and PS then return to the monitor.
;=======================================================================
BREAK:      MOV   (SP)+,@#SAVEDR7   ; save PC from before the interrupt
            MOV   (SP)+,@#SAVEDPS   ; save PS from before the interrupt
            MOV   SP,@#SAVEDR6      ; save SP
            MOV   R0,@#SAVEDR0      ; save R0
            MOV   R1,@#SAVEDR1      ; save R1
            MOV   R2,@#SAVEDR2      ; save R2
            MOV   R3,@#SAVEDR3      ; save R3
            MOV   R4,@#SAVEDR4      ; save R4
            MOV   R5,@#SAVEDR5      ; save R5
            
            ; print what was saved from the registers
            JSR   PC,@#CRLF
            MOVB  #9,R3             ; 8 register plus PS
            MOV   #SAVEDR0,R0       ; R0 points to the first memory location where the registers are saved
BREAK1:     MOV   (R0),R1           ; get the saved register contents
            JSR   PC,@#PRINT4HEX    ; print the contents
            JSR   PC,@#SPACE        ; print a space between contents
            INC   R0                ; point to the next memory location
            INC   R0
            DECB  R3
            BNE   BREAK1
            
            ; restore the saved values to the registers
            MOV   @#SAVEDR0,R0      ; restore R0
            MOV   @#SAVEDR1,R1      ; restore R1
            MOV   @#SAVEDR2,R2      ; restore R2
            MOV   @#SAVEDR3,R3      ; restore R3
            MOV   @#SAVEDR4,R4      ; restore R4
            MOV   @#SAVEDR5,R5      ; restore R50
            MOV   @#SAVEDR6,SP      ; restore SP
            BIC   #0x0010,@#SAVEDPS ; clear the T bit
            MOV   @#SAVEDPS,-(SP)   ; push PS
            MOV   #MONITOR,-(SP)    ; push PC (return to monitor)
            JSR   PC,@#CRLF               
            JSR   PC,@#CRLF               
            RTI

;=======================================================================
; jump here on HALT instruction. flash the yellow LEDs to let us know what happened
;=======================================================================
HALTED:     MOVB  #0xCE,@#PCR       ; turn off the orange LED and turn on the red error LED
            MOVB  #0x01,@#ORB       ; light one yellow LED
HALTED1:    DEC   @#COUNT
            BNE   HALTED1           ; branch if the loop counter has not yet reached zero
            MOV   #LOOPCNT/4,@#COUNT; else, re-initialize loop counter
            MOVB  @#ORB,R5          ; load Output Register B into R5
            ROLB  R5                ; rotate the bit right
            MOVB  R5,@#ORB          ; load R5 into Output Register B
            BR    HALTED1

;=======================================================================
; jump here on unhandled interrupts. flash the yellow LEDs to let us know happened
;=======================================================================
HANG:       MOVB  #0xCE,@#PCR       ; turn off the orange LED and turn on the red error LED
HANG1:      MOVB  #0x55,@#ORB       ; light the yellow LEDs
            DEC   @#COUNT
            BNE   HANG              ; branch back if the loop count has not yet reached zero
            MOV   #LOOPCNT,@#COUNT  ; initialize loop counter
HANG2:      MOVB  #0xAA,@#ORB       ; alternate the yellow LEDs
            DEC   @#COUNT
            BNE   HANG2             ; branch back if the loop count has not yet reached zero
            MOV   #LOOPCNT,@#COUNT  ; initialize loop counter
            BR    HANG1

;=======================================================================
; jump here on TRAP instruction.
;=======================================================================
TRAPPER:    MOV   R0,@#SAVEDR0      ; save R0
            MOV   R1,@#SAVEDR1      ; save R1
            MOV   (SP),R0           ; get the return address from the stack into R0
            SUB   #2,R0             ; subtract 2 to get the address of the TRAP instruction
            MOV   (R0),R1           ; load the actual TRAP instruction into R1
            BIC   #0xFF00,R1        ; mask out the upper byte so that R1 now holds the TRAP instruction parameter (0x00-0xFF)

            ; for now, just print the TRAP parameter
            JSR   PC,@#CRLF
            MOVB  R1,R0
            JSR   PC,@#PRINT2HEX
            JSR   PC,@#CRLF

            MOV   @#SAVEDR1,R1      ; restore R1
            MOV   @#SAVEDR0,R0      ; restore R0
            RTI
            
;-----------------------------------------------------------------------            
; interrupt/TRAP vectors to be copied into RAM starting at 0x0008
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
BANNERTXT   BYTE  CLS,"T-11 SBC Serial Monitor\r\n\n"
            BYTE  "Assembled on ",DATE," at ",TIME,"\r\n\n",0
MENUTXT     BYTE  "D - Dump a page of memory\r\n"
            BYTE  "F - Fill block of RAM\r\n"
            BYTE  "M - Modify RAM contents\r\n"
            BYTE  "R - modify Registers\r\n"
            BYTE  "H - Intel Hex file download\r\n"
            BYTE  "U - print Uptime\r\n"
            BYTE  "C - Call subroutine\r\n"
            BYTE  "J - Jump to address\r\n"
            BYTE  "S - Single-step\r\n"
            BYTE  "N - single-step Next instruction\r\n"
            BYTE  "B - resume code execution after Breakpoint\r\n\n",0
PROMPTTXT   BYTE  ">>",0
DUMP1TXT    BYTE  "Dump memory at address: ",0
DUMP2TXT    BYTE  "\n        00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F\r\n",0
NEXTTXT     BYTE  "SPACE for next page. Any other key to exit...",0
MODIFYTXT   BYTE  "Examine/Modify memory at address: ",0
UPTIMETXT   BYTE  "Uptime: ",0
ARROWTXT    BYTE  " --> ",0
FILLTXT     BYTE  "Fill memory block at address: ",0
COUNTTXT    BYTE  "Count: (in HEX) ",0
VALUETXT    BYTE  "Value: ",0
JUMPTXT     BYTE  "Jump to address: ",0
CALLTXT     BYTE  "Call subroutine at address: ",0
HEXDLTXT    BYTE  "Waiting for hex download...",0
DLCNTTXT:   BYTE  " bytes downloaded\r\n",0
CKSERRTXT   BYTE  " checksum errors!\r\n",0
NOERRTXT    BYTE  "No checksum errors\r\n",0
STEPTXT     BYTE  "Single step at address: ",0
REGTXT      BYTE  "Registers...\r\n",0

            END
