module GHC.Iface.Load where

import GHC.Types.Module (Module)
import GHC.Tc.Utils.Monad (IfM)
import GHC.Driver.Types (ModIface)
import Outputable (SDoc)

loadSysInterface :: SDoc -> Module -> IfM lcl ModIface
