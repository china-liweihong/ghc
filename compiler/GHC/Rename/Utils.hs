{-

This module contains miscellaneous functions related to renaming.

-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

module GHC.Rename.Utils (
        checkDupRdrNames, checkShadowedRdrNames,
        checkDupNames, checkDupAndShadowedNames, dupNamesErr,
        checkTupSize,
        addFvRn, mapFvRn, mapMaybeFvRn,
        warnUnusedMatches, warnUnusedTypePatterns,
        warnUnusedTopBinds, warnUnusedLocalBinds,
        checkUnusedRecordWildcard,
        mkFieldEnv,
        unknownSubordinateErr, badQualBndrErr, typeAppErr,
        HsDocContext(..), pprHsDocContext,
        inHsDocContext, withHsDocContext,

        newLocalBndrRn, newLocalBndrsRn,

        bindLocalNames, bindLocalNamesFV,

        addNameClashErrRn, extendTyVarEnvFVRn

)

where


import GhcPrelude

import GHC.Hs
import RdrName
import GHC.Driver.Types
import TcEnv
import TcRnMonad
import Name
import NameSet
import NameEnv
import GHC.Core.DataCon
import SrcLoc
import Outputable
import Util
import BasicTypes       ( TopLevelFlag(..) )
import ListSetOps       ( removeDups )
import GHC.Driver.Session
import FastString
import Control.Monad
import Data.List
import Constants        ( mAX_TUPLE_SIZE )
import qualified Data.List.NonEmpty as NE
import qualified GHC.LanguageExtensions as LangExt

{-
*********************************************************
*                                                      *
\subsection{Binding}
*                                                      *
*********************************************************
-}

newLocalBndrRn :: LocatedA RdrName -> RnM Name
-- Used for non-top-level binders.  These should
-- never be qualified.
newLocalBndrRn (L loc rdr_name)
  | Just name <- isExact_maybe rdr_name
  = return name -- This happens in code generated by Template Haskell
                -- See Note [Binders in Template Haskell] in Convert.hs
  | otherwise
  = do { unless (isUnqual rdr_name)
                (addErrAt (locA loc) (badQualBndrErr rdr_name))
       ; uniq <- newUnique
       ; return (mkInternalName uniq (rdrNameOcc rdr_name) (locA loc)) }

newLocalBndrsRn :: [LocatedA RdrName] -> RnM [Name]
newLocalBndrsRn = mapM newLocalBndrRn

bindLocalNames :: [Name] -> RnM a -> RnM a
bindLocalNames names enclosed_scope
  = do { lcl_env <- getLclEnv
       ; let th_level  = thLevel (tcl_th_ctxt lcl_env)
             th_bndrs' = extendNameEnvList (tcl_th_bndrs lcl_env)
                           [ (n, (NotTopLevel, th_level)) | n <- names ]
             rdr_env'  = extendLocalRdrEnvList (tcl_rdr lcl_env) names
       ; setLclEnv (lcl_env { tcl_th_bndrs = th_bndrs'
                            , tcl_rdr      = rdr_env' })
                    enclosed_scope }

bindLocalNamesFV :: [Name] -> RnM (a, FreeVars) -> RnM (a, FreeVars)
bindLocalNamesFV names enclosed_scope
  = do  { (result, fvs) <- bindLocalNames names enclosed_scope
        ; return (result, delFVs names fvs) }

-------------------------------------

extendTyVarEnvFVRn :: [Name] -> RnM (a, FreeVars) -> RnM (a, FreeVars)
extendTyVarEnvFVRn tyvars thing_inside = bindLocalNamesFV tyvars thing_inside

-------------------------------------
checkDupRdrNames :: [LocatedA RdrName] -> RnM ()
-- Check for duplicated names in a binding group
checkDupRdrNames rdr_names_w_loc
  = mapM_ (dupNamesErr getLocA) dups
  where
    (_, dups) = removeDups (\n1 n2 -> unLoc n1 `compare` unLoc n2) rdr_names_w_loc

checkDupNames :: [Name] -> RnM ()
-- Check for duplicated names in a binding group
checkDupNames names = check_dup_names (filterOut isSystemName names)
                -- See Note [Binders in Template Haskell] in Convert

check_dup_names :: [Name] -> RnM ()
check_dup_names names
  = mapM_ (dupNamesErr nameSrcSpan) dups
  where
    (_, dups) = removeDups (\n1 n2 -> nameOccName n1 `compare` nameOccName n2) names

---------------------
checkShadowedRdrNames :: [LocatedA RdrName] -> RnM ()
checkShadowedRdrNames loc_rdr_names
  = do { envs <- getRdrEnvs
       ; checkShadowedOccs envs get_loc_occ filtered_rdrs }
  where
    filtered_rdrs = filterOut (isExact . unLoc) loc_rdr_names
                -- See Note [Binders in Template Haskell] in Convert
    get_loc_occ (L loc rdr) = (locA loc,rdrNameOcc rdr)

checkDupAndShadowedNames :: (GlobalRdrEnv, LocalRdrEnv) -> [Name] -> RnM ()
checkDupAndShadowedNames envs names
  = do { check_dup_names filtered_names
       ; checkShadowedOccs envs get_loc_occ filtered_names }
  where
    filtered_names = filterOut isSystemName names
                -- See Note [Binders in Template Haskell] in Convert
    get_loc_occ name = (nameSrcSpan name, nameOccName name)

-------------------------------------
checkShadowedOccs :: (GlobalRdrEnv, LocalRdrEnv)
                  -> (a -> (SrcSpan, OccName))
                  -> [a] -> RnM ()
checkShadowedOccs (global_env,local_env) get_loc_occ ns
  = whenWOptM Opt_WarnNameShadowing $
    do  { traceRn "checkShadowedOccs:shadow" (ppr (map get_loc_occ ns))
        ; mapM_ check_shadow ns }
  where
    check_shadow n
        | startsWithUnderscore occ = return ()  -- Do not report shadowing for "_x"
                                                -- See #3262
        | Just n <- mb_local = complain [text "bound at" <+> ppr (nameSrcLoc n)]
        | otherwise = do { gres' <- filterM is_shadowed_gre gres
                         ; complain (map pprNameProvenance gres') }
        where
          (loc,occ) = get_loc_occ n
          mb_local  = lookupLocalRdrOcc local_env occ
          gres      = lookupGRE_RdrName (mkRdrUnqual occ) global_env
                -- Make an Unqualified RdrName and look that up, so that
                -- we don't find any GREs that are in scope qualified-only

          complain []      = return ()
          complain pp_locs = addWarnAt (Reason Opt_WarnNameShadowing)
                                       loc
                                       (shadowedNameWarn occ pp_locs)

    is_shadowed_gre :: GlobalRdrElt -> RnM Bool
        -- Returns False for record selectors that are shadowed, when
        -- punning or wild-cards are on (cf #2723)
    is_shadowed_gre gre | isRecFldGRE gre
        = do { dflags <- getDynFlags
             ; return $ not (xopt LangExt.RecordPuns dflags
                             || xopt LangExt.RecordWildCards dflags) }
    is_shadowed_gre _other = return True


{-
************************************************************************
*                                                                      *
\subsection{Free variable manipulation}
*                                                                      *
************************************************************************
-}

-- A useful utility
addFvRn :: FreeVars -> RnM (thing, FreeVars) -> RnM (thing, FreeVars)
addFvRn fvs1 thing_inside = do { (res, fvs2) <- thing_inside
                               ; return (res, fvs1 `plusFV` fvs2) }

mapFvRn :: (a -> RnM (b, FreeVars)) -> [a] -> RnM ([b], FreeVars)
mapFvRn f xs = do stuff <- mapM f xs
                  case unzip stuff of
                      (ys, fvs_s) -> return (ys, plusFVs fvs_s)

mapMaybeFvRn :: (a -> RnM (b, FreeVars)) -> Maybe a -> RnM (Maybe b, FreeVars)
mapMaybeFvRn _ Nothing = return (Nothing, emptyFVs)
mapMaybeFvRn f (Just x) = do { (y, fvs) <- f x; return (Just y, fvs) }

{-
************************************************************************
*                                                                      *
\subsection{Envt utility functions}
*                                                                      *
************************************************************************
-}

warnUnusedTopBinds :: [GlobalRdrElt] -> RnM ()
warnUnusedTopBinds gres
    = whenWOptM Opt_WarnUnusedTopBinds
    $ do env <- getGblEnv
         let isBoot = tcg_src env == HsBootFile
         let noParent gre = case gre_par gre of
                            NoParent -> True
                            _        -> False
             -- Don't warn about unused bindings with parents in
             -- .hs-boot files, as you are sometimes required to give
             -- unused bindings (trac #3449).
             -- HOWEVER, in a signature file, you are never obligated to put a
             -- definition in the main text.  Thus, if you define something
             -- and forget to export it, we really DO want to warn.
             gres' = if isBoot then filter noParent gres
                               else                 gres
         warnUnusedGREs gres'


-- | Checks to see if we need to warn for -Wunused-record-wildcards or
-- -Wredundant-record-wildcards
checkUnusedRecordWildcard :: SrcSpan
                          -> FreeVars
                          -> Maybe [Name]
                          -> RnM ()
checkUnusedRecordWildcard _ _ Nothing    = return ()
checkUnusedRecordWildcard loc _ (Just [])  = do
  -- Add a new warning if the .. pattern binds no variables
  setSrcSpan loc $ warnRedundantRecordWildcard
checkUnusedRecordWildcard loc fvs (Just dotdot_names) =
  setSrcSpan loc $ warnUnusedRecordWildcard dotdot_names fvs


-- | Produce a warning when the `..` pattern binds no new
-- variables.
--
-- @
--   data P = P { x :: Int }
--
--   foo (P{x, ..}) = x
-- @
--
-- The `..` here doesn't bind any variables as `x` is already bound.
warnRedundantRecordWildcard :: RnM ()
warnRedundantRecordWildcard =
  whenWOptM Opt_WarnRedundantRecordWildcards
            (addWarn (Reason Opt_WarnRedundantRecordWildcards)
                     redundantWildcardWarning)


-- | Produce a warning when no variables bound by a `..` pattern are used.
--
-- @
--   data P = P { x :: Int }
--
--   foo (P{..}) = ()
-- @
--
-- The `..` pattern binds `x` but it is not used in the RHS so we issue
-- a warning.
warnUnusedRecordWildcard :: [Name] -> FreeVars -> RnM ()
warnUnusedRecordWildcard ns used_names = do
  let used = filter (`elemNameSet` used_names) ns
  traceRn "warnUnused" (ppr ns $$ ppr used_names $$ ppr used)
  warnIfFlag Opt_WarnUnusedRecordWildcards (null used)
    unusedRecordWildcardWarning



warnUnusedLocalBinds, warnUnusedMatches, warnUnusedTypePatterns
  :: [Name] -> FreeVars -> RnM ()
warnUnusedLocalBinds   = check_unused Opt_WarnUnusedLocalBinds
warnUnusedMatches      = check_unused Opt_WarnUnusedMatches
warnUnusedTypePatterns = check_unused Opt_WarnUnusedTypePatterns

check_unused :: WarningFlag -> [Name] -> FreeVars -> RnM ()
check_unused flag bound_names used_names
  = whenWOptM flag (warnUnused flag (filterOut (`elemNameSet` used_names)
                                               bound_names))

-------------------------
--      Helpers
warnUnusedGREs :: [GlobalRdrElt] -> RnM ()
warnUnusedGREs gres = mapM_ warnUnusedGRE gres

warnUnused :: WarningFlag -> [Name] -> RnM ()
warnUnused flag names = do
    fld_env <- mkFieldEnv <$> getGlobalRdrEnv
    mapM_ (warnUnused1 flag fld_env) names

warnUnused1 :: WarningFlag -> NameEnv (FieldLabelString, Name) -> Name -> RnM ()
warnUnused1 flag fld_env name
  = when (reportable name occ) $
    addUnusedWarning flag
                     occ (nameSrcSpan name)
                     (text $ "Defined but not used" ++ opt_str)
  where
    occ = case lookupNameEnv fld_env name of
              Just (fl, _) -> mkVarOccFS fl
              Nothing      -> nameOccName name
    opt_str = case flag of
                Opt_WarnUnusedTypePatterns -> " on the right hand side"
                _ -> ""

warnUnusedGRE :: GlobalRdrElt -> RnM ()
warnUnusedGRE gre@(GRE { gre_name = name, gre_lcl = lcl, gre_imp = is })
  | lcl       = do fld_env <- mkFieldEnv <$> getGlobalRdrEnv
                   warnUnused1 Opt_WarnUnusedTopBinds fld_env name
  | otherwise = when (reportable name occ) (mapM_ warn is)
  where
    occ = greOccName gre
    warn spec = addUnusedWarning Opt_WarnUnusedTopBinds occ span msg
        where
           span = importSpecLoc spec
           pp_mod = quotes (ppr (importSpecModule spec))
           msg = text "Imported from" <+> pp_mod <+> ptext (sLit "but not used")

-- | Make a map from selector names to field labels and parent tycon
-- names, to be used when reporting unused record fields.
mkFieldEnv :: GlobalRdrEnv -> NameEnv (FieldLabelString, Name)
mkFieldEnv rdr_env = mkNameEnv [ (gre_name gre, (lbl, par_is (gre_par gre)))
                               | gres <- occEnvElts rdr_env
                               , gre <- gres
                               , Just lbl <- [greLabel gre]
                               ]

-- | Should we report the fact that this 'Name' is unused? The
-- 'OccName' may differ from 'nameOccName' due to
-- DuplicateRecordFields.
reportable :: Name -> OccName -> Bool
reportable name occ
  | isWiredInName name = False    -- Don't report unused wired-in names
                                  -- Otherwise we get a zillion warnings
                                  -- from Data.Tuple
  | otherwise = not (startsWithUnderscore occ)

addUnusedWarning :: WarningFlag -> OccName -> SrcSpan -> SDoc -> RnM ()
addUnusedWarning flag occ span msg
  = addWarnAt (Reason flag) span $
    sep [msg <> colon,
         nest 2 $ pprNonVarNameSpace (occNameSpace occ)
                        <+> quotes (ppr occ)]

unusedRecordWildcardWarning :: SDoc
unusedRecordWildcardWarning =
  wildcardDoc $ text "No variables bound in the record wildcard match are used"

redundantWildcardWarning :: SDoc
redundantWildcardWarning =
  wildcardDoc $ text "Record wildcard does not bind any new variables"

wildcardDoc :: SDoc -> SDoc
wildcardDoc herald =
  herald
    $$ nest 2 (text "Possible fix" <> colon <+> text "omit the"
                                            <+> quotes (text ".."))

addNameClashErrRn :: RdrName -> [GlobalRdrElt] -> RnM ()
addNameClashErrRn rdr_name gres
  | all isLocalGRE gres && not (all isRecFldGRE gres)
               -- If there are two or more *local* defns, we'll have reported
  = return ()  -- that already, and we don't want an error cascade
  | otherwise
  = addErr (vcat [ text "Ambiguous occurrence" <+> quotes (ppr rdr_name)
                 , text "It could refer to"
                 , nest 3 (vcat (msg1 : msgs)) ])
  where
    (np1:nps) = gres
    msg1 =  text "either" <+> ppr_gre np1
    msgs = [text "    or" <+> ppr_gre np | np <- nps]
    ppr_gre gre = sep [ pp_gre_name gre <> comma
                      , pprNameProvenance gre]

    -- When printing the name, take care to qualify it in the same
    -- way as the provenance reported by pprNameProvenance, namely
    -- the head of 'gre_imp'.  Otherwise we get confusing reports like
    --   Ambiguous occurrence ‘null’
    --   It could refer to either ‘T15487a.null’,
    --                            imported from ‘Prelude’ at T15487.hs:1:8-13
    --                     or ...
    -- See #15487
    pp_gre_name gre@(GRE { gre_name = name, gre_par = parent
                         , gre_lcl = lcl, gre_imp = iss })
      | FldParent { par_lbl = Just lbl } <- parent
      = text "the field" <+> quotes (ppr lbl)
      | otherwise
      = quotes (pp_qual <> dot <> ppr (nameOccName name))
      where
        pp_qual | lcl
                = ppr (nameModule name)
                | imp : _ <- iss  -- This 'imp' is the one that
                                  -- pprNameProvenance chooses
                , ImpDeclSpec { is_as = mod } <- is_decl imp
                = ppr mod
                | otherwise
                = pprPanic "addNameClassErrRn" (ppr gre $$ ppr iss)
                  -- Invariant: either 'lcl' is True or 'iss' is non-empty

shadowedNameWarn :: OccName -> [SDoc] -> SDoc
shadowedNameWarn occ shadowed_locs
  = sep [text "This binding for" <+> quotes (ppr occ)
            <+> text "shadows the existing binding" <> plural shadowed_locs,
         nest 2 (vcat shadowed_locs)]


unknownSubordinateErr :: SDoc -> RdrName -> SDoc
unknownSubordinateErr doc op    -- Doc is "method of class" or
                                -- "field of constructor"
  = quotes (ppr op) <+> text "is not a (visible)" <+> doc


dupNamesErr :: Outputable n => (n -> SrcSpan) -> NE.NonEmpty n -> RnM ()
dupNamesErr get_loc names
  = addErrAt big_loc $
    vcat [text "Conflicting definitions for" <+> quotes (ppr (NE.head names)),
          locations]
  where
    locs      = map get_loc (NE.toList names)
    big_loc   = foldr1 combineSrcSpans locs
    locations = text "Bound at:" <+> vcat (map ppr (sortBy SrcLoc.leftmost_smallest locs))

badQualBndrErr :: RdrName -> SDoc
badQualBndrErr rdr_name
  = text "Qualified name in binding position:" <+> ppr rdr_name

typeAppErr :: String -> LHsType GhcPs -> SDoc
typeAppErr what (L _ k)
  = hang (text "Illegal visible" <+> text what <+> text "application"
            <+> quotes (char '@' <> ppr k))
       2 (text "Perhaps you intended to use TypeApplications")

checkTupSize :: Int -> RnM ()
checkTupSize tup_size
  | tup_size <= mAX_TUPLE_SIZE
  = return ()
  | otherwise
  = addErr (sep [text "A" <+> int tup_size <> ptext (sLit "-tuple is too large for GHC"),
                 nest 2 (parens (text "max size is" <+> int mAX_TUPLE_SIZE)),
                 nest 2 (text "Workaround: use nested tuples or define a data type")])


{-
************************************************************************
*                                                                      *
\subsection{Contexts for renaming errors}
*                                                                      *
************************************************************************
-}

-- AZ:TODO: Change these all to be Name instead of RdrName.
--          Merge TcType.UserTypeContext in to it.
data HsDocContext
  = TypeSigCtx SDoc
  | StandaloneKindSigCtx SDoc
  | PatCtx
  | SpecInstSigCtx
  | DefaultDeclCtx
  | ForeignDeclCtx (LocatedA RdrName)
  | DerivDeclCtx
  | RuleCtx FastString
  | TyDataCtx (LocatedA RdrName)
  | TySynCtx (LocatedA RdrName)
  | TyFamilyCtx (LocatedA RdrName)
  | FamPatCtx (LocatedA RdrName)    -- The patterns of a type/data family instance
  | ConDeclCtx [LocatedA Name]
  | ClassDeclCtx (LocatedA RdrName)
  | ExprWithTySigCtx
  | TypBrCtx
  | HsTypeCtx
  | GHCiCtx
  | SpliceTypeCtx (LHsType GhcPs)
  | ClassInstanceCtx
  | GenericCtx SDoc   -- Maybe we want to use this more!

withHsDocContext :: HsDocContext -> SDoc -> SDoc
withHsDocContext ctxt doc = doc $$ inHsDocContext ctxt

inHsDocContext :: HsDocContext -> SDoc
inHsDocContext ctxt = text "In" <+> pprHsDocContext ctxt

pprHsDocContext :: HsDocContext -> SDoc
pprHsDocContext (GenericCtx doc)      = doc
pprHsDocContext (TypeSigCtx doc)      = text "the type signature for" <+> doc
pprHsDocContext (StandaloneKindSigCtx doc) = text "the standalone kind signature for" <+> doc
pprHsDocContext PatCtx                = text "a pattern type-signature"
pprHsDocContext SpecInstSigCtx        = text "a SPECIALISE instance pragma"
pprHsDocContext DefaultDeclCtx        = text "a `default' declaration"
pprHsDocContext DerivDeclCtx          = text "a deriving declaration"
pprHsDocContext (RuleCtx name)        = text "the transformation rule" <+> ftext name
pprHsDocContext (TyDataCtx tycon)     = text "the data type declaration for" <+> quotes (ppr tycon)
pprHsDocContext (FamPatCtx tycon)     = text "a type pattern of family instance for" <+> quotes (ppr tycon)
pprHsDocContext (TySynCtx name)       = text "the declaration for type synonym" <+> quotes (ppr name)
pprHsDocContext (TyFamilyCtx name)    = text "the declaration for type family" <+> quotes (ppr name)
pprHsDocContext (ClassDeclCtx name)   = text "the declaration for class" <+> quotes (ppr name)
pprHsDocContext ExprWithTySigCtx      = text "an expression type signature"
pprHsDocContext TypBrCtx              = text "a Template-Haskell quoted type"
pprHsDocContext HsTypeCtx             = text "a type argument"
pprHsDocContext GHCiCtx               = text "GHCi input"
pprHsDocContext (SpliceTypeCtx hs_ty) = text "the spliced type" <+> quotes (ppr hs_ty)
pprHsDocContext ClassInstanceCtx      = text "TcSplice.reifyInstances"

pprHsDocContext (ForeignDeclCtx name)
   = text "the foreign declaration for" <+> quotes (ppr name)
pprHsDocContext (ConDeclCtx [name])
   = text "the definition of data constructor" <+> quotes (ppr name)
pprHsDocContext (ConDeclCtx names)
   = text "the definition of data constructors" <+> interpp'SP names
