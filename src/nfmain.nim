import strformat
import nforth

#const DEBUG = true

var initok = false
var bootstrapok = false

proc nfreadLine*(prompt: string, skk: bool = false): string =
  var input: seq[Rune]
  result = ""
  input = term.lineEdit(prompt, skk = skk)
  #when DEBUG: echo "input => ", repr(input)
  stdout.write('\n')
  term.addIHistory(input)
  for r in input: result.add(toUTF8(r))

##
## nforth main
##

proc nforth(trace: bool = false, loadFname: string = "", includes: varargs[string]) =
  # Initialize zforth

  if not initok:
    nfInit(trace)
    initok = true

  # Load dict from disk if requested, otherwise bootstrap forth dictionary

  if loadFname != "": nfLoad(loadFname)
  else:
    if not bootstrapok:
      nfBootstrap()
      bootstrapok = true
    #when DEBUG:
    #  echo "Dictionary contents => ", repr(dict)
  
  # include files

  let forthdir = getEnv("NEDDIR")
  if forthdir.len == 0:
    for i in includes: nfInclude(i)
  else:
    for i in includes:
      nfinclude(forthdir & "/" & i)

  # Interactive interpreter:read a line and pass to zf_eval() for evaluation
  var buf = ""
  var line = 0
  while not nforth.quitok:
    #stdout.write("zf> ")
    let pt = "zf[" & $nfDsp() & "]> "
    buf = nfreadLine(prompt = pt)
    buf.add('\0')
    #when DEBUG: echo "buf => ", buf
    if nfDoEval("stdin", line, buf):
      echo "ok"
      inc(line)
    buf = ""

proc nforthLoop*() =
  if nforth.quitok:
    nforth.quitok = false
    nforth(false, "", [])
  else:
    nforth(false, "", ["forth/core.zf", "forth/dict.zf"])
#[
when isMainModule:
  import terminal, unicode, strutils, strformat
  import term, nforth
  #block readLine:
  #  let input = readLine("test> ")
  #  echo "input => ", input

  block nfMain:
    #nfMain()
    nforth(false, "", ["forth/core.zf", "forth/dict.zf"])    # , "forth/memaccess.zf"])
]#
