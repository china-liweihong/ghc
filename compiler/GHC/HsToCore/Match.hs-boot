module GHC.HsToCore.Match where

import GhcPrelude
import Name     ( Name )
import Var      ( Id )
import TcType   ( Type )
import GHC.HsToCore.Monad  ( DsM, EquationInfo, MatchResult )
import GHC.Core  ( CoreExpr )
import GHC.Hs   ( LPat, HsMatchContext, MatchGroup, LHsExpr )
import GHC.Hs.Extension ( GhcTc )

match   :: [Id]
        -> Type
        -> [EquationInfo]
        -> DsM MatchResult

matchWrapper
        :: HsMatchContext Name
        -> Maybe (LHsExpr GhcTc)
        -> MatchGroup GhcTc (LHsExpr GhcTc)
        -> DsM ([Id], CoreExpr)

matchSimply
        :: CoreExpr
        -> HsMatchContext Name
        -> LPat GhcTc
        -> CoreExpr
        -> CoreExpr
        -> DsM CoreExpr

matchSinglePatVar
        :: Id
        -> HsMatchContext Name
        -> LPat GhcTc
        -> Type
        -> MatchResult
        -> DsM MatchResult
