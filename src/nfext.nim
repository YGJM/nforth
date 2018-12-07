import unicode
import utf8utils as utf8
import parse
from command import parseCmd, execCmd

## main/zforth

## tempolary input/output buffer for utf8

var tiob = newString(utf8.MaxRune)
var fill = 0      # rune length
var fillp = 0     # index of tiob

## Extensions prototype

proc nfDsp*(): NfAddr
proc nfBase(): NfAddr

##
## Tracing output
##

proc nfHostTrace*(fmtstr: string) =
  writeStyled(fmtstr, {styleBright})

##
## Parse number
##

proc nfHostParseNum*(buf: string): NfCell =
  var v: NfCell
  try:
    v = cast[NfCell](parseInt(buf))
  except ValueError:
    when DEBUG: echo "HostParseNum buf => ", buf
    nfAbort(NfAbortNotAWord)
  return v

proc nfMsg(reason: NfResult, src = "", line = -1) =
  #echo " nfMsg called reason => ", reason, " nfresult => ", nfresult
  var msg: string

  case reason:
  of NfAbortInternalError:
    msg = "internal error"
  of NfAbortOutsideMem:
    msg = "outside memory"
  of NfAbortDstackOverrun:
    msg = "dstack overrun"
  of NfAbortDstackUnderrun:
    msg = "dstack underrun"
  of NfAbortRstackOverrun:
    msg = "rstack overrun"
  of NfAbortRstackUnderrun:
    msg = "rstack underrun"
  of NfAbortNotAWord:
    msg = "not a word"
  of NfAbortCompileOnlyWord:
    msg = "compile only word"
  of NfAbortInvalidSize:
    msg = "invalid size"
  of NfAbortDivisionByZero:
    msg = "division by zero"
  else: msg = "unknown error"

  if msg != "":
    stderr.setForegroundColor(fgRed)
    if src != "" or line != -1: stderr.write(src & ":" & $line & " abort! ")
    stderr.resetAttributes()
    stderr.write(msg & '\n')

##
## valuate buffer with code, check return value and report errors
##

proc nfEval*(buf: string): bool

proc nfDoEval*(src: string, line: int, buf: string): bool =
  #when DEBUG: echo "DoEval buf len => ", buf.len
  if nfEval(buf): return true
  else:
    nfMsg(nfresult, src, line)
    nfresult = NfOk
    return false

##
## Load given forth file
##

proc nfinclude*(fname: string) =
  var f: system.File
  var buf: TaintedString
  var line = 1

  if open(f, fname, fmRead):
    when DEBUG: echo "include fname => ", fname
    while true:
      if readLine(f, buf):
        if buf.len != 0:
          buf = buf & '\0'
          when DEBUG: echo line, ": ", buf
          if nfDoEval(fname, line, buf): inc(line)
          else: break
      else: break
    close(f)
  else:
    echo "Error openning file: ", fname
    
##
## Save dictionary
##

proc nfSave(fname: string) =
  var f: system.File

  if open(f, fname, fmWrite):
    let b = writeBytes(f, dict, 0, dict.len)
    if b != dict.len:
      echo "Unknown error!"
  else:
    echo "error openning file: ", fname   

##
## Load dictionary
##

proc nfLoad*(fname: string) =
  var f: system.File

  if open(f, fname, fmRead):
    let b = readBytes(f, dict, 0, dict.len)
    if b != dict.len:
      echo "Unknown error!"
  else:
    echo "error openning file: ", fname 

##
## send command to editor
##

proc nfSendToEditor(cmdstr: string): int = 
  var cmd: parse.Cmd
  result = 0
  #echo "nfSendToEditor cmdstr => ", cmdstr
  parse.linebuf = toRunes(cmdstr & '\n')
  cmd = parseCmd()
  if cmd == nil: result = 1
  elif not execCmd(cmd): result = 1

##
## Sys callback function
##

proc nfHostSys*(id: NfSyscallId, input: string): NfInputState =
  case ord(id)

  # The core system callbacks

  of ord(NfSyscallEmit):     # emit
    let c = nfPop()
    if c <= 127:
      stdout.write(chr(c))
    else:       # print utf8
      #echo "emit c => ", c, " fill => ", fill, " tiob => ", repr(tiob)
      if fill == 0:
        fill = utf8.runeByteLen(chr(c))
        tiob[fillp] = chr(c)
        inc(fillp)
      else:
        tiob[fillp] = chr(c)
        inc(fillp)
      if fillp == fill:
        stdout.write(tiob[0..fill - 1])
        for i in 0..fill - 1: tiob[i] = '\0'
        fill = 0
        fillp = 0

  of ord(NfSyscallPrint):    # print
    #when DEBUG: echo "nfHostSys call print"
    let b = int(nfBase())
    let n = nfPop()
    #when DEBUG: echo "nfHostSys print b => ", b, " n => ", n
    case b
    of 10:
      stdout.write(fmt"{n:d}")
    of 8:
      stdout.write(fmt"{n:o}")
    of 16:
      stdout.write(fmt"{n:#X}")
    of 2:
      stdout.write(fmt"{n:b}")
    else: discard

  of ord(NfSyscallTell):      # tell for utf8, use dictGetCell to get Rune
    let len = nfPop()
    let adr = nfPop()
    #for i in 0..len - 1: write(stdout, chr(dict[cast[NfAddr](adr) + cast[NfAddr](i)]))
    var a = NfAddr(adr)
    var d: NfCell
    var l = NfAddr(0)
    while l < NfAddr(len):
      l += dictGetCell(a, d)
      #echo "HostSys tell adr => ", a, " len => ", len, " d => ", d, " l => ", l
      if d <= 127:
        stdout.write(chr(d))
      else:
        if fill == 0:
          fill = utf8.runeByteLen(chr(d))
          tiob[fillp] = chr(d)
          inc(fillp)
        else:
          tiob[fillp] = chr(d)
          inc(fillp)
        if fillp == fill:
          stdout.write(tiob[0..fill - 1])
          for i in 0..fill - 1: tiob[i] = '\0'
          fill = 0
          fillp = 0
      a = NfAddr(adr) + l

  # Application specific callback: extensions

  of ord(NfSyscallUser) + 0:     # 128 quit
    quitok = true
    stdout.write("\n")

  of ord(NfSyscallUser) + 1:     # 129 depth
    nfPush(NfCell(nfDsp()))

  of ord(NfSyscallUser) + 2:     # 130 include
    if input == "": return NfInputPassWord
    nfInclude(input)

  of ord(NfSyscallUser) + 3:     # 131 save dictionary
    nfSave("nforth.save")

  of ord(NfSyscallUser) + 4:     # 132 OR
    nfPush(int(nfPop()) or int(nfPop()))

  of ord(NfSyscallUser) + 5:     # 133 XOR
    nfPush(int(nfPop()) xor int(nfPop()))

  of ord(NfSyscallUser) + 6:     # 134 INVERT(complement)
    nfPush(not(nfPop()))

  of ord(NfSyscallUser) + 7:     # 135 shift right/left
    let n = nfPop()
    if n < 0: nfPush(nfPop() shr -n)
    else: nfPush(nfPop() shl n)

  of ord(NfSyscallUser) + 8:     # 136 debug dump of dict
    let f = nfPop()
    if f == 0:
      echo "Debug dict dump => ", repr(dict)
    else:
      echo "Debug dict dump => ", repr(dict[LATEST..HERE])
    
  of ord(NfSyscallUser) + 9:     # 137 string len for ascii, utf8
    let len = nfPop()
    let adr = nfPop()
    #for i in 0..len - 1: write(stdout, chr(dict[cast[NfAddr](adr) + cast[NfAddr](i)]))
    var a = NfAddr(adr)
    var d: NfCell
    var l = NfAddr(0)
    var slen = 0
    while l < NfAddr(len):
      l += dictGetCell(a, d)
      #echo "HostSys tell adr => ", a, " len => ", len, " d => ", d, " l => ", l
      if d <= 127:
        inc(slen)
      else:
        if fill == 0:
          fill = utf8.runeByteLen(chr(d))
          tiob[fillp] = chr(d)
          inc(fillp)
        else:
          tiob[fillp] = chr(d)
          inc(fillp)
        if fillp == fill:
          inc(slen)
          for i in 0..fill - 1: tiob[i] = '\0'
          fill = 0
          fillp = 0
      a = NfAddr(adr) + l

    nfPush(slen)

  of ord(NfSyscallUser) + 10:     # send to editor
    let len = nfPop()
    let adr = nfPop()
    #for i in 0..len - 1: write(stdout, chr(dict[cast[NfAddr](adr) + cast[NfAddr](i)]))
    var a = NfAddr(adr)
    var d: NfCell
    var l = NfAddr(0)
    var s = ""
    while l < NfAddr(len):
      l += dictGetCell(a, d)
      #echo "HostSys tell adr => ", a, " len => ", len, " d => ", d, " l => ", l
      if d <= 127:
        s.add(chr(d))
      else:
        if fill == 0:
          fill = utf8.runeByteLen(chr(d))
          tiob[fillp] = chr(d)
          inc(fillp)
        else:
          tiob[fillp] = chr(d)
          inc(fillp)
        if fillp == fill:
          for i in 0..fill - 1:
            s.add(tiob[i])
            tiob[i] = '\0'
          fill = 0
          fillp = 0
      a = NfAddr(adr) + l

    nfPush(nfSendToEditor(s))
    
  else: echo "Unhandled syscall ", id
  return NfInputInterpret

## My extensions
  
proc nfDsp*(): NfAddr =
  return dsp

proc nfBase(): NfAddr =
  return BASE

## End of main
