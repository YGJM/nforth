import tables, strformat, strutils, terminal
 
include nfconf

## header/zforth
  
## Flags and length encoded in words

const
  NfFlagImmediate = (1 shl 6)
  NfFlagPrim = (1 shl 5)

proc nfFlagLen(v: int): int =
  return (v and 0x1f)
  
## Abort reasons, memory size, input state, syscall ids

type
  NfResult* = enum
    NfOk = 0, NfAbortInternalError, NfAbortOutsideMem, NfAbortDstackUnderrun,
    NfAbortDstackOverrun, NfAbortRstackUnderrun, NfAbortRstackOverrun,
    NfAbortNotAWord, NfAbortCompileOnlyWord, NfAbortInvalidSize,
    NfAbortDivisionByZero
  NfMemSize* = enum
    NfMemSizeVar = 0, NfMemSizeCell, NfMemSizeU8, NfMemSizeU16,
    NfMemSizeU32, NfMemSizeS8, NfMemSizeS16, NfMemSizeS32
  NfInputState* = enum
    NfInputInterpret = 0, NfInputPassChar, NfInputPassWord
  NfSyscallId* = enum
    NfSyscallEmit = 0, NfSyscallPrint, NfSyscallTell, NfSyscallUser = 128

var nfresult*: NfResult = NfOk

## Boundary check

proc nfAbort*(reason: NfResult)

when NfEnableBoundaryChecks:
  proc nfCheck(exp: bool, reason: NfResult): bool =
    #when DEBUG: echo "check exp => ", exp
    result = false
    if not exp: nfAbort(reason)
    else: result = true
else:
  proc nfCheck(exp: bool, reason: NfResult): bool = discard
    
## All primitives

type
  Primitives = enum PrimEXIT = 0, PrimLIT, PrimLTZ, PrimCOL, PrimSEMICOL, PrimADD, PrimSUB, PrimMUL,
    PrimDIV, PrimMOD, PrimDROP, PrimDUP, PrimPICKR, PrimIMMEDIATE, PrimPEEK, PrimPOKE, PrimSWAP,
    PrimROT, PrimJMP, PrimJMP0, PrimTICK, PrimCOMMENT, PrimPUSHR, PrimPOPR, PrimEQUAL, PrimSYS,
    PrimPICK, PrimCOMMA, PrimKEY, PrimLITS, PrimLEN, PrimAND,
    PrimCOUNT

const
  PrimNames = {ord(PrimEXIT): "exit",
               ord(PrimLIT): "lit",
               ord(PrimLTZ): "<0",
               ord(PrimCOL): ":",
               ord(PrimSEMICOL): "_;",
               ord(PrimADD): "+",
               ord(PrimSUB): "-",
               ord(PrimMUL): "*",
               ord(PrimDIV): "/",
               ord(PrimMOD): "%",
               ord(PrimDROP): "drop",
               ord(PrimDUP): "dup",
               ord(PrimPICKR): "pickr",
               ord(PrimIMMEDIATE): "_immediate",
               ord(PrimPEEK): "@@",
               ord(PrimPOKE): "!!",
               ord(PrimSWAP): "swap",
               ord(PrimROT): "rot",
               ord(PrimJMP): "jmp",
               ord(PrimJMP0): "jmp0",
               ord(PrimTICK): "'",
               ord(PrimCOMMENT): "_(",
               ord(PrimPUSHR): ">r",
               ord(PrimPOPR): "r>",
               ord(PrimEQUAL): "=",
               ord(PrimSYS): "sys",
               ord(PrimPICK): "pick",
               ord(PrimCOMMA): ",,",
               ord(PrimKEY): "key",
               ord(PrimLITS): "lits",
               ord(PrimLEN): "##",
               ord(PrimAND): "&"}.toTable
#  PrimCOUNT

## Stacks and dictionary

type
  Rstack = array[NfRstackSize, NfCell]
  Dstack = array[NfDstackSize, NfCell]
  Dict = array[NfDictSize, uint8]

var rstack: Rstack
var dstack: Dstack
var dict*: Dict

## State and stack and interpreter pointer

var inputState: NfInputState
var dsp: NfAddr
var rsp: NfAddr
var ip: NfAddr

var quitok* = false

## User variables are variables which are shared between forth and Nim.

const
  UservarCount = 6
  UservarNames = {0: "h", 1: "latest", 2: "trace", 3: "compiling", 4: "_postpone", 5: "base"}.toTable

var HERE*: NfAddr
var LATEST*: NfAddr
var TRACE*: uint8
var COMPILING*: uint8
var POSTPONE*: uint8
var BASE*: uint8

proc setUservar(adr: NfAddr, val: NfCell) =
  case adr
  of 0: HERE = NfAddr(val)
  of 1: LATEST = NfAddr(val)
  of 2: TRACE = uint8(val)
  of 3: COMPILING = uint8(val)
  of 4: POSTPONE = uint8(val)
  of 5: BASE = uint8(val)
  else: discard

proc getUservar(adr: NfAddr): NfCell =
  case adr
  of 0: result = NfCell(HERE)
  of 1: result = NfCell(LATEST)
  of 2: result = NfCell(TRACE)
  of 3: result = NfCell(COMPILING)
  of 4: result = NfCell(POSTPONE)
  of 5: result = NfCell(BASE)
  else: discard

## PrevEnv object instead of jmp_buf

type
  PrevEnv = ref object of RootObj
    pHERE, pLATEST, pDsp, pRsp: NfAddr
    pTRACE, pCOMPILING, pBASE: uint8
    
var prevenv: PrevEnv = nil

proc setPEnv(): bool =
  if prevenv == nil: return false
  prevenv.pHERE = HERE
  prevenv.pLATEST = LATEST
  #prevenv.pDsp = dsp
  #prevenv.pRsp = rsp
  prevenv.pTRACE = TRACE
  prevenv.pCOMPILING = COMPILING
  prevenv.pBASE = BASE
  return true

proc nfMsg(reason: NfResult, src = "", line = -1)

proc jmpPEnv(reason: NfResult) =
  #nfMsg(reason)
  HERE = prevenv.pHERE
  LATEST = prevenv.pLATEST
  dsp = 0                      # prevenv.pDsp
  rsp = 0                      # prevenv.pRsp
  TRACE = prevenv.pTRACE
  COMPILING = prevenv.pCOMPILING
  BASE = prevenv.pBASE   
  nfresult = reason

## Prototype

proc doPrim(op: Primitives, input: var string)
proc dictGetCell(adr: NfAddr, v: var NfCell): NfAddr
proc dictGetBytes(adr: NfAddr, buf: var openArray[byte], len: int)

proc nfPush(v: NfCell)
proc nfPop(): NfCell

## End of Header

## main/nfHost**, extensions

include nfext

## zforth/zforth
  
## Tracing function

when NfEnableTrace:
  proc nfTrace(fmtstr: string) =
    if TRACE == 1: nfHostTrace(fmtstr)
  
  proc nfOpName(adr: NfAddr): string =
    var w = LATEST
    var name: array[32, byte]
    var name2 = newString(32)
    
    while TRACE == 1 and w > 0'u:    # ?TODO
      var xt: NfAddr
      var p = w
      var d, link, op2: NfCell 
      var lenflags, i: int

      p += dictGetCell(p, d)
      lenflags = int(d)
      p += dictGetCell(p, link)
      xt = p + NfAddr(nfFlagLen(lenflags))
      discard dictGetCell(xt, op2)

      if (lenflags and NfFlagPrim) != 0 and adr == NfAddr(op2) or adr == w or adr == xt:
        let l = nfFlagLen(lenflags)
        dictGetBytes(p, name, l)
        i = 0
        for b in items(name):
          name2[i] = chr(b)
          inc(i)
        return name2

      w = NfAddr(link)
    return "?"
else:
  proc nfTrace(fmtstr: string) = discard
  proc nfOpName(adr: NfAddr) = discard

## Handle abort

proc nfAbort(reason: NfResult) =
  jmpPEnv(reason)
  
## Stack operation

proc nfPush(v: NfCell) =
  if nfCheck(dsp < NfDstackSize, NfAbortDstackOverrun):
    nfTrace("»" & fmt"{v:d}" & " ") 
    dstack[dsp] = v
    inc(dsp)
    when DEBUG: echo "Push dsp => ", dsp
  
proc nfPop(): NfCell =
  if nfCheck(dsp > 0'u, NfAbortDstackUnderrun):
    dec(dsp)
    when DEBUG: echo "Pop dsp => ", dsp
    let v = dstack[dsp]
    nfTrace("«" & fmt"{v:d}" & " ") 
    return v

proc nfPick(n: NfAddr): NfCell =
  if nfCheck(n < dsp, NfAbortDstackUnderrun):
    return dstack[dsp - n - 1]

proc nfPushr(v: NfCell) =
  if nfCheck(rsp < NfRstackSize, NfAbortRstackOverrun):
    nfTrace("r»" & fmt"{v:d}" & " ")
    rstack[rsp] = v
    inc(rsp)

proc nfPopr(): NfCell =
  when DEBUG: echo "nfPopr rsp => ", rsp
  if nfCheck(rsp > 0'u, NfAbortRstackUnderrun):
    dec(rsp)
    let v = rstack[rsp]
    nfTrace("r«" & fmt"{v:d}" & " ")
    return v
  
proc nfPickr(n: NfAddr): NfCell =
  when DEBUG: echo "nfPickr rsp => ", rsp
  if nfCheck(n < rsp, NfAbortRstackUnderrun):
    return rstack[rsp - n - 1]

## All access to dictionary memory

proc dictPutBytes(adr: NfAddr, buf: openArray[byte], len: int): NfAddr =
   var p = 0
   var a = adr
   var i = len
   if nfCheck(a < NfAddr(NfDictSize - len), NfAbortOutsideMem):
     when DEBUG2: echo "dictPutBytes adr => ", a, " buf => ", repr(buf), " len => ", len
     while i > 0:
       dict[a] = buf[p]
       a = a + NfAddr(1)
       inc(p)
       dec(i)
     return NfAddr(len)
   
proc dictGetBytes(adr: NfAddr, buf: var openArray[byte], len: int) =
  var p = 0
  var a = adr
  var l = len
  if nfCheck(a < NfAddr(NfDictSize - len), NfAbortOutsideMem):
    while l > 0:
      buf[p] = dict[a]
      inc(p)
      a = a + NfAddr(1)
      dec(l)
    
## zf_cells are encoded in the dictionary with a variable length:
##
## encode:
##
##    integer   0 ..   127  0xxxxxxx
##    integer 128 .. 16383  10xxxxxx xxxxxxxx
##    else                  11111111 <array of uint8, size is 8>

## Helper functions to handle between uint8 array and NfCell value
    
proc nfCellToArray2(v: NfCell): array[2, uint8] =
  var t: array[2, uint8]
  t[0] = uint8(v shr 8)
  t[1] = uint8(v)
  return t
  
proc nfArrayToCell2(a: array[2, uint8]): NfCell =
  var v = NfCell(a[0])
  v = (v shl 8) or NfCell(a[1])
  return v
  
proc nfCellToArray4(v: NfCell): array[4, uint8] =
  var t: array[4, uint8]
  t[0] = uint8(v shr 24)
  t[1] = uint8(v shr 16)
  t[2] = uint8(v shr 8)
  t[3] = uint8(v)
  return t

proc nfArrayToCell4(a: array[4, uint8]): NfCell =
  var t: array[2, uint8]
  t[0] = a[0]
  t[1] = a[1]
  let v1 = nfArrayToCell2(t)
  t[0] = a[2]
  t[1] = a[3]
  let v2 = nfArrayToCell2(t) 
  return (v1 shl 16) or v2
  
proc nfCellToArray8(v: NfCell): array[8, uint8] =
  var t: array[8, uint8]
  t[0] = uint8(v shr 56)
  t[1] = uint8(v shr 48)
  t[2] = uint8(v shr 40)
  t[3] = uint8(v shr 32)
  t[4] = uint8(v shr 24)
  t[5] = uint8(v shr 16)
  t[6] = uint8(v shr 8)
  t[7] = uint8(v)
  return t
   
proc nfArrayToCell8(a: array[8, uint8]): NfCell =
  var t: array[4, uint8]
  t[0] = a[0]
  t[1] = a[1]
  t[2] = a[2]
  t[3] = a[3]
  let v1 = nfArrayToCell4(t)
  t[0] = a[4]
  t[1] = a[5]
  t[2] = a[6]
  t[3] = a[7]
  let v2 = nfArrayToCell4(t)
  return (v1 shl 32) or v2
  
## Dictionary access covinient functions
  
proc dictPutCellTyped(adr: NfAddr, v: NfCell, size: NfMemSize): NfAddr =
  var vi: uint
  var t: array[2, uint8]

  nfTrace('\n' & "+" & fmt"{adr:#X}" & " " & fmt"{NfAddr(v):#X}")

  if size == NfMemSizeVar:
    #when DEBUG2: echo "dictPutCellTYped size => ", NfMemSizeVar, " v => ", v
    #when v is SomeUnsignedInt:
    if v >= 0 and  v < 16384:
      var vi = v
      #when DEBUG2: echo "dictPutCellTyped vi => ", vi
      if vi < 128:
        nfTrace(" ¹")
        t[0] = uint8(vi)
        return dictPutBytes(adr, t, 1)
      if vi < 16384:
        nfTrace(" ²")
        t[0] = uint8((vi shr 8) or 0x80)
        t[1] = uint8(vi)
        return dictPutBytes(adr, t, sizeof(t))
    nfTrace(" ⁵")
    t[0] = 0xff
    case sizeof(v)
    of 2:
      return dictPutBytes(adr + 0, t, 1) + dictPutBytes(adr + 1, nfCellToArray2(v), sizeof(v))
    of 4:
      return dictPutBytes(adr + 0, t, 1) + dictPutBytes(adr + 1, nfCellToArray4(v), sizeof(v))
    of 8:
      return dictPutBytes(adr + 0, t, 1) + dictPutBytes(adr + 1, nfCellToArray8(v), sizeof(v))
    else: discard  

  when NfEnableTypedMemAccess:
    if size == NfMemSizeCell:
      if sizeof(NfCell) == 2:
        return dictPutBytes(adr, nfCellToArray2(v), 2)
      elif sizeof(NfCell) == 4:
        return dictPutBytes(adr, nfCellToArray4(v), 4)
      elif sizeof(NfCell) == 8:
        return dictPutBytes(adr, nfCellToArray8(v), 8)
    elif size == NfMemSizeU8:
      var tmp: array[1, uint8]
      tmp[0] = uint8(vi)
      return dictPutBytes(adr, tmp, 1)
    elif size == NfMemSizeU16:
      return dictPutBytes(adr, nfCellToArray2(v), 2)
    elif size == NfMemSizeU32:
      return dictPutBytes(adr, nfCellToArray4(v), 4)
    elif size == NfMemSizeS8:
      var tmp: array[1, uint8]
      tmp[0] = uint8(vi)
      return dictPutBytes(adr, tmp, 1)
    elif size == NfMemSizeS16:
      return dictPutBytes(adr, nfCellToArray2(v), 2)
    elif size == NfMemSizeS32:
      return dictPutBytes(adr, nfCellToArray4(v), 4)
  nfAbort(NfAbortInvalidSize)
  return 0

proc dictGetCellTyped(adr: NfAddr, v: var NfCell, size: NfMemSize): NfAddr =
  var t: array[2, uint8]
  dictGetBytes(adr, t, sizeof(t))

  if size == NfMemSizeVar:
    if (t[0] and 0x80) != 0:
      #when DEBUG2: echo "dictGetCellTYped t => ", repr(t)
      #when DEBUG2: echo "dictGetCellTyped enter t[0] and 0x80 != 0"
      if t[0] == 0xff:
        #when DEBUG: echo "dictGetCellTyped t0 == 0xff sizeof(v) => ", sizeof(v)
        if sizeof(v) == 2: 
          var tmp: array[2, uint8]
          dictGetBytes(adr + 1, tmp, sizeof(v))
          v = nfArrayToCell2(tmp)
        elif sizeof(v) == 4:
          var tmp: array[4, uint8]
          dictGetBytes(adr + 1, tmp, sizeof(v))
          v = nfArrayToCell4(tmp)
        elif sizeof(v) == 8:
          var tmp: array[8, uint8]
          dictGetBytes(adr + 1, tmp, sizeof(v))
          v = nfArrayToCell8(tmp)
        return 1 + sizeof(v)
      else:
        v = (NfCell(t[0] and 0x3f) shl 8) + NfCell(t[1])
        return 2
    else:
      v = NfCell(t[0])
      return 1

  when NfEnableTypedMemAccess:
    if size == NfMemSizeCell:
      #when DEBUG: echo "dictGetCellTyped size => ", NfMemSizeCell
      if sizeof(NfCell) == 2:
        var t: array[2, uint8]
        dictGetBytes(adr, t, 2)
        v = nfArrayToCell2(t)
        return 2
      elif sizeof(NfCell) == 4:
        var t: array[4, uint8]
        dictGetBytes(adr, t, 4)
        v = nfArrayToCell4(t)
        return 4
      elif sizeof(NfCell) == 8:
        var t: array[8, uint8]
        dictGetBytes(adr, t, 8)
        v = nfArrayToCell8(t)
        return 8
    elif size == NfMemSizeU8:
      var tmp: array[1, uint8]
      dictGetBytes(adr, tmp, 1)
      v = NfCell(tmp[0])
      return 1
    elif size == NfMemSizeU16:
      var tmp: array[2, uint8]
      dictGetBytes(adr, tmp, 2)
      v = nfArrayToCell2(tmp)
      return 2
    elif size == NfMemSizeU32:
      var tmp: array[4, uint8]
      dictGetBytes(adr, tmp, 4)
      v = nfArrayToCell4(tmp)
      return 4
    elif size == NfMemSizeS8:
      var tmp: array[1, uint8]
      dictGetBytes(adr, tmp, 1)
      v = NfCell(tmp[0])
      return 1
    elif size == NfMemSizeS16:
      var tmp: array[2, uint8]
      dictGetBytes(adr, tmp, 2)
      v = nfArrayToCell2(tmp)
      return 2
    elif size == NfMemSizeS32:
      var tmp: array[4, uint8]
      dictGetBytes(adr, tmp, 4)
      v = nfArrayToCell4(tmp)
      return 4

  nfAbort(NfAbortInvalidSize)
  return 0

## Shortcut functions for cell access with variable cell size

proc dictPutCell(adr: NfAddr, v: NfCell): NfAddr =
  return dictPutCellTyped(adr, v, NfMemSizeVar)
  
proc dictGetCell(adr: NfAddr, v: var NfCell): NfAddr =
  return dictGetCellTyped(adr, v, NfMemSizeVar)
  
## Generic dictionary adding, these functions all add at the HERE pointer and
## increase the pointer

proc dictAddCellTyped(v: NfCell, size: NfMemSize) =
  HERE += dictPutCellTyped(HERE, v, size)
  #when DEBUG2: echo "dictAddCellTyped HERE => ", HERE, " v => ", v, " size => ", size
  nfTrace(" ")

proc dictAddCell(v: NfCell) =
  #when DEBUG2: echo "dictAddCell v => ", v
  dictAddCellTyped(v, NfMemSizeVar)

proc dictAddOp(op: NfAddr) =
  #dictAddCell(NfCell(op))
  dictAddCell(NfCell(op))
  let opname = nfOpName(op)
  nfTrace("+n" & opname & " ")

proc dictAddLit(v: NfCell) =
  dictAddOp(ord(PrimLIT))
  dictAddCell(v)

proc dictAddStr(s: string) =
  let l = s.len
  #when DEBUG2: echo "dictAddStr s => ", s, " HERE => ", HERE
  nfTrace('\n' & "+" & fmt"{HERE:#X}" & " " & fmt"{0:#X}" & " s " & s)
  var str: seq[uint8]
  for i in 0..l - 1:
    let v = uint8(ord(s[i]))
    str.add(v)
  HERE += dictPutBytes(HERE, str, l)

## Create new word, adjusting HERE and LATEST accordingly

proc nfCreate(name: string, flags: int) =
  let phere = HERE
  nfTrace("\n=== create " & name)
  dictAddCell(name.len or flags)
  dictAddCell(NfCell(LATEST))
  dictAddStr(name)
  LATEST = phere
  nfTrace("\n===")
  
## Find word in dictionary, returning address and execution token

proc nfFindWord(name: string, word, code: var NfAddr): int =
  var w = LATEST
  #when DEBUG: echo "FindWord LATEST => ", w

  while w > 0'u:    # ?TODO
    var link, d: NfCell
    var p = w
    p += dictGetCell(p, d)
    #when DEBUG: echo "FindWord p => ", p, " d => ", d
    p += dictGetCell(p, link)
    #when DEBUG: echo "FindWord p => ", p, " link => ", link
    let len = nfFlagLen(int(d))
    #when DEBUG: echo "FindWord name => ", name, " len => ", len, " name.len => ", name.len
    #when DEBUG:
    #  echo "FindWord name => ", name
    #  for c in items(name):
    #    stdout.write(ord(c))
    #    stdout.write(',')
    #  stdout.write('\n')
    #  var n = p
    #  for i in 0..len - 1:
    #    stdout.write(chr(dict[n]))
    #    inc(n)
    #  stdout.write('\n')
    if len == name.len:
      var name2 = newString(len)
      for i in 0..len - 1:
        name2[i] = chr(dict[p])
        inc(p)
      #when DEBUG: echo "FindWord name => ", name, " name2 => ", name2
      if name == name2:
        word = w
        #code = p + NfAddr(len)
        code = p
        #when DEBUG: echo "FindWord w => ", w, " code => ", code
        return 1
    w = NfAddr(link)
    #when DEBUG: echo "FindWord w => ", w
  return 0
  
## Set 'immediate' flag in last compiled word

proc nfMakeImmediate() =
  var lenflags: NfCell
  discard dictGetCell(LATEST, lenflags)
  discard dictPutCell(LATEST, (int(lenflags) or NfFlagImmediate))

## Inner interpreter

proc nfRun(input: string) =
  var inputbuf = input
  
  while ip != 0:
    var d: NfCell
    var i, origIp: NfAddr
    when DEBUG2: echo "Run ip => ", ip
    origIp = ip
    ip += dictGetCell(ip, d)
    var code = d
    when DEBUG2: echo "Run code => ", code, " ip => ", ip

    nfTrace('\n' & fmt"{ip:#X}" & " " & fmt"{code:#X}" & " ")
    i = 0
    while i < rsp:
      nfTrace("┊  ")
      inc(i)
    #ip += l

    if code < ord(PrimCOUNT): 
      #when DEBUG: echo "Run enter doPrim code => ", code, " inputbuf => ", inputbuf
      doPrim(Primitives(code), inputbuf)
      #when DEBUG2: echo "After doPrim ip => ", ip
      # If the prim requests input, restore IP so that the
      # next time around we call the same prim again

      if inputState != NfInputInterpret:
        when DEBUG2: echo "Run inputState not interpret"
        ip = origIp
        break
    else:
      let name = nfOpName(NfAddr(code))
      nfTrace(name & "/" & fmt"{code:#X}" & " ")
      nfPushr(NfCell(ip))
      #when DEBUG: echo "Run pushr ip => ", ip, " code => ", code
      ip = NfAddr(code)

  #inputbuf = ""
    
## Execute bytecode from given address

proc execute(adr: NfAddr) =
  ip = adr
  rsp = 0
  nfPushr(0)

  let name = nfOpName(ip)
  nfTrace('\n' & "[" & name & "/" & fmt"{ip:#X}" & "] ")
  when DEBUG2: echo "execute call run"
  nfRun("")

proc peek(adr: NfAddr, val: var NfCell, len: int): NfAddr =
  if adr < UservarCount:
    #val = NfCell(u[adr])
    val = getUservar(adr)
    return 1
  else:
    let a = adr
    return dictGetCellTyped(a, val, NfMemSize(len))
    
## Run primitive opcode

proc doPrim(op: Primitives, input: var string) =
  var d1, d2, d3: NfCell
  var adr, len: NfAddr

  let opr = nfOpName(NfAddr(ord(op)))
  nfTrace("(" & opr & ")")
  
  case op:
  of PrimCOL:
    when DEBUG: echo "doPrim col input => ", input
    if input == "": inputState = NfInputPassWord
    else:
      nfCreate(input, 0)
      COMPILING = 1
  of PrimLTZ:
    when DEBUG: echo "doPrim ltz"
    let n = nfPop()
    if n < 0: nfPush(1)
    else: nfPush(0)
  of PrimSEMICOL:
    when DEBUG: echo "doPrim SEMICOL"
    dictAddOp(ord(PrimEXIT))
    nfTrace("\n===")
    #when DEBUG:
    #  echo "doPrim semicolon => "
    #  for d in items(dict[LATEST..^1]):
    #    echo d
    COMPILING = 0
  of PrimLIT:
    ip += dictGetCell(ip, d1)
    when DEBUG: echo "doPrim Lit ip => ", ip, " d1 => ", d1
    nfPush(d1)
  of PrimEXIT:
    when DEBUG:
      echo "doPrim exit"
      let ds = nfDsp()
      if int(ds) > 0:
        for d in 0..ds - 1:
          stdout.write("dsp" & $d & ": " & $dstack[d] & " ")
        stdout.write('\n')
    ip = NfAddr(nfPopr())
  of PrimLEN:
    len = NfAddr(nfPop())
    adr = NfAddr(nfPop())
    let p = peek(adr, d1, int(len))
    when DEBUG: echo "doPrim len len => ", len, " adr => ", adr, " peek => ", p
    nfPush(NfCell(p))
  of PrimPEEK:
    len = NfAddr(nfPop())
    adr = NfAddr(nfPop())
    discard peek(adr, d1, int(len))
    when DEBUG: echo "doPrim peek len => ", len, " adr => ", adr, " d1 => ", d1
    nfPush(d1)
  of PrimPOKE:
    d2 = nfPop()
    adr = NfAddr(nfPop())
    d1 = nfPop()
    when DEBUG2: echo "doPrim poke d1 => ", d1, " adr => ", adr, " d2 => ", d2
    if adr < UservarCount:
      #u[adr] = NfAddr(d1)
      setUservar(adr, d1)
    else:
      discard dictPutCellTyped(adr, d1, NfMemSize(d2))
  of PrimSWAP:
    when DEBUG: echo "doPrim swap"
    d1 = nfPop()
    d2 = nfPop()
    nfPush(d1)
    nfPush(d2)
  of PrimROT:
    when DEBUG: echo "doPrim rot"
    d1 = nfPop()
    d2 = nfPop()
    d3 = nfPop()
    nfPush(d2)
    nfPush(d1)
    nfPush(d3)
  of PrimDROP:
    when DEBUG: echo "doPrim drop"
    discard nfPop()
  of PrimDUP:
    when DEBUG: echo "doPrim dup"
    d1 = nfPop()
    nfPush(d1)
    nfPush(d1)
  of PrimADD:
    when DEBUG: echo "doPrim add"
    d1 = nfPop()
    d2 = nfPop()
    nfPush(d1 + d2)
  of PrimSYS:
    d1 = nfPop()
    when DEBUG: echo "doPrim sys id => ", d1
    inputState = nfHostSys(cast[NfSyscallId](d1), input)
    if inputState != NfInputInterpret:
      nfPush(d1)
  of PrimPICK:
    when DEBUG: echo "doPrim pick"
    adr = NfAddr(nfPop())
    nfPush(nfPick(adr))
  of PrimPICKR:
    when DEBUG: echo "doPrim pickr"
    adr = NfAddr(nfPop())
    nfPush(nfPickr(adr))
  of PrimSUB:
    when DEBUG: echo "doPrim sub"
    d1 = nfPop()
    d2 = nfPop()
    nfPush(d2 - d1)
  of PrimMUL:
    when DEBUG: echo "doPrim mul"
    nfPush(nfPop() * nfPop())
  of PrimDIV:
    when DEBUG: echo "doPrim div"
    d2 = nfPop()
    if d2 == 0: nfAbort(NfAbortDivisionByZero)
    d1 = nfPop()
    nfPush(d1 div d2)
  of PrimMOD:
    when DEBUG: echo "doPrim mod"
    d2 = nfPop()
    if d2 == 0: nfAbort(NfAbortDivisionByZero)
    d1 = nfPop()
    nfPush(d1 mod d2)
  of PrimIMMEDIATE:
    when DEBUG: echo "doPrim immediate"
    nfMakeImmediate()
  of PrimJMP:
    ip += dictGetCell(ip, d1)
    when DEBUG: echo "doPrim jmp ip => ", ip, " d1 => ", d1
    nfTrace("ip " & fmt"{ip:#X}" & "=>" & fmt"{NfAddr(d1):#X}")
    ip = NfAddr(d1)
  of PrimJMP0:
    ip += dictGetCell(ip, d1)
    let v = nfPop()
    when DEBUG:
      echo "doPrim jmp0  ip => ", ip, " d1 => ", d1, " pop() => ", v
    if v == 0:
      nfTrace("ip " & fmt"{ip:#X}" & "=>" & fmt"{NfAddr(d1):#X}")
      ip = NfAddr(d1)
  of PrimTICK:
    ip += dictGetCell(ip, d1)
    when DEBUG: echo "doPrim Tick ip => ", ip, " d1 => ", d1
    let m = nfOpName(NfAddr(d1))
    nfTrace(m)
    nfPush(d1)
  of PrimCOMMA:
    when DEBUG: echo "doPrim comma"
    d2 = nfPop()
    d1 = nfPop()
    dictAddCellTyped(d1, NfMemSize(d2))
  of PrimCOMMENT:
    when DEBUG: echo "doPrim COMMENT input => ", input
    if input == "" or input[0] != ')':
      inputState = NfInputPassChar
  of PrimPUSHR:
    when DEBUG: echo "doPrim pushr"
    nfPushr(nfPop())
  of PrimPOPR:
    when DEBUG: echo "doPrim popr"
    nfPush(nfPopr())
  of PrimEQUAL:
    when DEBUG: echo "doPrim equal"
    let b = (nfPop() == nfPop())
    let v = if b: 1 else: 0
    nfPush(NfCell(v))
  of PrimKEY:
    when DEBUG:
      echo "doPrim key input => ", input
    if input == "":
      inputState = NfInputPassChar
    else:     # convert ascii, utf8 character to Rune
      nfPush(ord(input[0]))
      input = ""
  of PrimLITS:
    when DEBUG: echo "doPrim lits"
    ip += dictGetCell(ip, d1)
    nfPush(NfCell(ip))
    nfPush(d1)
    ip += NfAddr(d1)
  of PrimAND:
    d2 = nfPop()
    d1 = nfPop()
    let v = d2 and d1
    when DEBUG: echo "doPrim and d2 => ", d2, " d1 => ", d1, " d2 and d1 => ", v
    nfPush(v)
  else:
    when DEBUG: echo "doPrim id => ", op
    nfAbort(NfAbortInternalError)
  
## Handle incoming word. Compile or interpreted the word, or pass it to a
## deferred primitive if it requested a word from the input stream.

proc handleWord(buf: string) =
  var w, c: NfAddr
  c = 0
  var found: int

  # If a word was requested by an earlier operation, resume with the new word

  if inputState == NfInputPassWord:
    inputState = NfInputInterpret
    when DEBUG: echo "handle word call run"
    nfRun(buf)
    return
    # Look up the word in the dictionary

  else:
    found = nfFindWord(buf, w, c)
    
  #when DEBUG: echo "handleWord found => ", found
  if found == 1:
    
    # Word found: compile or execute, depending on flags and state

    var d: NfCell
    var flags: int
    discard dictGetCell(w, d)
    flags = int(d)

    when DEBUG2: echo "HandleWord COMPILING => ", COMPILING, " POSTPONE => ", POSTPONE, " immflags => ", (flags and NfFlagImmediate)
    if COMPILING == 1 and (POSTPONE == 1 or (flags and NfFlagImmediate) == 0):
      if (flags and NfFlagPrim) != 0:
        when DEBUG2: echo "HandleWord prim => ", buf, " c => ", c, " d => ", d
        discard dictGetCell(c, d)
        dictAddOp(NfAddr(d))
      else:
        when DEBUG2: echo "HandleWord word => ", buf
        dictAddOp(c)
      POSTPONE = 0
    else:
      when DEBUG2: echo "HandleWord execute => ", buf, " code => ", c
      execute(c)
  else:

    # Word not found: try to convert to a number and compile or push, depending
    # on state

    var v = nfHostParseNum(buf)
    when DEBUG2: echo "handleWord not found word buf => ", buf, " v => ", v
    if COMPILING == 1:
      when v is SomeUnsignedInt:
        if v < 16384: dictAddLit(NfAddr(v))
        else: dictAddLit(v)
      else: dictAddLit(v)
    else: nfPush(v)
    
## Handle one character. Split into words to pass to handle_word(), or pass the
## char to a deferred prim if it requested a character from the input stream

proc handleChar(c: char, buf: var string, len: var int) =
  #if inputState == NfInputPassChar:
  #  inputState = NfInputInterpret
  #  nfRun($c)
  if c != '\0' and not isSpaceAscii(c):
    if len < buf.len - 1:
      buf[len] = c
      inc(len)
      buf[len] = '\0'
    #when DEBUG: echo "handleChar buf => ", buf
  else:
    #when DEBUG: echo "handleChar goto handleWord"
    if len > 0:
      handleWord(buf[0..len - 1])
      len = 0

##  ZForth API functions

## Initialisation

proc nfInit*(trace: bool = false) =
  HERE = UservarCount
  LATEST = 0
  TRACE = if trace: 1 else: 0
  dsp = 0
  rsp = 0
  COMPILING = 0
  POSTPONE = 0
  BASE = 10
  
when NfEnableBootstrap:
  
  ## Functions for bootstrapping the dictionary by adding all primitive ops and the
  ## user variables.

  proc addPrim(name: string, op: Primitives) =
    var name1 = name
    var imm = false
    when DEBUG2: echo "addPrim name => ", name, " op => ", op

    if name[0] == '_':
      name1 = name[1..^1]
      imm = true

    nfCreate(name1, NfFlagPrim)
    dictAddOp(NfAddr(ord(op)))
    dictAddOp(NfAddr(ord(PrimEXIT)))
    if imm: nfMakeImmediate()
    
  proc addUservar(name: string, adr: NfAddr) =
    when DEBUG2: echo "addUservar name => ", name, " adr => ", adr
    nfCreate(name, 0)
    dictAddLit(NfCell(adr))
    dictAddOp(NfAddr(ord(PrimEXIT)))
    
  proc nfBootstrap*() =
    # PrevEnv object

    prevenv = new(PrevEnv)

    # Add primitives and user variables to dictionary */

    for i in keys(PrimNames):
      addPrim(PrimNames[i], Primitives(i))
    
    for i in keys(UservarNames):
      addUservar(UservarNames[i], NfAddr(i))

else:
  proc nfBootstrap() = 
    prevenv = new(PrevEnv)
    
## Eval forth string

proc nfEval*(buf: string): bool =
  var wbuf = newString(32)
  var input: string
  var len = 0

  result = true
  #when DEBUG: echo "nfEval buf len => ", buf.len
  if setPEnv():
    var i = 0
    while i < buf.len:
      input = buf[i..buf.len - 1]
      if inputState == NfInputPassChar:
        inputState = NfInputInterpret
        #when DEBUG: echo "eval call run"
        nfRun(input)
      else:
        handleChar(input[0], wbuf, len)
      if nfresult != NfOk: return false
      inc(i)
  else:
    COMPILING = 0
    rsp = 0
    dsp = 0
    result = false
  
# nfDump: no need
