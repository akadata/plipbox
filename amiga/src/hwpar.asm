      section "text",code

      IFND HARDARE_CIA_I
      include "hardware/cia.i"
      ENDC

      IFND EXEC_MACROS_I
      include "exec/macros.i"
      ENDC

      IFND HWPAR_I
      include "hwpar.i"
      ENDC


      xdef    _interrupt
      xdef    _hwsend
      xdef    _hwrecv


ciaa     equ     $bfe001
ciab     equ     $bfd000
BaseAX   equ     ciab+ciapra

HS_ACK_BIT      equ     CIAB_PRTRBUSY
HS_REQ_BIT      equ     CIAB_PRTRPOUT

SETSELECT MACRO
      bset     #CIAB_PRTRSEL,ciab+ciapra-BaseAX(\1)   ; raise PRTSEL line
      ENDM

CLRSELECT MACRO
      bclr     #CIAB_PRTRSEL,ciab+ciapra-BaseAX(\1)   ; lower PRTSEL line
      ENDM

SETCIAOUTPUT MACRO
      st       ciaa+ciaddrb-BaseAX(\1)                ; data dir. => output
      ENDM

SETCIAINPUT MACRO
      sf       ciaa+ciaddrb-BaseAX(\1)                ; data dir. => input
      ENDM


;----------------------------------------------------------------------------
;
; NAME
;     interrupt() - ICR FLG interrupt server
;
; SYNOPSIS
;     void interrupt(struct HWBase *)
;                    A1
;
; FUNCTION
;     This is called from CIA resource on the receipt of an parallel port
;     FLG line interrupt. This is the case if the other side starts
;     transmission and writes the first byte to our port.
;
;     We recognise this here and propagate the information to the server
;     task by Signal()ing it and by setting the PLIPB_RECEIVING bit
;     in the flags field.
;
_interrupt:
        btst    #HWB_RECV_PENDING,hwb_Flags(a1)
        bne.s   skipint
        bset    #HWB_RECV_PENDING,hwb_Flags(a1)
        move.l  hwb_IntSigMask(a1),d0
        move.l  hwb_SysBase(a1),a6
        move.l  hwb_Server(a1),a1
        JSRLIB  Signal
skipint:
        moveq #0,d0
        rts

;----------------------------------------------------------------------------
;
; NAME
;     hwsend() - low level send routine
;
; SYNOPSIS
;     void hwsend(struct HWBase *, struct HWFrame *)
;                 A0               A1
;
; FUNCTION
;     This functions sends a HW frame with the plipbox protocol via
;     the parallel port
;
_hwsend:
         movem.l  d2-d7/a2-a6,-(sp)
         move.l   a0,a2                               ; a2 = HWBase
         move.l   a1,a4                               ; a4 = Frame
         moveq    #FALSE,d2                           ; d2 = return value
         moveq    #HS_REQ_BIT,d3                      ; d3 = HS_REQ
         moveq    #HS_ACK_BIT,d4                      ; d4 = HS_ACK
         lea      BaseAX,a5                           ; a5 = CIA HW base

         ; signal plipbox by setting SEL
         SETSELECT a5

         ; disable ack irq
         move.l   hwb_CIAABase(a2),a6
         moveq    #CIAICRF_FLG,d0
         JSRLIB   AbleICR

         ; if ACK is already set then its an invalid plipbox state!
         move.b   (a5),d7                             ; read par flags, d7 = State
         btst     d4,d7
         bne.s    hww_ExitError
                  
         ; --- initial handshake ---
         ; par is OUTPUT
         SETCIAOUTPUT a5
         move.b   #HWF_CMD_SEND,ciaa+ciaprb-BaseAX(a5) ; WRITECIA *p++
         ; initially set REQ high
         bset     d3,d7
         move.b   d7,(a5)
        
         ; packet size
         move.w   (a4),d6
         addq.w   #2,d6    ; add size itself
        
         ; --- main loop ---
         ; wait for incoming ACK 
hww_WaitAck:
         move.b   (a5),d0                             ; ciab+ciapra
         eor.b    d7,d0
         btst     d4,d0                               ; ACK toggled?
         bne.s    hww_AckOk
         ; check for timeout
         tst.b    hwb_TimeoutSet(a2)
         beq.s    hww_WaitAck
         bra.s    hww_ExitError
hww_AckOk:
         eor.b    d0,d7

         ; write next byte of HW packet
         move.b   (a3)+,ciaa+ciaprb-BaseAX(a5)        ; WRITECIA *p++
         bchg     d3,(a5)                             ; set REQ toggle

         ; loop for all packet bytes
         dbra     d6,hww_WaitAck

hww_ExitOk:
         moveq    #TRUE,d2                            ; rc = TRUE
hww_ExitError:
         ; --- exit ---
         ; par is INPUT
         SETCIAINPUT a5
         ; clear REQ
         bclr     d3,(a5)                             ; clear REQ

         ; enable ack irq
         moveq    #CIAICRF_FLG,d0
         JSRLIB   SetICR                              ; CLEARINT
         move.w   #CIAICRF_FLG|CIAICRF_SETCLR,d0
         JSRLIB   AbleICR                             ; ENABLEINT

         ; finally clear SEL
         CLRSELECT a5

         move.l   d2,d0                               ; return rc
         movem.l  (sp)+,d2-d7/a2-a6
         rts

;----------------------------------------------------------------------------
;
; NAME
;     hwrecv() - low level receive routine
;
; SYNOPSIS
;     void hwrecv(struct HWBase *, struct HWFrame *)
;                 A0               A1
;
; FUNCTION
;     Receive a packet with the plipbox protocol
;
_hwrecv:
         movem.l  d2-d7/a2-a6,-(sp)
         move.l   a0,a2                               ; a2 = HWBase
         move.l   a1,a4                               ; a4 = HWFrame
         moveq    #FALSE,d5                           ; d5 = return value
         move.l   hwb_CIAABase(a2),a6                 ; a6 = CIABase
         moveq    #HS_REQ_BIT,d3                      ; d3 = HS_REQ
         moveq    #HS_ACK_BIT,d4                      ; d4 = HS_ACK
         lea      BaseAX,a5                           ; a5 = ciab+ciapra

         ; signal plipbox by setting SEL
         SETSELECT a5

         ; disable ack irq
         move.l   hwb_CIAABase(a2),a6
         moveq    #CIAICRF_FLG,d0
         JSRLIB   AbleICR

         ; if ACK is already set then its an invalid plipbox state!
         move.b   (a5),d7                             ; read par flags, d7 = State
         btst     d4,d7
         bne      hwr_ExitError
         
         ; --- init ---
         ; par is OUTPUT and set command byte
         SETCIAOUTPUT a5
         move.b   #HWF_CMD_RECV,ciaa+ciaprb-BaseAX(a5) ; WRITECIA *p++
         ; initially set REQ high
         bset     d3,d7
         move.b   d7,(a5)
        
         ; --- main loop ---
         ; wait for incoming ACK
hwr_WaitAck:
         move.b   (a5),d0                             ; ciab+ciapra
         eor.b    d7,d0
         btst     d4,d0                               ; ACK toggled?
         bne.s    hwr_AckOk
         ; check for timeout
         tst.b    hwb_TimeoutSet(a2)
         beq.s    hwr_WaitAck
         bra.s    hwr_ExitError
hwr_AckOk:
         eor.b    d0,d7
         
         ; par is now INPUT
         SETCIAINPUT a5
         
         ; --- read size word ---
         ; wait for incoming ACK for HI size byte
hwr_WaitAck2:
         move.b   (a5),d0                             ; ciab+ciapra
         eor.b    d7,d0
         btst     d4,d0                               ; ACK toggled?
         bne.s    hwr_AckOk2
         ; check for timeout
         tst.b    hwb_TimeoutSet(a2)
         beq.s    hwr_WaitAck2
         bra.s    hwr_ExitError
hwr_AckOk2:
         eor.b    d0,d7
         
         ; read incoming HI size byte
         move.b   ciaa+ciaprb-BaseAX(a5),(a3)+        ; READCIABYTE
         bchg     d3,(a5)                             ; OUTPUTTOGGLE
         
         ; wait for incoming ACK for LO size byte
hwr_WaitAck3:
         move.b   (a5),d0                             ; ciab+ciapra
         eor.b    d7,d0
         btst     d4,d0                               ; ACK toggled?
         bne.s    hwr_AckOk3
         ; check for timeout
         tst.b    hwb_TimeoutSet(a2)
         beq.s    hwr_WaitAck3
         bra.s    hwr_ExitError
hwr_AckOk3:
         eor.b    d0,d7
         
         ; read incoming LO size byte
         move.b   ciaa+ciaprb-BaseAX(a5),(a3)+        ; READCIABYTE
         bchg     d3,(a5)                             ; OUTPUTTOGGLE

         ; now fetch full size word and check for max MTU
         move.w   -2(a3),d6                           ; = length
         tst.w    d6
         beq.s    hwr_ExitOk                          ; empty buffer
         cmp.w    hwb_MaxMTU(a2),d6                   ; buffer too large
         bhi.s    hwr_ExitError

         ; --- main packet data loop ---
         ; wait for incoming ACK on data byte
 hwr_WaitAck4:
         move.b   (a5),d0                             ; ciab+ciapra
         eor.b    d7,d0
         btst     d4,d0                               ; ACK toggled?
         bne.s    hwr_AckOk4
         ; check for timeout
         tst.b    hwb_TimeoutSet(a2)
         beq.s    hwr_WaitAck4
         bra.s    hwr_ExitError
 hwr_AckOk4:
         eor.b    d0,d7
 
         ; read incoming LO size byte
         move.b   ciaa+ciaprb-BaseAX(a5),(a3)+        ; READCIABYTE
         bchg     d3,(a5)                             ; OUTPUTTOGGLE

         ; loop for all packet bytes
         dbra     d6,hwr_WaitAck4

hwr_ExitOk:
         moveq    #TRUE,d5
hwr_ExitError:
         ; --- exit ---
         ; clear REQ
         bclr     d3,(a5)                             ; CLEARREQUEST ciab+ciapra
         
         ; clear RECV_PENDING flag set by irq
         bclr     #HWB_RECV_PENDING,hwb_Flags(a2)
         
         ; enable ack irq
         moveq    #CIAICRF_FLG,d0
         JSRLIB   SetICR                              ; CLEARINT
         move.w   #CIAICRF_FLG|CIAICRF_SETCLR,d0
         JSRLIB   AbleICR                             ; ENABLEINT
         
         ; clear SEL
         CLRSELECT a5

         move.l   d5,d0                               ; return value
         movem.l  (sp)+,d2-d7/a2-a6
         rts

         end
