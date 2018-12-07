# Package

version       = "0.1.0"
author        = "yoshinori arai"
description   = "forth interpreter for ned based on zforth"
license       = "GPL-3.0"
srcDir        = "src"
installExt    = @["nim"]
bin           = @["nforth"]


# Dependencies

requires "nim >= 0.19.0"
