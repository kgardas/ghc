%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[RnSource]{Main pass of renamer}

\begin{code}
module RnSource ( 
	rnSrcDecls, addTcgDUs, rnTyClDecls, findSplice
    ) where

#include "HsVersions.h"

import {-# SOURCE #-} RnExpr( rnLExpr )
#ifdef GHCI
import {-# SOURCE #-} TcSplice ( runQuasiQuoteDecl )
#endif 	/* GHCI */

import HsSyn
import RdrName		( RdrName, isRdrDataCon, elemLocalRdrEnv, rdrNameOcc )
import RdrHsSyn		( extractHsRhoRdrTyVars )
import RnHsSyn
import RnTypes
import RnBinds		( rnTopBindsLHS, rnTopBindsRHS, rnMethodBinds, renameSigs, mkSigTvFn,
                                makeMiniFixityEnv)
import RnEnv		( lookupLocalDataTcNames, lookupLocatedOccRn,
			  lookupTopBndrRn, lookupLocatedTopBndrRn,
			  lookupOccRn, bindLocalNamesFV,
			  bindLocatedLocalsFV, bindPatSigTyVarsFV,
			  bindTyVarsRn, bindTyVarsFV, extendTyVarEnvFVRn,
			  bindLocalNames, checkDupRdrNames, mapFvRn
			)
import RnNames       	( getLocalNonValBinders, extendGlobalRdrEnvRn )
import HscTypes      	( GenAvailInfo(..), availsToNameSet )
import RnHsDoc          ( rnHsDoc, rnMbLHsDoc )
import TcRnMonad

import ForeignCall	( CCallTarget(..) )
import Module
import HscTypes		( Warnings(..), plusWarns )
import Class		( FunDep )
import Name		( Name, nameOccName )
import NameSet
import NameEnv
import Outputable
import Bag
import FastString
import Util		( filterOut )
import SrcLoc
import DynFlags
import HscTypes		( HscEnv, hsc_dflags )
import BasicTypes       ( Boxity(..) )
import ListSetOps       ( findDupsEq )
import Digraph		( SCC, flattenSCC, stronglyConnCompFromEdgedVertices )

import Control.Monad
import Maybes( orElse )
import Data.Maybe
\end{code}

\begin{code}
-- XXX
thenM :: Monad a => a b -> (b -> a c) -> a c
thenM = (>>=)

thenM_ :: Monad a => a b -> a c -> a c
thenM_ = (>>)
\end{code}

@rnSourceDecl@ `renames' declarations.
It simultaneously performs dependency analysis and precedence parsing.
It also does the following error checks:
\begin{enumerate}
\item
Checks that tyvars are used properly. This includes checking
for undefined tyvars, and tyvars in contexts that are ambiguous.
(Some of this checking has now been moved to module @TcMonoType@,
since we don't have functional dependency information at this point.)
\item
Checks that all variable occurences are defined.
\item 
Checks the @(..)@ etc constraints in the export list.
\end{enumerate}


\begin{code}
-- Brings the binders of the group into scope in the appropriate places;
-- does NOT assume that anything is in scope already
rnSrcDecls :: HsGroup RdrName -> RnM (TcGblEnv, HsGroup Name)
-- Rename a HsGroup; used for normal source files *and* hs-boot files
rnSrcDecls group@(HsGroup { hs_valds   = val_decls,
                            hs_tyclds  = tycl_decls,
                            hs_instds  = inst_decls,
                            hs_derivds = deriv_decls,
                            hs_fixds   = fix_decls,
                            hs_warnds  = warn_decls,
                            hs_annds   = ann_decls,
                            hs_fords   = foreign_decls,
                            hs_defds   = default_decls,
                            hs_ruleds  = rule_decls,
                            hs_vects   = vect_decls,
                            hs_docs    = docs })
 = do {
   -- (A) Process the fixity declarations, creating a mapping from
   --     FastStrings to FixItems.
   --     Also checks for duplcates.
   local_fix_env <- makeMiniFixityEnv fix_decls;

   -- (B) Bring top level binders (and their fixities) into scope,
   --     *except* for the value bindings, which get brought in below.
   --     However *do* include class ops, data constructors
   --     And for hs-boot files *do* include the value signatures
   tc_avails <- getLocalNonValBinders group ;
   tc_envs <- extendGlobalRdrEnvRn tc_avails local_fix_env ;
   setEnvs tc_envs $ do {

   failIfErrsM ; -- No point in continuing if (say) we have duplicate declarations

   -- (C) Extract the mapping from data constructors to field names and
   --     extend the record field env.
   --     This depends on the data constructors and field names being in
   --     scope from (B) above
   inNewEnv (extendRecordFieldEnv tycl_decls inst_decls) $ \ _ -> do {

   -- (D) Rename the left-hand sides of the value bindings.
   --     This depends on everything from (B) being in scope,
   --     and on (C) for resolving record wild cards.
   --     It uses the fixity env from (A) to bind fixities for view patterns.
   new_lhs <- rnTopBindsLHS local_fix_env val_decls ;
   -- bind the LHSes (and their fixities) in the global rdr environment
   let { val_binders = collectHsValBinders new_lhs ;
	 val_bndr_set = mkNameSet val_binders ;
	 all_bndr_set = val_bndr_set `unionNameSets` availsToNameSet tc_avails ;
         val_avails = map Avail val_binders 
       } ;
   (tcg_env, tcl_env) <- extendGlobalRdrEnvRn val_avails local_fix_env ;
   setEnvs (tcg_env, tcl_env) $ do {

   --  Now everything is in scope, as the remaining renaming assumes.

   -- (E) Rename type and class decls
   --     (note that value LHSes need to be in scope for default methods)
   --
   -- You might think that we could build proper def/use information
   -- for type and class declarations, but they can be involved
   -- in mutual recursion across modules, and we only do the SCC
   -- analysis for them in the type checker.
   -- So we content ourselves with gathering uses only; that
   -- means we'll only report a declaration as unused if it isn't
   -- mentioned at all.  Ah well.
   traceRn (text "Start rnTyClDecls") ;
   (rn_tycl_decls, src_fvs1) <- rnTyClDecls tycl_decls ;

   -- (F) Rename Value declarations right-hand sides
   traceRn (text "Start rnmono") ;
   (rn_val_decls, bind_dus) <- rnTopBindsRHS new_lhs ;
   traceRn (text "finish rnmono" <+> ppr rn_val_decls) ;

   -- (G) Rename Fixity and deprecations
   
   -- Rename fixity declarations and error if we try to
   -- fix something from another module (duplicates were checked in (A))
   rn_fix_decls <- rnSrcFixityDecls all_bndr_set fix_decls ;

   -- Rename deprec decls;
   -- check for duplicates and ensure that deprecated things are defined locally
   -- at the moment, we don't keep these around past renaming
   rn_warns <- rnSrcWarnDecls all_bndr_set warn_decls ;

   -- (H) Rename Everything else

   (rn_inst_decls,    src_fvs2) <- rnList rnSrcInstDecl   inst_decls ;
   (rn_rule_decls,    src_fvs3) <- setXOptM Opt_ScopedTypeVariables $
                                   rnList rnHsRuleDecl    rule_decls ;
                           -- Inside RULES, scoped type variables are on
   (rn_vect_decls,    src_fvs4) <- rnList rnHsVectDecl    vect_decls ;
   (rn_foreign_decls, src_fvs5) <- rnList rnHsForeignDecl foreign_decls ;
   (rn_ann_decls,     src_fvs6) <- rnList rnAnnDecl       ann_decls ;
   (rn_default_decls, src_fvs7) <- rnList rnDefaultDecl   default_decls ;
   (rn_deriv_decls,   src_fvs8) <- rnList rnSrcDerivDecl  deriv_decls ;
      -- Haddock docs; no free vars
   rn_docs <- mapM (wrapLocM rnDocDecl) docs ;

   -- (I) Compute the results and return
   let {rn_group = HsGroup { hs_valds  	= rn_val_decls,
			     hs_tyclds 	= rn_tycl_decls,
			     hs_instds 	= rn_inst_decls,
                             hs_derivds = rn_deriv_decls,
			     hs_fixds   = rn_fix_decls,
			     hs_warnds  = [], -- warns are returned in the tcg_env
	                                     -- (see below) not in the HsGroup
			     hs_fords  = rn_foreign_decls,
			     hs_annds  = rn_ann_decls,
			     hs_defds  = rn_default_decls,
			     hs_ruleds = rn_rule_decls,
			     hs_vects  = rn_vect_decls,
                             hs_docs   = rn_docs } ;

        tycl_bndrs = hsTyClDeclsBinders rn_tycl_decls rn_inst_decls ;
        ford_bndrs = hsForeignDeclsBinders rn_foreign_decls ;
	other_def  = (Just (mkNameSet tycl_bndrs `unionNameSets` mkNameSet ford_bndrs), emptyNameSet) ;
        other_fvs  = plusFVs [src_fvs1, src_fvs2, src_fvs3, src_fvs4, 
			      src_fvs5, src_fvs6, src_fvs7, src_fvs8] ;
		-- It is tiresome to gather the binders from type and class decls

	src_dus = [other_def] `plusDU` bind_dus `plusDU` usesOnly other_fvs ;
		-- Instance decls may have occurrences of things bound in bind_dus
		-- so we must put other_fvs last

        final_tcg_env = let tcg_env' = (tcg_env `addTcgDUs` src_dus)
                        in -- we return the deprecs in the env, not in the HsGroup above
                        tcg_env' { tcg_warns = tcg_warns tcg_env' `plusWarns` rn_warns };
       } ;

   traceRn (text "finish rnSrc" <+> ppr rn_group) ;
   traceRn (text "finish Dus" <+> ppr src_dus ) ;
   return (final_tcg_env, rn_group)
                    }}}}

-- some utils because we do this a bunch above
-- compute and install the new env
inNewEnv :: TcM TcGblEnv -> (TcGblEnv -> TcM a) -> TcM a
inNewEnv env cont = do e <- env
                       setGblEnv e $ cont e

addTcgDUs :: TcGblEnv -> DefUses -> TcGblEnv 
-- This function could be defined lower down in the module hierarchy, 
-- but there doesn't seem anywhere very logical to put it.
addTcgDUs tcg_env dus = tcg_env { tcg_dus = tcg_dus tcg_env `plusDU` dus }

rnList :: (a -> RnM (b, FreeVars)) -> [Located a] -> RnM ([Located b], FreeVars)
rnList f xs = mapFvRn (wrapLocFstM f) xs
\end{code}


%*********************************************************
%*						 	 *
	HsDoc stuff
%*							 *
%*********************************************************

\begin{code}
rnDocDecl :: DocDecl -> RnM DocDecl
rnDocDecl (DocCommentNext doc) = do 
  rn_doc <- rnHsDoc doc
  return (DocCommentNext rn_doc)
rnDocDecl (DocCommentPrev doc) = do 
  rn_doc <- rnHsDoc doc
  return (DocCommentPrev rn_doc)
rnDocDecl (DocCommentNamed str doc) = do
  rn_doc <- rnHsDoc doc
  return (DocCommentNamed str rn_doc)
rnDocDecl (DocGroup lev doc) = do
  rn_doc <- rnHsDoc doc
  return (DocGroup lev rn_doc)
\end{code}


%*********************************************************
%*						 	 *
	Source-code fixity declarations
%*							 *
%*********************************************************

\begin{code}
rnSrcFixityDecls :: NameSet -> [LFixitySig RdrName] -> RnM [LFixitySig Name]
-- Rename the fixity decls, so we can put
-- the renamed decls in the renamed syntax tree
-- Errors if the thing being fixed is not defined locally.
--
-- The returned FixitySigs are not actually used for anything,
-- except perhaps the GHCi API
rnSrcFixityDecls bound_names fix_decls
  = do fix_decls <- mapM rn_decl fix_decls
       return (concat fix_decls)
  where
    rn_decl :: LFixitySig RdrName -> RnM [LFixitySig Name]
        -- GHC extension: look up both the tycon and data con 
	-- for con-like things; hence returning a list
	-- If neither are in scope, report an error; otherwise
	-- return a fixity sig for each (slightly odd)
    rn_decl (L loc (FixitySig (L name_loc rdr_name) fixity))
      = setSrcSpan name_loc $
                    -- this lookup will fail if the definition isn't local
        do names <- lookupLocalDataTcNames bound_names what rdr_name
           return [ L loc (FixitySig (L name_loc name) fixity)
                  | name <- names ]
    what = ptext (sLit "fixity signature")
\end{code}


%*********************************************************
%*						 	 *
	Source-code deprecations declarations
%*							 *
%*********************************************************

Check that the deprecated names are defined, are defined locally, and
that there are no duplicate deprecations.

It's only imported deprecations, dealt with in RnIfaces, that we
gather them together.

\begin{code}
-- checks that the deprecations are defined locally, and that there are no duplicates
rnSrcWarnDecls :: NameSet -> [LWarnDecl RdrName] -> RnM Warnings
rnSrcWarnDecls _bound_names [] 
  = return NoWarnings

rnSrcWarnDecls bound_names decls 
  = do { -- check for duplicates
       ; mapM_ (\ dups -> let (L loc rdr:lrdr':_) = dups
                          in addErrAt loc (dupWarnDecl lrdr' rdr)) 
               warn_rdr_dups
       ; pairs_s <- mapM (addLocM rn_deprec) decls
       ; return (WarnSome ((concat pairs_s))) }
 where
   rn_deprec (Warning rdr_name txt)
       -- ensures that the names are defined locally
     = lookupLocalDataTcNames bound_names what rdr_name	`thenM` \ names ->
       return [(nameOccName name, txt) | name <- names]
   
   what = ptext (sLit "deprecation")

   -- look for duplicates among the OccNames;
   -- we check that the names are defined above
   -- invt: the lists returned by findDupsEq always have at least two elements
   warn_rdr_dups = findDupsEq (\ x -> \ y -> rdrNameOcc (unLoc x) == rdrNameOcc (unLoc y))
                     (map (\ (L loc (Warning rdr_name _)) -> L loc rdr_name) decls)
               
dupWarnDecl :: Located RdrName -> RdrName -> SDoc
-- Located RdrName -> DeprecDecl RdrName -> SDoc
dupWarnDecl (L loc _) rdr_name
  = vcat [ptext (sLit "Multiple warning declarations for") <+> quotes (ppr rdr_name),
          ptext (sLit "also at ") <+> ppr loc]

\end{code}

%*********************************************************
%*							*
\subsection{Annotation declarations}
%*							*
%*********************************************************

\begin{code}
rnAnnDecl :: AnnDecl RdrName -> RnM (AnnDecl Name, FreeVars)
rnAnnDecl (HsAnnotation provenance expr) = do
    (provenance', provenance_fvs) <- rnAnnProvenance provenance
    (expr', expr_fvs) <- rnLExpr expr
    return (HsAnnotation provenance' expr', provenance_fvs `plusFV` expr_fvs)

rnAnnProvenance :: AnnProvenance RdrName -> RnM (AnnProvenance Name, FreeVars)
rnAnnProvenance provenance = do
    provenance' <- modifyAnnProvenanceNameM lookupTopBndrRn provenance
    return (provenance', maybe emptyFVs unitFV (annProvenanceName_maybe provenance'))
\end{code}

%*********************************************************
%*							*
\subsection{Default declarations}
%*							*
%*********************************************************

\begin{code}
rnDefaultDecl :: DefaultDecl RdrName -> RnM (DefaultDecl Name, FreeVars)
rnDefaultDecl (DefaultDecl tys)
  = mapFvRn (rnHsTypeFVs doc_str) tys	`thenM` \ (tys', fvs) ->
    return (DefaultDecl tys', fvs)
  where
    doc_str = text "In a `default' declaration"
\end{code}

%*********************************************************
%*							*
\subsection{Foreign declarations}
%*							*
%*********************************************************

\begin{code}
rnHsForeignDecl :: ForeignDecl RdrName -> RnM (ForeignDecl Name, FreeVars)
rnHsForeignDecl (ForeignImport name ty spec)
  = getTopEnv                           `thenM` \ (topEnv :: HscEnv) ->
    lookupLocatedTopBndrRn name	        `thenM` \ name' ->
    rnHsTypeFVs (fo_decl_msg name) ty	`thenM` \ (ty', fvs) ->

    -- Mark any PackageTarget style imports as coming from the current package
    let packageId	= thisPackage $ hsc_dflags topEnv
	spec'		= patchForeignImport packageId spec

    in	return (ForeignImport name' ty' spec', fvs)

rnHsForeignDecl (ForeignExport name ty spec)
  = lookupLocatedOccRn name	        `thenM` \ name' ->
    rnHsTypeFVs (fo_decl_msg name) ty  	`thenM` \ (ty', fvs) ->
    return (ForeignExport name' ty' spec, fvs `addOneFV` unLoc name')
	-- NB: a foreign export is an *occurrence site* for name, so 
	--     we add it to the free-variable list.  It might, for example,
	--     be imported from another module

fo_decl_msg :: Located RdrName -> SDoc
fo_decl_msg name = ptext (sLit "In the foreign declaration for") <+> ppr name


-- | For Windows DLLs we need to know what packages imported symbols are from
--	to generate correct calls. Imported symbols are tagged with the current
--	package, so if they get inlined across a package boundry we'll still
--	know where they're from.
--
patchForeignImport :: PackageId -> ForeignImport -> ForeignImport
patchForeignImport packageId (CImport cconv safety fs spec)
	= CImport cconv safety fs (patchCImportSpec packageId spec) 

patchCImportSpec :: PackageId -> CImportSpec -> CImportSpec
patchCImportSpec packageId spec
 = case spec of
	CFunction callTarget	-> CFunction $ patchCCallTarget packageId callTarget
	_			-> spec

patchCCallTarget :: PackageId -> CCallTarget -> CCallTarget
patchCCallTarget packageId callTarget
 = case callTarget of
 	StaticTarget label Nothing
	 -> StaticTarget label (Just packageId)

	_			-> callTarget	


\end{code}


%*********************************************************
%*							*
\subsection{Instance declarations}
%*							*
%*********************************************************

\begin{code}
rnSrcInstDecl :: InstDecl RdrName -> RnM (InstDecl Name, FreeVars)
rnSrcInstDecl (InstDecl inst_ty mbinds uprags ats)
	-- Used for both source and interface file decls
  = rnHsSigType (text "an instance decl") inst_ty	`thenM` \ inst_ty' ->

	-- Rename the bindings
	-- The typechecker (not the renamer) checks that all 
	-- the bindings are for the right class
    let
	(inst_tyvars, _, cls,_) = splitHsInstDeclTy (unLoc inst_ty')
    in
    extendTyVarEnvForMethodBinds inst_tyvars (		
	-- (Slightly strangely) the forall-d tyvars scope over
	-- the method bindings too
	rnMethodBinds cls (\_ -> []) 	-- No scoped tyvars
		      mbinds
    )						`thenM` \ (mbinds', meth_fvs) ->
	-- Rename the associated types
	-- The typechecker (not the renamer) checks that all 
	-- the declarations are for the right class
    let
	at_names = map (head . hsTyClDeclBinders) ats
    in
    checkDupRdrNames at_names		`thenM_`
	-- See notes with checkDupRdrNames for methods, above

    rnATInsts ats				`thenM` \ (ats', at_fvs) ->

	-- Rename the prags and signatures.
	-- Note that the type variables are not in scope here,
	-- so that	instance Eq a => Eq (T a) where
	--			{-# SPECIALISE instance Eq a => Eq (T [a]) #-}
	-- works OK. 
	--
	-- But the (unqualified) method names are in scope
    let 
	binders = collectHsBindsBinders mbinds'
	bndr_set = mkNameSet binders
    in
    bindLocalNames binders 
	(renameSigs (Just bndr_set) okInstDclSig uprags)	`thenM` \ uprags' ->

    return (InstDecl inst_ty' mbinds' uprags' ats',
	     meth_fvs `plusFV` at_fvs
		      `plusFV` hsSigsFVs uprags'
		      `plusFV` extractHsTyNames inst_ty')
             -- We return the renamed associated data type declarations so
             -- that they can be entered into the list of type declarations
             -- for the binding group, but we also keep a copy in the instance.
             -- The latter is needed for well-formedness checks in the type
             -- checker (eg, to ensure that all ATs of the instance actually
             -- receive a declaration). 
	     -- NB: Even the copies in the instance declaration carry copies of
	     --     the instance context after renaming.  This is a bit
	     --     strange, but should not matter (and it would be more work
	     --     to remove the context).
\end{code}

Renaming of the associated types in instances.  

\begin{code}
rnATInsts :: [LTyClDecl RdrName] -> RnM ([LTyClDecl Name], FreeVars)
rnATInsts atDecls = rnList rnATInst atDecls
  where
    rnATInst tydecl@TyData     {} = rnTyClDecl tydecl
    rnATInst tydecl@TySynonym  {} = rnTyClDecl tydecl
    rnATInst tydecl               =
      pprPanic "RnSource.rnATInsts: invalid AT instance" 
	       (ppr (tcdName tydecl))
\end{code}

For the method bindings in class and instance decls, we extend the 
type variable environment iff -fglasgow-exts

\begin{code}
extendTyVarEnvForMethodBinds :: [LHsTyVarBndr Name]
                             -> RnM (Bag (LHsBind Name), FreeVars)
                             -> RnM (Bag (LHsBind Name), FreeVars)
extendTyVarEnvForMethodBinds tyvars thing_inside
  = do	{ scoped_tvs <- xoptM Opt_ScopedTypeVariables
	; if scoped_tvs then
		extendTyVarEnvFVRn (map hsLTyVarName tyvars) thing_inside
	  else
		thing_inside }
\end{code}

%*********************************************************
%*							*
\subsection{Stand-alone deriving declarations}
%*							*
%*********************************************************

\begin{code}
rnSrcDerivDecl :: DerivDecl RdrName -> RnM (DerivDecl Name, FreeVars)
rnSrcDerivDecl (DerivDecl ty)
  = do { standalone_deriv_ok <- xoptM Opt_StandaloneDeriving
       ; unless standalone_deriv_ok (addErr standaloneDerivErr)
       ; ty' <- rnLHsType (text "In a deriving declaration") ty
       ; let fvs = extractHsTyNames ty'
       ; return (DerivDecl ty', fvs) }

standaloneDerivErr :: SDoc
standaloneDerivErr 
  = hang (ptext (sLit "Illegal standalone deriving declaration"))
       2 (ptext (sLit "Use -XStandaloneDeriving to enable this extension"))
\end{code}

%*********************************************************
%*							*
\subsection{Rules}
%*							*
%*********************************************************

\begin{code}
rnHsRuleDecl :: RuleDecl RdrName -> RnM (RuleDecl Name, FreeVars)
rnHsRuleDecl (HsRule rule_name act vars lhs _fv_lhs rhs _fv_rhs)
  = bindPatSigTyVarsFV (collectRuleBndrSigTys vars)	$
    bindLocatedLocalsFV (map get_var vars)		$ \ ids ->
    do	{ (vars', fv_vars) <- mapFvRn rn_var (vars `zip` ids)
		-- NB: The binders in a rule are always Ids
		--     We don't (yet) support type variables

	; (lhs', fv_lhs') <- rnLExpr lhs
	; (rhs', fv_rhs') <- rnLExpr rhs

	; checkValidRule rule_name ids lhs' fv_lhs'

	; return (HsRule rule_name act vars' lhs' fv_lhs' rhs' fv_rhs',
		  fv_vars `plusFV` fv_lhs' `plusFV` fv_rhs') }
  where
    doc = text "In the transformation rule" <+> ftext rule_name
  
    get_var (RuleBndr v)      = v
    get_var (RuleBndrSig v _) = v

    rn_var (RuleBndr (L loc _), id)
	= return (RuleBndr (L loc id), emptyFVs)
    rn_var (RuleBndrSig (L loc _) t, id)
	= rnHsTypeFVs doc t	`thenM` \ (t', fvs) ->
	  return (RuleBndrSig (L loc id) t', fvs)

badRuleVar :: FastString -> Name -> SDoc
badRuleVar name var
  = sep [ptext (sLit "Rule") <+> doubleQuotes (ftext name) <> colon,
	 ptext (sLit "Forall'd variable") <+> quotes (ppr var) <+> 
		ptext (sLit "does not appear on left hand side")]
\end{code}

Note [Rule LHS validity checking]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Check the shape of a transformation rule LHS.  Currently we only allow
LHSs of the form @(f e1 .. en)@, where @f@ is not one of the
@forall@'d variables.  

We used restrict the form of the 'ei' to prevent you writing rules
with LHSs with a complicated desugaring (and hence unlikely to match);
(e.g. a case expression is not allowed: too elaborate.)

But there are legitimate non-trivial args ei, like sections and
lambdas.  So it seems simmpler not to check at all, and that is why
check_e is commented out.
	
\begin{code}
checkValidRule :: FastString -> [Name] -> LHsExpr Name -> NameSet -> RnM ()
checkValidRule rule_name ids lhs' fv_lhs'
  = do 	{ 	-- Check for the form of the LHS
	  case (validRuleLhs ids lhs') of
		Nothing  -> return ()
		Just bad -> failWithTc (badRuleLhsErr rule_name lhs' bad)

		-- Check that LHS vars are all bound
	; let bad_vars = [var | var <- ids, not (var `elemNameSet` fv_lhs')]
	; mapM_ (addErr . badRuleVar rule_name) bad_vars }

validRuleLhs :: [Name] -> LHsExpr Name -> Maybe (HsExpr Name)
-- Nothing => OK
-- Just e  => Not ok, and e is the offending expression
validRuleLhs foralls lhs
  = checkl lhs
  where
    checkl (L _ e) = check e

    check (OpApp e1 op _ e2)		  = checkl op `mplus` checkl_e e1 `mplus` checkl_e e2
    check (HsApp e1 e2) 		  = checkl e1 `mplus` checkl_e e2
    check (HsVar v) | v `notElem` foralls = Nothing
    check other				  = Just other 	-- Failure

	-- Check an argument
    checkl_e (L _ _e) = Nothing 	-- Was (check_e e); see Note [Rule LHS validity checking]

{-	Commented out; see Note [Rule LHS validity checking] above 
    check_e (HsVar v)     = Nothing
    check_e (HsPar e) 	  = checkl_e e
    check_e (HsLit e) 	  = Nothing
    check_e (HsOverLit e) = Nothing

    check_e (OpApp e1 op _ e2) 	 = checkl_e e1 `mplus` checkl_e op `mplus` checkl_e e2
    check_e (HsApp e1 e2)      	 = checkl_e e1 `mplus` checkl_e e2
    check_e (NegApp e _)       	 = checkl_e e
    check_e (ExplicitList _ es)	 = checkl_es es
    check_e other		 = Just other	-- Fails

    checkl_es es = foldr (mplus . checkl_e) Nothing es
-}

badRuleLhsErr :: FastString -> LHsExpr Name -> HsExpr Name -> SDoc
badRuleLhsErr name lhs bad_e
  = sep [ptext (sLit "Rule") <+> ftext name <> colon,
	 nest 4 (vcat [ptext (sLit "Illegal expression:") <+> ppr bad_e, 
		       ptext (sLit "in left-hand side:") <+> ppr lhs])]
    $$
    ptext (sLit "LHS must be of form (f e1 .. en) where f is not forall'd")
\end{code}


%*********************************************************
%*                                                      *
\subsection{Vectorisation declarations}
%*                                                      *
%*********************************************************

\begin{code}
rnHsVectDecl :: VectDecl RdrName -> RnM (VectDecl Name, FreeVars)
rnHsVectDecl (HsVect var Nothing)
  = do { var' <- wrapLocM lookupTopBndrRn var
       ; return (HsVect var' Nothing, unitFV (unLoc var'))
       }
rnHsVectDecl (HsVect var (Just rhs))
  = do { var' <- wrapLocM lookupTopBndrRn var
       ; (rhs', fv_rhs) <- rnLExpr rhs
       ; return (HsVect var' (Just rhs'), fv_rhs `addOneFV` unLoc var')
       }
rnHsVectDecl (HsNoVect var)
  = do { var' <- wrapLocM lookupTopBndrRn var
       ; return (HsNoVect var', unitFV (unLoc var'))
       }
\end{code}

%*********************************************************
%*							*
\subsection{Type, class and iface sig declarations}
%*							*
%*********************************************************

@rnTyDecl@ uses the `global name function' to create a new type
declaration in which local names have been replaced by their original
names, reporting any unknown names.

Renaming type variables is a pain. Because they now contain uniques,
it is necessary to pass in an association list which maps a parsed
tyvar to its @Name@ representation.
In some cases (type signatures of values),
it is even necessary to go over the type first
in order to get the set of tyvars used by it, make an assoc list,
and then go over it again to rename the tyvars!
However, we can also do some scoping checks at the same time.

\begin{code}
rnTyClDecls :: [[LTyClDecl RdrName]] -> RnM ([[LTyClDecl Name]], FreeVars)
-- Renamed the declarations and do depedency analysis on them
rnTyClDecls tycl_ds
  = do { ds_w_fvs <- mapM (wrapLocFstM rnTyClDecl) (concat tycl_ds)

       ; let sccs :: [SCC (LTyClDecl Name)]
             sccs = depAnalTyClDecls ds_w_fvs

             all_fvs = foldr (plusFV . snd) emptyFVs ds_w_fvs

       ; return (map flattenSCC sccs, all_fvs) }

rnTyClDecl :: TyClDecl RdrName -> RnM (TyClDecl Name, FreeVars)
rnTyClDecl (ForeignType {tcdLName = name, tcdExtName = ext_name})
  = lookupLocatedTopBndrRn name		`thenM` \ name' ->
    return (ForeignType {tcdLName = name', tcdExtName = ext_name},
	     emptyFVs)

-- all flavours of type family declarations ("type family", "newtype fanily",
-- and "data family")
rnTyClDecl tydecl@TyFamily {} = rnFamily tydecl bindTyVarsFV

-- "data", "newtype", "data instance, and "newtype instance" declarations
rnTyClDecl tydecl@TyData {tcdND = new_or_data, tcdCtxt = context, 
			   tcdLName = tycon, tcdTyVars = tyvars, 
			   tcdTyPats = typats, tcdCons = condecls, 
			   tcdKindSig = sig, tcdDerivs = derivs}
  = do	{ tycon' <- if isFamInstDecl tydecl
		    then lookupLocatedOccRn     tycon -- may be imported family
		    else lookupLocatedTopBndrRn tycon
	; checkTc (h98_style || null (unLoc context)) 
                  (badGadtStupidTheta tycon)
    	; ((tyvars', context', typats', derivs'), stuff_fvs)
		<- bindTyVarsFV tyvars $ \ tyvars' -> do
		         	 -- Checks for distinct tyvars
		   { context' <- rnContext data_doc context
                   ; (typats', fvs1) <- rnTyPats data_doc tycon' typats
                   ; (derivs', fvs2) <- rn_derivs derivs
                   ; let fvs = fvs1 `plusFV` fvs2 `plusFV` 
                               extractHsCtxtTyNames context'
		   ; return ((tyvars', context', typats', derivs'), fvs) }

	-- For the constructor declarations, bring into scope the tyvars 
	-- bound by the header, but *only* in the H98 case
	-- Reason: for GADTs, the type variables in the declaration 
	--   do not scope over the constructor signatures
	--   data T a where { T1 :: forall b. b-> b }
        ; let tc_tvs_in_scope | h98_style = hsLTyVarNames tyvars'
                              | otherwise = []
	; (condecls', con_fvs) <- bindLocalNamesFV tc_tvs_in_scope $
                                  rnConDecls condecls
		-- No need to check for duplicate constructor decls
		-- since that is done by RnNames.extendGlobalRdrEnvRn

	; return (TyData {tcdND = new_or_data, tcdCtxt = context', 
			   tcdLName = tycon', tcdTyVars = tyvars', 
			   tcdTyPats = typats', tcdKindSig = sig,
			   tcdCons = condecls', tcdDerivs = derivs'}, 
	     	   con_fvs `plusFV` stuff_fvs)
        }
  where
    h98_style = case condecls of	 -- Note [Stupid theta]
		     L _ (ConDecl { con_res = ResTyGADT {} }) : _  -> False
		     _    		                           -> True
               		     						  
    data_doc = text "In the data type declaration for" <+> quotes (ppr tycon)

    rn_derivs Nothing   = return (Nothing, emptyFVs)
    rn_derivs (Just ds) = rnLHsTypes data_doc ds	`thenM` \ ds' -> 
			  return (Just ds', extractHsTyNames_s ds')

-- "type" and "type instance" declarations
rnTyClDecl tydecl@(TySynonym {tcdLName = name, tcdTyVars = tyvars,
			      tcdTyPats = typats, tcdSynRhs = ty})
  = bindTyVarsFV tyvars $ \ tyvars' -> do
    {    	 -- Checks for distinct tyvars
      name' <- if isFamInstDecl tydecl
    		  then lookupLocatedOccRn     name -- may be imported family
    		  else lookupLocatedTopBndrRn name
    ; (typats',fvs1) <- rnTyPats syn_doc name' typats
    ; (ty', fvs2)    <- rnHsTypeFVs syn_doc ty
    ; return (TySynonym { tcdLName = name', tcdTyVars = tyvars' 
    			, tcdTyPats = typats', tcdSynRhs = ty'},
    	      fvs1 `plusFV` fvs2) }
  where
    syn_doc = text "In the declaration for type synonym" <+> quotes (ppr name)

rnTyClDecl (ClassDecl {tcdCtxt = context, tcdLName = cname, 
		       tcdTyVars = tyvars, tcdFDs = fds, tcdSigs = sigs, 
		       tcdMeths = mbinds, tcdATs = ats, tcdDocs = docs})
  = do	{ cname' <- lookupLocatedTopBndrRn cname

	-- Tyvars scope over superclass context and method signatures
	; ((tyvars', context', fds', ats', sigs'), stuff_fvs)
	    <- bindTyVarsFV tyvars $ \ tyvars' -> do
         	 -- Checks for distinct tyvars
	     { context' <- rnContext cls_doc context
	     ; fds' <- rnFds cls_doc fds
	     ; (ats', at_fvs) <- rnATs ats
	     ; sigs' <- renameSigs Nothing okClsDclSig sigs
	     ; let fvs = at_fvs `plusFV` 
                         extractHsCtxtTyNames context'	`plusFV`
	                 hsSigsFVs sigs'
			 -- The fundeps have no free variables
	     ; return ((tyvars', context', fds', ats', sigs'), fvs) }

	-- No need to check for duplicate associated type decls
	-- since that is done by RnNames.extendGlobalRdrEnvRn

	-- Check the signatures
	-- First process the class op sigs (op_sigs), then the fixity sigs (non_op_sigs).
	; let sig_rdr_names_w_locs = [op | L _ (TypeSig ops _) <- sigs, op <- ops]
	; checkDupRdrNames sig_rdr_names_w_locs
		-- Typechecker is responsible for checking that we only
		-- give default-method bindings for things in this class.
		-- The renamer *could* check this for class decls, but can't
		-- for instance decls.

   	-- The newLocals call is tiresome: given a generic class decl
	--	class C a where
	--	  op :: a -> a
	--	  op {| x+y |} (Inl a) = ...
	--	  op {| x+y |} (Inr b) = ...
	--	  op {| a*b |} (a*b)   = ...
	-- we want to name both "x" tyvars with the same unique, so that they are
	-- easy to group together in the typechecker.  
	; (mbinds', meth_fvs) 
	    <- extendTyVarEnvForMethodBinds tyvars' $
		-- No need to check for duplicate method signatures
		-- since that is done by RnNames.extendGlobalRdrEnvRn
		-- and the methods are already in scope
	         rnMethodBinds (unLoc cname') (mkSigTvFn sigs') mbinds

  -- Haddock docs 
	; docs' <- mapM (wrapLocM rnDocDecl) docs

	; return (ClassDecl { tcdCtxt = context', tcdLName = cname', 
			      tcdTyVars = tyvars', tcdFDs = fds', tcdSigs = sigs',
			      tcdMeths = mbinds', tcdATs = ats', tcdDocs = docs'},
	     	  meth_fvs `plusFV` stuff_fvs) }
  where
    cls_doc  = text "In the declaration for class" 	<+> ppr cname

badGadtStupidTheta :: Located RdrName -> SDoc
badGadtStupidTheta _
  = vcat [ptext (sLit "No context is allowed on a GADT-style data declaration"),
	  ptext (sLit "(You can put a context on each contructor, though.)")]
\end{code}

Note [Stupid theta]
~~~~~~~~~~~~~~~~~~~
Trac #3850 complains about a regression wrt 6.10 for 
     data Show a => T a
There is no reason not to allow the stupid theta if there are no data
constructors.  It's still stupid, but does no harm, and I don't want
to cause programs to break unnecessarily (notably HList).  So if there
are no data constructors we allow h98_style = True


\begin{code}
depAnalTyClDecls :: [(LTyClDecl Name, FreeVars)] -> [SCC (LTyClDecl Name)]
-- See Note [Dependency analysis of type and class decls]
depAnalTyClDecls ds_w_fvs
  = stronglyConnCompFromEdgedVertices edges
  where
    edges = [ (d, tcdName (unLoc d), map get_assoc (nameSetToList fvs))
            | (d, fvs) <- ds_w_fvs ]
    get_assoc n = lookupNameEnv assoc_env n `orElse` n
    assoc_env = mkNameEnv [ (tcdName assoc_decl, cls_name) 
                          | (L _ (ClassDecl { tcdLName = L _ cls_name
                                            , tcdATs   = ats }) ,_) <- ds_w_fvs
                          , L _ assoc_decl <- ats ]
\end{code}

Note [Dependency analysis of type and class decls]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We need to do dependency analysis on type and class declarations
else we get bad error messages.  Consider

     data T f a = MkT f a
     data S f a = MkS f (T f a)

This has a kind error, but the error message is better if you
check T first, (fixing its kind) and *then* S.  If you do kind
inference together, you might get an error reported in S, which
is jolly confusing.  See Trac #4875


%*********************************************************
%*							*
\subsection{Support code for type/data declarations}
%*							*
%*********************************************************

\begin{code}
rnTyPats :: SDoc -> Located Name -> Maybe [LHsType RdrName] -> RnM (Maybe [LHsType Name], FreeVars)
-- Although, we are processing type patterns here, all type variables will
-- already be in scope (they are the same as in the 'tcdTyVars' field of the
-- type declaration to which these patterns belong)
rnTyPats _   _  Nothing
  = return (Nothing, emptyFVs)
rnTyPats doc tc (Just typats) 
  = do { typats' <- rnLHsTypes doc typats
       ; let fvs = addOneFV (extractHsTyNames_s typats') (unLoc tc)
       	     -- type instance => use, hence addOneFV
       ; return (Just typats', fvs) }

rnConDecls :: [LConDecl RdrName] -> RnM ([LConDecl Name], FreeVars)
rnConDecls condecls
  = do { condecls' <- mapM (wrapLocM rnConDecl) condecls
       ; return (condecls', plusFVs (map conDeclFVs condecls')) }

rnConDecl :: ConDecl RdrName -> RnM (ConDecl Name)
rnConDecl decl@(ConDecl { con_name = name, con_qvars = tvs
                   	       , con_cxt = cxt, con_details = details
                   	       , con_res = res_ty, con_doc = mb_doc
                   	       , con_old_rec = old_rec, con_explicit = expl })
  = do	{ addLocM checkConName name
    	; when old_rec (addWarn (deprecRecSyntax decl))
	; new_name <- lookupLocatedTopBndrRn name

    	   -- For H98 syntax, the tvs are the existential ones
	   -- For GADT syntax, the tvs are all the quantified tyvars
	   -- Hence the 'filter' in the ResTyH98 case only
        ; rdr_env <- getLocalRdrEnv
        ; let in_scope     = (`elemLocalRdrEnv` rdr_env) . unLoc
	      arg_tys      = hsConDeclArgTys details
	      mentioned_tvs = case res_ty of
	      	    	       ResTyH98 -> filterOut in_scope (get_rdr_tvs arg_tys)
	      	    	       ResTyGADT ty -> get_rdr_tvs (ty : arg_tys)

         -- With an Explicit forall, check for unused binders
	 -- With Implicit, find the mentioned ones, and use them as binders
	; new_tvs <- case expl of
	    	       Implicit -> return (userHsTyVarBndrs mentioned_tvs)
            	       Explicit -> do { warnUnusedForAlls doc tvs mentioned_tvs
                                      ; return tvs }

        ; mb_doc' <- rnMbLHsDoc mb_doc 

        ; bindTyVarsRn new_tvs $ \new_tyvars -> do
	{ new_context <- rnContext doc cxt
	; new_details <- rnConDeclDetails doc details
        ; (new_details', new_res_ty)  <- rnConResult doc new_details res_ty
        ; return (decl { con_name = new_name, con_qvars = new_tyvars, con_cxt = new_context 
                       , con_details = new_details', con_res = new_res_ty, con_doc = mb_doc' }) }}
 where
    doc = text "In the definition of data constructor" <+> quotes (ppr name)
    get_rdr_tvs tys  = extractHsRhoRdrTyVars cxt (noLoc (HsTupleTy Boxed tys))

rnConResult :: SDoc
            -> HsConDetails (LHsType Name) [ConDeclField Name]
            -> ResType RdrName
            -> RnM (HsConDetails (LHsType Name) [ConDeclField Name],
                    ResType Name)
rnConResult _ details ResTyH98 = return (details, ResTyH98)
rnConResult doc details (ResTyGADT ty)
  = do { ty' <- rnLHsType doc ty
       ; let (arg_tys, res_ty) = splitHsFunType ty'
          	-- We can finally split it up, 
		-- now the renamer has dealt with fixities
	        -- See Note [Sorting out the result type] in RdrHsSyn

             details' = case details of
       	     	           RecCon {}    -> details
			   PrefixCon {} -> PrefixCon arg_tys
			   InfixCon {}  -> pprPanic "rnConResult" (ppr ty)
			  -- See Note [Sorting out the result type] in RdrHsSyn
		
       ; when (not (null arg_tys) && case details of { RecCon {} -> True; _ -> False })
              (addErr (badRecResTy doc))
       ; return (details', ResTyGADT res_ty) }

rnConDeclDetails :: SDoc
                 -> HsConDetails (LHsType RdrName) [ConDeclField RdrName]
                 -> RnM (HsConDetails (LHsType Name) [ConDeclField Name])
rnConDeclDetails doc (PrefixCon tys)
  = mapM (rnLHsType doc) tys	`thenM` \ new_tys  ->
    return (PrefixCon new_tys)

rnConDeclDetails doc (InfixCon ty1 ty2)
  = rnLHsType doc ty1  		`thenM` \ new_ty1 ->
    rnLHsType doc ty2  		`thenM` \ new_ty2 ->
    return (InfixCon new_ty1 new_ty2)

rnConDeclDetails doc (RecCon fields)
  = do	{ new_fields <- rnConDeclFields doc fields
		-- No need to check for duplicate fields
		-- since that is done by RnNames.extendGlobalRdrEnvRn
	; return (RecCon new_fields) }

-- Rename family declarations
--
-- * This function is parametrised by the routine handling the index
--   variables.  On the toplevel, these are defining occurences, whereas they
--   are usage occurences for associated types.
--
rnFamily :: TyClDecl RdrName 
         -> ([LHsTyVarBndr RdrName] -> 
	     ([LHsTyVarBndr Name] -> RnM (TyClDecl Name, FreeVars)) ->
	     RnM (TyClDecl Name, FreeVars))
         -> RnM (TyClDecl Name, FreeVars)

rnFamily (tydecl@TyFamily {tcdFlavour = flavour, 
			   tcdLName = tycon, tcdTyVars = tyvars}) 
        bindIdxVars =
      do { bindIdxVars tyvars $ \tyvars' -> do {
	 ; tycon' <- lookupLocatedTopBndrRn tycon
	 ; return (TyFamily {tcdFlavour = flavour, tcdLName = tycon', 
			      tcdTyVars = tyvars', tcdKind = tcdKind tydecl}, 
		    emptyFVs) 
         } }
rnFamily d _ = pprPanic "rnFamily" (ppr d)

-- Rename associated type declarations (in classes)
--
-- * This can be family declarations and (default) type instances
--
rnATs :: [LTyClDecl RdrName] -> RnM ([LTyClDecl Name], FreeVars)
rnATs ats = mapFvRn (wrapLocFstM rn_at) ats
  where
    rn_at (tydecl@TyFamily  {}) = rnFamily tydecl lookupIdxVars
    rn_at (tydecl@TySynonym {}) = 
      do
        unless (isNothing (tcdTyPats tydecl)) $ addErr noPatterns
        rnTyClDecl tydecl
    rn_at _                      = panic "RnSource.rnATs: invalid TyClDecl"

    lookupIdxVars tyvars cont = 
      do { checkForDups tyvars
	 ; tyvars' <- mapM lookupIdxVar tyvars
	 ; cont tyvars'
	 }
    -- Type index variables must be class parameters, which are the only
    -- type variables in scope at this point.
    lookupIdxVar (L l tyvar) =
      do
	name' <- lookupOccRn (hsTyVarName tyvar)
	return $ L l (replaceTyVarName tyvar name')

    -- Type variable may only occur once.
    --
    checkForDups [] = return ()
    checkForDups (L loc tv:ltvs) = 
      do { setSrcSpan loc $
	     when (hsTyVarName tv `ltvElem` ltvs) $
	       addErr (repeatedTyVar tv)
	 ; checkForDups ltvs
	 }

    _       `ltvElem` [] = False
    rdrName `ltvElem` (L _ tv:ltvs)
      | rdrName == hsTyVarName tv = True
      | otherwise		  = rdrName `ltvElem` ltvs

deprecRecSyntax :: ConDecl RdrName -> SDoc
deprecRecSyntax decl 
  = vcat [ ptext (sLit "Declaration of") <+> quotes (ppr (con_name decl))
    	 	 <+> ptext (sLit "uses deprecated syntax")
         , ptext (sLit "Instead, use the form")
         , nest 2 (ppr decl) ]	 -- Pretty printer uses new form

badRecResTy :: SDoc -> SDoc
badRecResTy doc = ptext (sLit "Malformed constructor signature") $$ doc

noPatterns :: SDoc
noPatterns = text "Default definition for an associated synonym cannot have"
	     <+> text "type pattern"

repeatedTyVar :: HsTyVarBndr RdrName -> SDoc
repeatedTyVar tv = ptext (sLit "Illegal repeated type variable") <+>
		   quotes (ppr tv)

-- This data decl will parse OK
--	data T = a Int
-- treating "a" as the constructor.
-- It is really hard to make the parser spot this malformation.
-- So the renamer has to check that the constructor is legal
--
-- We can get an operator as the constructor, even in the prefix form:
--	data T = :% Int Int
-- from interface files, which always print in prefix form

checkConName :: RdrName -> TcRn ()
checkConName name = checkErr (isRdrDataCon name) (badDataCon name)

badDataCon :: RdrName -> SDoc
badDataCon name
   = hsep [ptext (sLit "Illegal data constructor name"), quotes (ppr name)]
\end{code}


%*********************************************************
%*							*
\subsection{Support code for type/data declarations}
%*							*
%*********************************************************

Get the mapping from constructors to fields for this module.
It's convenient to do this after the data type decls have been renamed
\begin{code}
extendRecordFieldEnv :: [[LTyClDecl RdrName]] -> [LInstDecl RdrName] -> TcM TcGblEnv
extendRecordFieldEnv tycl_decls inst_decls
  = do	{ tcg_env <- getGblEnv
	; field_env' <- foldrM get_con (tcg_field_env tcg_env) all_data_cons
	; return (tcg_env { tcg_field_env = field_env' }) }
  where
    -- we want to lookup:
    --  (a) a datatype constructor
    --  (b) a record field
    -- knowing that they're from this module.
    -- lookupLocatedTopBndrRn does this, because it does a lookupGreLocalRn,
    -- which keeps only the local ones.
    lookup x = do { x' <- lookupLocatedTopBndrRn x
                    ; return $ unLoc x'}

    all_data_cons :: [ConDecl RdrName]
    all_data_cons = [con | L _ (TyData { tcdCons = cons }) <- all_tycl_decls
    		         , L _ con <- cons ]
    all_tycl_decls = at_tycl_decls ++ concat tycl_decls
    at_tycl_decls = instDeclATs inst_decls  -- Do not forget associated types!

    get_con (ConDecl { con_name = con, con_details = RecCon flds })
	    (RecFields env fld_set)
	= do { con' <- lookup con
             ; flds' <- mapM lookup (map cd_fld_name flds)
	     ; let env'    = extendNameEnv env con' flds'
	           fld_set' = addListToNameSet fld_set flds'
             ; return $ (RecFields env' fld_set') }
    get_con _ env = return env
\end{code}

%*********************************************************
%*							*
\subsection{Support code to rename types}
%*							*
%*********************************************************

\begin{code}
rnFds :: SDoc -> [Located (FunDep RdrName)] -> RnM [Located (FunDep Name)]

rnFds doc fds
  = mapM (wrapLocM rn_fds) fds
  where
    rn_fds (tys1, tys2)
      =	rnHsTyVars doc tys1		`thenM` \ tys1' ->
	rnHsTyVars doc tys2		`thenM` \ tys2' ->
	return (tys1', tys2')

rnHsTyVars :: SDoc -> [RdrName] -> RnM [Name]
rnHsTyVars doc tvs  = mapM (rnHsTyVar doc) tvs

rnHsTyVar :: SDoc -> RdrName -> RnM Name
rnHsTyVar _doc tyvar = lookupOccRn tyvar
\end{code}


%*********************************************************
%*							*
	findSplice
%*							*
%*********************************************************

This code marches down the declarations, looking for the first
Template Haskell splice.  As it does so it
	a) groups the declarations into a HsGroup
	b) runs any top-level quasi-quotes

\begin{code}
findSplice :: [LHsDecl RdrName] -> RnM (HsGroup RdrName, Maybe (SpliceDecl RdrName, [LHsDecl RdrName]))
findSplice ds = addl emptyRdrGroup ds

addl :: HsGroup RdrName -> [LHsDecl RdrName]
     -> RnM (HsGroup RdrName, Maybe (SpliceDecl RdrName, [LHsDecl RdrName]))
-- This stuff reverses the declarations (again) but it doesn't matter
addl gp []	     = return (gp, Nothing)
addl gp (L l d : ds) = add gp l d ds


add :: HsGroup RdrName -> SrcSpan -> HsDecl RdrName -> [LHsDecl RdrName]
    -> RnM (HsGroup RdrName, Maybe (SpliceDecl RdrName, [LHsDecl RdrName]))

add gp loc (SpliceD splice@(SpliceDecl _ flag)) ds 
  = do { -- We've found a top-level splice.  If it is an *implicit* one 
         -- (i.e. a naked top level expression)
         case flag of
           Explicit -> return ()
           Implicit -> do { th_on <- xoptM Opt_TemplateHaskell
                          ; unless th_on $ setSrcSpan loc $
                            failWith badImplicitSplice }

       ; return (gp, Just (splice, ds)) }
  where
    badImplicitSplice = ptext (sLit "Parse error: naked expression at top level")

#ifndef GHCI
add _ _ (QuasiQuoteD qq) _
  = pprPanic "Can't do QuasiQuote declarations without GHCi" (ppr qq)
#else
add gp _ (QuasiQuoteD qq) ds		-- Expand quasiquotes
  = do { ds' <- runQuasiQuoteDecl qq
       ; addl gp (ds' ++ ds) }
#endif

-- Class declarations: pull out the fixity signatures to the top
add gp@(HsGroup {hs_tyclds = ts, hs_fixds = fs}) l (TyClD d) ds
  | isClassDecl d
  = let fsigs = [ L l f | L l (FixSig f) <- tcdSigs d ] in
    addl (gp { hs_tyclds = add_tycld (L l d) ts, hs_fixds = fsigs ++ fs}) ds
  | otherwise
  = addl (gp { hs_tyclds = add_tycld (L l d) ts }) ds

-- Signatures: fixity sigs go a different place than all others
add gp@(HsGroup {hs_fixds = ts}) l (SigD (FixSig f)) ds
  = addl (gp {hs_fixds = L l f : ts}) ds
add gp@(HsGroup {hs_valds = ts}) l (SigD d) ds
  = addl (gp {hs_valds = add_sig (L l d) ts}) ds

-- Value declarations: use add_bind
add gp@(HsGroup {hs_valds  = ts}) l (ValD d) ds
  = addl (gp { hs_valds = add_bind (L l d) ts }) ds

-- The rest are routine
add gp@(HsGroup {hs_instds = ts})  l (InstD d) ds
  = addl (gp { hs_instds = L l d : ts }) ds
add gp@(HsGroup {hs_derivds = ts})  l (DerivD d) ds
  = addl (gp { hs_derivds = L l d : ts }) ds
add gp@(HsGroup {hs_defds  = ts})  l (DefD d) ds
  = addl (gp { hs_defds = L l d : ts }) ds
add gp@(HsGroup {hs_fords  = ts}) l (ForD d) ds
  = addl (gp { hs_fords = L l d : ts }) ds
add gp@(HsGroup {hs_warnds  = ts})  l (WarningD d) ds
  = addl (gp { hs_warnds = L l d : ts }) ds
add gp@(HsGroup {hs_annds  = ts}) l (AnnD d) ds
  = addl (gp { hs_annds = L l d : ts }) ds
add gp@(HsGroup {hs_ruleds  = ts}) l (RuleD d) ds
  = addl (gp { hs_ruleds = L l d : ts }) ds
add gp@(HsGroup {hs_vects  = ts}) l (VectD d) ds
  = addl (gp { hs_vects = L l d : ts }) ds
add gp l (DocD d) ds
  = addl (gp { hs_docs = (L l d) : (hs_docs gp) })  ds

add_tycld :: LTyClDecl a -> [[LTyClDecl a]] -> [[LTyClDecl a]]
add_tycld d []       = [[d]]
add_tycld d (ds:dss) = (d:ds) : dss

add_bind :: LHsBind a -> HsValBinds a -> HsValBinds a
add_bind b (ValBindsIn bs sigs) = ValBindsIn (bs `snocBag` b) sigs
add_bind _ (ValBindsOut {})     = panic "RdrHsSyn:add_bind"

add_sig :: LSig a -> HsValBinds a -> HsValBinds a
add_sig s (ValBindsIn bs sigs) = ValBindsIn bs (s:sigs) 
add_sig _ (ValBindsOut {})     = panic "RdrHsSyn:add_sig"
\end{code}
