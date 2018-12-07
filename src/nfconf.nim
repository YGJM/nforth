
const DEBUG = false
const DEBUG2 = false

## https://github.com/zevv/zForth.git
## zfconf/zforth

##  Set to true to add tracing support for debugging and inspection. 

const NfEnableTrace* = true

##  Set to true to add boundary checks to stack operations. 

const NfEnableBoundaryChecks* = true

##  Set to true to enable bootstrapping of the forth dictionary by adding the
##  primitives and user veriables. 

const NfEnableBootstrap* = true

##  Set to true to enable typed access to memory. This allows memory read and write 
##  of signed and unsigned memory of 8, 16 and 32 bits width, as well as the NfCell 
##  type. This adds a few hundred bytes of .text. Check the memaccess.zf file for
##  examples how to use these operations

const NfEnableTypedMemAccess* = true

##  Type to use for the basic cell, data stack and return stack. Choose a signed
##  integer type that suits your needs, or 'float' or 'double' if you need
##  floating point numbers

type NfCell* = int64

#const NfCellFmt* = "32d"

##  The type to use for adresses. 'unsigned int' is usually a good
##  choice for best performance and smallest code size

type NfAddr* = uint

#const NfAddrFmt* = "X"

##  Number of cells in memory regions: dictionary size is given in bytes, stack
##  sizes are number of elements

const
  NfDictSize* = 4096
  NfDstackSize* = 32
  NfRstackSize* = 32

## End of zfconf
 
