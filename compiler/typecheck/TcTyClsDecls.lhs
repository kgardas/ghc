%
% (c) The University of Glasgow 2006
% (c) The AQUA Project, Glasgow University, 1996-1998
%

TcTyClsDecls: Typecheck type and class declarations

\begin{code}
module TcTyClsDecls (
	tcTyAndClassDecls, kcDataDecl, tcConDecls, mkRecSelBinds,
        checkValidTyCon, dataDeclChecks, badFamInstDecl
    ) where

#include "HsVersions.h"

import HsSyn
import HscTypes
import BuildTyCl
import TcUnify
import TcRnMonad
import TcEnv
import TcTyDecls
import TcClassDcl
import TcHsType
import TcMType
import TcType
import TysWiredIn	( unitTy )
import Type
import Class
import TyCon
import DataCon
import Id
import MkCore		( rEC_SEL_ERROR_ID )
import IdInfo
import Var
import VarSet
import Name
import NameEnv
import Outputable
import Maybes
import Unify
import Util
import SrcLoc
import ListSetOps
import Digraph
import DynFlags
import FastString
import Unique		( mkBuiltinUnique )
import BasicTypes

import Bag
import Control.Monad
import Data.List
\end{code}


%************************************************************************
%*									*
\subsection{Type checking for type and class declarations}
%*									*
%************************************************************************

\begin{code}

tcTyAndClassDecls :: ModDetails 
                   -> [[LTyClDecl Name]]     -- Mutually-recursive groups in dependency order
   	           -> TcM (TcGblEnv,   	     -- Input env extended by types and classes 
					     -- and their implicit Ids,DataCons
		           HsValBinds Name)  -- Renamed bindings for record selectors
-- Fails if there are any errors

tcTyAndClassDecls boot_details decls_s
  = checkNoErrs $ 	-- The code recovers internally, but if anything gave rise to
			-- an error we'd better stop now, to avoid a cascade
    do { let tyclds_s = map (filterOut (isFamInstDecl . unLoc)) decls_s
     		  -- Remove family instance decls altogether
		  -- They are dealt with by TcInstDcls
	      
       ; tyclss <- fixM $ \ rec_tyclss ->
              tcExtendRecEnv (zipRecTyClss tyclds_s rec_tyclss) $
	      	-- We must populate the environment with the loop-tied
	      	-- T's right away (even before kind checking), because 
                -- the kind checker may "fault in" some type constructors 
	      	-- that recursively mention T

              do {    -- Kind-check in dependency order
                      -- See Note [Kind checking for type and class decls]
                   kc_decls <- kcTyClDecls tyclds_s

                      -- And now build the TyCons/Classes
                ; let rec_flags = calcRecFlags boot_details rec_tyclss
                ; concatMapM (tcTyClDecl rec_flags) kc_decls }

       ; traceTc "tcTyAndCl3" (ppr tyclss)

       ; tcExtendGlobalEnv tyclss $ do
       {  -- Perform the validity check
          -- We can do this now because we are done with the recursive knot
          traceTc "ready for validity check" empty
	; mapM_ (addLocM checkValidTyCl) (concat tyclds_s)
 	; traceTc "done" empty

	-- Add the implicit things;
	-- we want them in the environment because
	-- they may be mentioned in interface files
	-- NB: All associated types and their implicit things will be added a
	--     second time here.  This doesn't matter as the definitions are
	--     the same.
	; let {	implicit_things = concatMap implicitTyThings tyclss
	      ; rec_sel_binds   = mkRecSelBinds [tc | ATyCon tc <- tyclss]
              ; dm_ids          = mkDefaultMethodIds tyclss }

  	; env <- tcExtendGlobalEnv implicit_things $
                 tcExtendGlobalValEnv dm_ids $
                 getGblEnv
        ; return (env, rec_sel_binds) } }
                    
zipRecTyClss :: [[LTyClDecl Name]]
             -> [TyThing]           -- Knot-tied
             -> [(Name,TyThing)]
-- Build a name-TyThing mapping for the things bound by decls
-- being careful not to look at the [TyThing]
-- The TyThings in the result list must have a visible ATyCon/AClass,
-- because typechecking types (in, say, tcTyClDecl) looks at this outer constructor
zipRecTyClss decls_s rec_things
  = [ get decl | decls <- decls_s, L _ decl <- flattenATs decls ]
  where
    rec_type_env :: TypeEnv
    rec_type_env = mkTypeEnv rec_things

    get :: TyClDecl Name -> (Name, TyThing)
    get (ClassDecl {tcdLName = L _ name}) = (name, AClass cl)
      where
        Just (AClass cl) = lookupTypeEnv rec_type_env name
    get decl = (name, ATyCon tc)
      where
        name = tcdName decl
        Just (ATyCon tc) = lookupTypeEnv rec_type_env name
\end{code}


%************************************************************************
%*									*
		Kind checking
%*									*
%************************************************************************

Note [Kind checking for type and class decls]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Kind checking is done thus:

   1. Make up a kind variable for each parameter of the *data* type, 
      and class, decls, and extend the kind environment (which is in
      the TcLclEnv)

   2. Dependency-analyse the type *synonyms* (which must be non-recursive),
      and kind-check them in dependency order.  Extend the kind envt.

   3. Kind check the data type and class decls

Synonyms are treated differently to data type and classes,
because a type synonym can be an unboxed type
	type Foo = Int#
and a kind variable can't unify with UnboxedTypeKind
So we infer their kinds in dependency order

We need to kind check all types in the mutually recursive group
before we know the kind of the type variables.  For example:

class C a where
   op :: D b => a -> b -> b

class D c where
   bop :: (Monad c) => ...

Here, the kind of the locally-polymorphic type variable "b"
depends on *all the uses of class D*.  For example, the use of
Monad c in bop's type signature means that D must have kind Type->Type.

However type synonyms work differently.  They can have kinds which don't
just involve (->) and *:
	type R = Int#		-- Kind #
	type S a = Array# a	-- Kind * -> #
	type T a b = (# a,b #)	-- Kind * -> * -> (# a,b #)
So we must infer their kinds from their right-hand sides *first* and then
use them, whereas for the mutually recursive data types D we bring into
scope kind bindings D -> k, where k is a kind variable, and do inference.

Type families
~~~~~~~~~~~~~
This treatment of type synonyms only applies to Haskell 98-style synonyms.
General type functions can be recursive, and hence, appear in `alg_decls'.

The kind of a type family is solely determinded by its kind signature;
hence, only kind signatures participate in the construction of the initial
kind environment (as constructed by `getInitialKind').  In fact, we ignore
instances of families altogether in the following.  However, we need to
include the kinds of associated families into the construction of the
initial kind environment.  (This is handled by `allDecls').


\begin{code}
kcTyClDecls :: [[LTyClDecl Name]] -> TcM [LTyClDecl Name]
kcTyClDecls []                = return []
kcTyClDecls (decls : decls_s) = do { (tcl_env, kc_decls1) <- kcTyClDecls1 decls
                                   ; kc_decls2 <- setLclEnv tcl_env (kcTyClDecls decls_s)
                                   ; return (kc_decls1 ++ kc_decls2) }

kcTyClDecls1 :: [LTyClDecl Name] -> TcM (TcLclEnv, [LTyClDecl Name])
kcTyClDecls1 decls
  = do	{       -- Omit instances of type families; they are handled together
		-- with the *heads* of class instances
        ; let (syn_decls, alg_decls) = partition (isSynDecl . unLoc) decls
              alg_at_decls           = flattenATs alg_decls

	; mod <- getModule
	; traceTc "tcTyAndCl" (ptext (sLit "module") <+> ppr mod $$ vcat (map ppr decls))

        	-- First check for cyclic classes
	; checkClassCycleErrs alg_decls

	   -- Kind checking; see Note [Kind checking for type and class decls]
	; alg_kinds <- mapM getInitialKind alg_at_decls
	; tcExtendKindEnv alg_kinds $  do

        { (kc_syn_decls, tcl_env) <- kcSynDecls (calcSynCycles syn_decls)
        ; setLclEnv tcl_env $  do
        { kc_alg_decls <- mapM (wrapLocM kcTyClDecl) alg_decls
                
	     -- Kind checking done for this group, so zonk the kind variables
	     -- See Note [Kind checking for type and class decls]
        ; mapM_ (zonkTcKindToKind . snd) alg_kinds

	; return (tcl_env, kc_syn_decls ++ kc_alg_decls) } } }

flattenATs :: [LTyClDecl Name] -> [LTyClDecl Name]
flattenATs decls = concatMap flatten decls
  where
    flatten decl@(L _ (ClassDecl {tcdATs = ats})) = decl : ats
    flatten decl				  = [decl]

getInitialKind :: LTyClDecl Name -> TcM (Name, TcKind)
-- Only for data type, class, and indexed type declarations
-- Get as much info as possible from the data, class, or indexed type decl,
-- so as to maximise usefulness of error messages
getInitialKind (L _ decl)
  = do 	{ arg_kinds <- mapM (mk_arg_kind . unLoc) (tyClDeclTyVars decl)
	; res_kind  <- mk_res_kind decl
	; return (tcdName decl, mkArrowKinds arg_kinds res_kind) }
  where
    mk_arg_kind (UserTyVar _ _)      = newKindVar
    mk_arg_kind (KindedTyVar _ kind) = return kind

    mk_res_kind (TyFamily { tcdKind    = Just kind }) = return kind
    mk_res_kind (TyData   { tcdKindSig = Just kind }) = return kind
	-- On GADT-style declarations we allow a kind signature
	--	data T :: *->* where { ... }
    mk_res_kind _ = return liftedTypeKind


----------------
kcSynDecls :: [SCC (LTyClDecl Name)] 
	   -> TcM ([LTyClDecl Name], 	-- Kind-annotated decls
		   TcLclEnv)	-- Kind bindings
kcSynDecls []
  = do { tcl_env <- getLclEnv; return ([], tcl_env) }
kcSynDecls (group : groups)
  = do	{ (decl,  nk)      <- kcSynDecl group
	; (decls, tcl_env) <- tcExtendKindEnv [nk] (kcSynDecls groups)
	; return (decl:decls, tcl_env) }
			
----------------
kcSynDecl :: SCC (LTyClDecl Name) 
	   -> TcM (LTyClDecl Name, 	-- Kind-annotated decls
		   (Name,TcKind))	-- Kind bindings
kcSynDecl (AcyclicSCC (L loc decl))
  = tcAddDeclCtxt decl	$
    kcHsTyVars (tcdTyVars decl) (\ k_tvs ->
    do { traceTc "kcd1" (ppr (unLoc (tcdLName decl)) <+> brackets (ppr (tcdTyVars decl)) 
			<+> brackets (ppr k_tvs))
       ; (k_rhs, rhs_kind) <- kcLHsType (tcdSynRhs decl)
       ; traceTc "kcd2" (ppr (unLoc (tcdLName decl)))
       ; let tc_kind = foldr (mkArrowKind . hsTyVarKind . unLoc) rhs_kind k_tvs
       ; return (L loc (decl { tcdTyVars = k_tvs, tcdSynRhs = k_rhs }),
		 (unLoc (tcdLName decl), tc_kind)) })

kcSynDecl (CyclicSCC decls)
  = do { recSynErr decls; failM }	-- Fail here to avoid error cascade
					-- of out-of-scope tycons

------------------------------------------------------------------------
kcTyClDecl :: TyClDecl Name -> TcM (TyClDecl Name)
	-- Not used for type synonyms (see kcSynDecl)

kcTyClDecl decl@(TyData {})
  = ASSERT( not . isFamInstDecl $ decl )   -- must not be a family instance
    kcTyClDeclBody decl	$
      kcDataDecl decl

kcTyClDecl decl@(TyFamily {})
  = kcFamilyDecl [] decl      -- the empty list signals a toplevel decl      

kcTyClDecl decl@(ClassDecl {tcdCtxt = ctxt, tcdSigs = sigs, tcdATs = ats})
  = kcTyClDeclBody decl	$ \ tvs' ->
    do	{ ctxt' <- kcHsContext ctxt	
	; ats'  <- mapM (wrapLocM (kcFamilyDecl tvs')) ats
	; sigs' <- mapM (wrapLocM kc_sig) sigs
	; return (decl {tcdTyVars = tvs', tcdCtxt = ctxt', tcdSigs = sigs',
		        tcdATs = ats'}) }
  where
    kc_sig (TypeSig nm op_ty) = do { op_ty' <- kcHsLiftedSigType op_ty
				   ; return (TypeSig nm op_ty') }
    kc_sig (GenericSig nm op_ty) = do { op_ty' <- kcHsLiftedSigType op_ty
				      ; return (GenericSig nm op_ty') }
    kc_sig other_sig	      = return other_sig

kcTyClDecl decl@(ForeignType {})
  = return decl

kcTyClDecl (TySynonym {}) = panic "kcTyClDecl TySynonym"

kcTyClDeclBody :: TyClDecl Name
	       -> ([LHsTyVarBndr Name] -> TcM a)
	       -> TcM a
-- getInitialKind has made a suitably-shaped kind for the type or class
-- Unpack it, and attribute those kinds to the type variables
-- Extend the env with bindings for the tyvars, taken from
-- the kind of the tycon/class.  Give it to the thing inside, and 
-- check the result kind matches
kcTyClDeclBody decl thing_inside
  = tcAddDeclCtxt decl		$
    do 	{ tc_ty_thing <- tcLookupLocated (tcdLName decl)
	; let tc_kind	 = case tc_ty_thing of
                             AThing k -> k
                             _ -> pprPanic "kcTyClDeclBody" (ppr tc_ty_thing)
	      (kinds, _) = splitKindFunTys tc_kind
	      hs_tvs 	 = tcdTyVars decl
	      kinded_tvs = ASSERT( length kinds >= length hs_tvs )
			   zipWith add_kind hs_tvs kinds
	; tcExtendKindEnvTvs kinded_tvs thing_inside }
  where
    add_kind (L loc (UserTyVar n _))   k = L loc (UserTyVar n k)
    add_kind (L loc (KindedTyVar n _)) k = L loc (KindedTyVar n k)

-- Kind check a data declaration, assuming that we already extended the
-- kind environment with the type variables of the left-hand side (these
-- kinded type variables are also passed as the second parameter).
--
kcDataDecl :: TyClDecl Name -> [LHsTyVarBndr Name] -> TcM (TyClDecl Name)
kcDataDecl decl@(TyData {tcdND = new_or_data, tcdCtxt = ctxt, tcdCons = cons})
	   tvs
  = do	{ ctxt' <- kcHsContext ctxt	
	; cons' <- mapM (wrapLocM kc_con_decl) cons
	; return (decl {tcdTyVars = tvs, tcdCtxt = ctxt', tcdCons = cons'}) }
  where
    -- doc comments are typechecked to Nothing here
    kc_con_decl con_decl@(ConDecl { con_name = name, con_qvars = ex_tvs
                                  , con_cxt = ex_ctxt, con_details = details, con_res = res })
      = addErrCtxt (dataConCtxt name)	$ 
        kcHsTyVars ex_tvs $ \ex_tvs' -> do
        do { ex_ctxt' <- kcHsContext ex_ctxt
           ; details' <- kc_con_details details 
           ; res'     <- case res of
                ResTyH98 -> return ResTyH98
                ResTyGADT ty -> do { ty' <- kcHsSigType ty; return (ResTyGADT ty') }
           ; return (con_decl { con_qvars = ex_tvs', con_cxt = ex_ctxt'
                              , con_details = details', con_res = res' }) }

    kc_con_details (PrefixCon btys) 
	= do { btys' <- mapM kc_larg_ty btys 
             ; return (PrefixCon btys') }
    kc_con_details (InfixCon bty1 bty2) 
	= do { bty1' <- kc_larg_ty bty1
             ; bty2' <- kc_larg_ty bty2
             ; return (InfixCon bty1' bty2') }
    kc_con_details (RecCon fields) 
	= do { fields' <- mapM kc_field fields
             ; return (RecCon fields') }

    kc_field (ConDeclField fld bty d) = do { bty' <- kc_larg_ty bty
					   ; return (ConDeclField fld bty' d) }

    kc_larg_ty bty = case new_or_data of
			DataType -> kcHsSigType bty
			NewType  -> kcHsLiftedSigType bty
	-- Can't allow an unlifted type for newtypes, because we're effectively
	-- going to remove the constructor while coercing it to a lifted type.
	-- And newtypes can't be bang'd
kcDataDecl d _ = pprPanic "kcDataDecl" (ppr d)

-- Kind check a family declaration or type family default declaration.
--
kcFamilyDecl :: [LHsTyVarBndr Name]  -- tyvars of enclosing class decl if any
             -> TyClDecl Name -> TcM (TyClDecl Name)
kcFamilyDecl classTvs decl@(TyFamily {tcdKind = kind})
  = kcTyClDeclBody decl $ \tvs' ->
    do { mapM_ unifyClassParmKinds tvs'
       ; return (decl {tcdTyVars = tvs', 
		       tcdKind = kind `mplus` Just liftedTypeKind})
		       -- default result kind is '*'
       }
  where
    unifyClassParmKinds (L _ tv) 
      | (n,k) <- hsTyVarNameKind tv
      , Just classParmKind <- lookup n classTyKinds 
      = unifyKind k classParmKind
      | otherwise = return ()
    classTyKinds = [hsTyVarNameKind tv | L _ tv <- classTvs]

kcFamilyDecl _ (TySynonym {})              -- type family defaults
  = panic "TcTyClsDecls.kcFamilyDecl: not implemented yet"
kcFamilyDecl _ d = pprPanic "kcFamilyDecl" (ppr d)
\end{code}


%************************************************************************
%*									*
\subsection{Type checking}
%*									*
%************************************************************************

\begin{code}
tcTyClDecl :: (Name -> RecFlag) -> LTyClDecl Name -> TcM [TyThing]

tcTyClDecl calc_isrec (L loc decl)
  = setSrcSpan loc $ tcAddDeclCtxt decl $
    traceTc "tcTyAndCl-x" (ppr decl) >>
    tcTyClDecl1 NoParentTyCon calc_isrec decl

  -- "type family" declarations
tcTyClDecl1 :: TyConParent -> (Name -> RecFlag) -> TyClDecl Name -> TcM [TyThing]
tcTyClDecl1 parent _calc_isrec 
  (TyFamily {tcdFlavour = TypeFamily, 
	     tcdLName = L _ tc_name, tcdTyVars = tvs,
             tcdKind = Just kind}) -- NB: kind at latest added during kind checking
  = tcTyVarBndrs tvs  $ \ tvs' -> do 
  { traceTc "type family:" (ppr tc_name) 

	-- Check that we don't use families without -XTypeFamilies
  ; idx_tys <- xoptM Opt_TypeFamilies
  ; checkTc idx_tys $ badFamInstDecl tc_name

  ; tycon <- buildSynTyCon tc_name tvs' SynFamilyTyCon kind parent Nothing
  ; return [ATyCon tycon]
  }

  -- "data family" declaration
tcTyClDecl1 parent _calc_isrec 
  (TyFamily {tcdFlavour = DataFamily, 
	     tcdLName = L _ tc_name, tcdTyVars = tvs, tcdKind = mb_kind})
  = tcTyVarBndrs tvs  $ \ tvs' -> do 
  { traceTc "data family:" (ppr tc_name) 
  ; extra_tvs <- tcDataKindSig mb_kind
  ; let final_tvs = tvs' ++ extra_tvs    -- we may not need these


	-- Check that we don't use families without -XTypeFamilies
  ; idx_tys <- xoptM Opt_TypeFamilies
  ; checkTc idx_tys $ badFamInstDecl tc_name

  ; tycon <- buildAlgTyCon tc_name final_tvs [] 
               DataFamilyTyCon Recursive True 
               parent Nothing
  ; return [ATyCon tycon]
  }

  -- "type"
tcTyClDecl1 _parent _calc_isrec
  (TySynonym {tcdLName = L _ tc_name, tcdTyVars = tvs, tcdSynRhs = rhs_ty})
  = ASSERT( isNoParent _parent )
    tcTyVarBndrs tvs		$ \ tvs' -> do 
    { traceTc "tcd1" (ppr tc_name) 
    ; rhs_ty' <- tcHsKindedType rhs_ty
    ; tycon <- buildSynTyCon tc_name tvs' (SynonymTyCon rhs_ty') 
      	       		     (typeKind rhs_ty') NoParentTyCon  Nothing
    ; return [ATyCon tycon] }

  -- "newtype" and "data"
  -- NB: not used for newtype/data instances (whether associated or not)
tcTyClDecl1 _parent calc_isrec
  (TyData {tcdND = new_or_data, tcdCtxt = ctxt, tcdTyVars = tvs,
	   tcdLName = L _ tc_name, tcdKindSig = mb_ksig, tcdCons = cons})
  = ASSERT( isNoParent _parent )
    tcTyVarBndrs tvs	$ \ tvs' -> do 
  { extra_tvs <- tcDataKindSig mb_ksig
  ; let final_tvs = tvs' ++ extra_tvs
  ; stupid_theta <- tcHsKindedContext ctxt
  ; kind_signatures <- xoptM Opt_KindSignatures
  ; existential_ok <- xoptM Opt_ExistentialQuantification
  ; gadt_ok      <- xoptM Opt_GADTs
  ; is_boot	 <- tcIsHsBoot	-- Are we compiling an hs-boot file?
  ; let ex_ok = existential_ok || gadt_ok	-- Data cons can have existential context

	-- Check that we don't use kind signatures without Glasgow extensions
  ; checkTc (kind_signatures || isNothing mb_ksig) (badSigTyDecl tc_name)

  ; dataDeclChecks tc_name new_or_data stupid_theta cons

  ; tycon <- fixM (\ tycon -> do 
	{ let res_ty = mkTyConApp tycon (mkTyVarTys final_tvs)
	; data_cons <- tcConDecls ex_ok tycon (final_tvs, res_ty) cons
	; tc_rhs <-
	    if null cons && is_boot 	-- In a hs-boot file, empty cons means
	    then return AbstractTyCon	-- "don't know"; hence Abstract
	    else case new_or_data of
		   DataType -> return (mkDataTyConRhs data_cons)
		   NewType  -> ASSERT( not (null data_cons) )
                               mkNewTyConRhs tc_name tycon (head data_cons)
	; buildAlgTyCon tc_name final_tvs stupid_theta tc_rhs is_rec
	    (not h98_syntax) NoParentTyCon Nothing
	})
  ; return [ATyCon tycon]
  }
  where
    is_rec   = calc_isrec tc_name
    h98_syntax = consUseH98Syntax cons

tcTyClDecl1 _parent calc_isrec 
  (ClassDecl {tcdLName = L _ class_name, tcdTyVars = tvs, 
	      tcdCtxt = ctxt, tcdMeths = meths,
	      tcdFDs = fundeps, tcdSigs = sigs, tcdATs = ats} )
  = ASSERT( isNoParent _parent )
    tcTyVarBndrs tvs		$ \ tvs' -> do 
  { ctxt' <- tcHsKindedContext ctxt
  ; fds' <- mapM (addLocM tc_fundep) fundeps
  ; (sig_stuff, gen_dm_env) <- tcClassSigs class_name sigs meths
  ; clas <- fixM $ \ clas -> do
	    { let 	-- This little knot is just so we can get
			-- hold of the name of the class TyCon, which we
			-- need to look up its recursiveness
		    tycon_name = tyConName (classTyCon clas)
		    tc_isrec = calc_isrec tycon_name
	    ; atss' <- mapM (addLocM $ tcTyClDecl1 (AssocFamilyTyCon clas) (const Recursive)) ats
            -- NB: 'ats' only contains "type family" and "data family"
            --     declarations as well as type family defaults
            ; buildClass False {- Must include unfoldings for selectors -}
			 class_name tvs' ctxt' fds' (concat atss')
			 sig_stuff tc_isrec }

  ; let gen_dm_ids = [ AnId (mkExportedLocalId gen_dm_name gen_dm_ty)
                     | (sel_id, GenDefMeth gen_dm_name) <- classOpItems clas
                     , let gen_dm_tau = expectJust "tcTyClDecl1" $
                                        lookupNameEnv gen_dm_env (idName sel_id)
		     , let gen_dm_ty = mkSigmaTy tvs' 
                                                 [mkClassPred clas (mkTyVarTys tvs')] 
                                                 gen_dm_tau
                     ]
        class_ats = map ATyCon (classATs clas)

  ; return (AClass clas : gen_dm_ids ++ class_ats )
      -- NB: Order is important due to the call to `mkGlobalThings' when
      --     tying the the type and class declaration type checking knot.
  }
  where
    tc_fundep (tvs1, tvs2) = do { tvs1' <- mapM tcLookupTyVar tvs1 ;
				; tvs2' <- mapM tcLookupTyVar tvs2 ;
				; return (tvs1', tvs2') }

tcTyClDecl1 _ _
  (ForeignType {tcdLName = L _ tc_name, tcdExtName = tc_ext_name})
  = return [ATyCon (mkForeignTyCon tc_name tc_ext_name liftedTypeKind 0)]

tcTyClDecl1 _ _ d = pprPanic "tcTyClDecl1" (ppr d)

dataDeclChecks :: Name -> NewOrData -> ThetaType -> [LConDecl Name] -> TcM ()
dataDeclChecks tc_name new_or_data stupid_theta cons
  = do {   -- Check that we don't use GADT syntax in H98 world
         gadtSyntax_ok <- xoptM Opt_GADTSyntax
       ; let h98_syntax = consUseH98Syntax cons
       ; checkTc (gadtSyntax_ok || h98_syntax) (badGadtDecl tc_name)

	   -- Check that the stupid theta is empty for a GADT-style declaration
       ; checkTc (null stupid_theta || h98_syntax) (badStupidTheta tc_name)

	-- Check that a newtype has exactly one constructor
	-- Do this before checking for empty data decls, so that
	-- we don't suggest -XEmptyDataDecls for newtypes
      ; checkTc (new_or_data == DataType || isSingleton cons) 
	        (newtypeConError tc_name (length cons))

 	-- Check that there's at least one condecl,
	-- or else we're reading an hs-boot file, or -XEmptyDataDecls
      ; empty_data_decls <- xoptM Opt_EmptyDataDecls
      ; is_boot <- tcIsHsBoot	-- Are we compiling an hs-boot file?
      ; checkTc (not (null cons) || empty_data_decls || is_boot)
                (emptyConDeclsErr tc_name) }
    
-----------------------------------
tcConDecls :: Bool -> TyCon -> ([TyVar], Type)
	   -> [LConDecl Name] -> TcM [DataCon]
tcConDecls ex_ok rep_tycon res_tmpl cons
  = mapM (addLocM (tcConDecl ex_ok rep_tycon res_tmpl)) cons

tcConDecl :: Bool		-- True <=> -XExistentialQuantificaton or -XGADTs
	  -> TyCon 		-- Representation tycon
	  -> ([TyVar], Type)	-- Return type template (with its template tyvars)
	  -> ConDecl Name 
	  -> TcM DataCon

tcConDecl existential_ok rep_tycon res_tmpl 	-- Data types
	  con@(ConDecl {con_name = name, con_qvars = tvs, con_cxt = ctxt
                   , con_details = details, con_res = res_ty })
  = addErrCtxt (dataConCtxt name)	$ 
    tcTyVarBndrs tvs			$ \ tvs' -> do 
    { ctxt' <- tcHsKindedContext ctxt
    ; checkTc (existential_ok || conRepresentibleWithH98Syntax con)
	      (badExistential name)
    ; (univ_tvs, ex_tvs, eq_preds, res_ty') <- tcResultType res_tmpl tvs' res_ty
    ; let 
	tc_datacon is_infix field_lbls btys
	  = do { (arg_tys, stricts) <- mapAndUnzipM tcConArg btys
    	       ; buildDataCon (unLoc name) is_infix
    		    stricts field_lbls
    		    univ_tvs ex_tvs eq_preds ctxt' arg_tys
		    res_ty' rep_tycon }
		-- NB:	we put data_tc, the type constructor gotten from the
		--	constructor type signature into the data constructor;
		--	that way checkValidDataCon can complain if it's wrong.

    ; case details of
	PrefixCon btys     -> tc_datacon False [] btys
	InfixCon bty1 bty2 -> tc_datacon True  [] [bty1,bty2]
	RecCon fields      -> tc_datacon False field_names btys
			   where
			      field_names = map (unLoc . cd_fld_name) fields
			      btys        = map cd_fld_type fields
    }

-- Example
--   data instance T (b,c) where 
--	TI :: forall e. e -> T (e,e)
--
-- The representation tycon looks like this:
--   data :R7T b c where 
--	TI :: forall b1 c1. (b1 ~ c1) => b1 -> :R7T b1 c1
-- In this case orig_res_ty = T (e,e)

tcResultType :: ([TyVar], Type)	-- Template for result type; e.g.
				-- data instance T [a] b c = ...  
				--      gives template ([a,b,c], T [a] b c)
	     -> [TyVar] 	-- where MkT :: forall x y z. ...
	     -> ResType Name
	     -> TcM ([TyVar],	 	-- Universal
		     [TyVar],		-- Existential (distinct OccNames from univs)
		     [(TyVar,Type)],	-- Equality predicates
		     Type)		-- Typechecked return type
	-- We don't check that the TyCon given in the ResTy is
	-- the same as the parent tycon, becuase we are in the middle
	-- of a recursive knot; so it's postponed until checkValidDataCon

tcResultType (tmpl_tvs, res_ty) dc_tvs ResTyH98
  = return (tmpl_tvs, dc_tvs, [], res_ty)
	-- In H98 syntax the dc_tvs are the existential ones
	--	data T a b c = forall d e. MkT ...
	-- The {a,b,c} are tc_tvs, and {d,e} are dc_tvs

tcResultType (tmpl_tvs, res_tmpl) dc_tvs (ResTyGADT res_ty)
	-- E.g.  data T [a] b c where
	--	   MkT :: forall x y z. T [(x,y)] z z
	-- Then we generate
	--	Univ tyvars	Eq-spec
	--	    a              a~(x,y)
	--	    b		   b~z
	--	    z		   
	-- Existentials are the leftover type vars: [x,y]
	-- So we return ([a,b,z], [x,y], [a~(x,y),b~z], T [(x,y)] z z)
  = do	{ res_ty' <- tcHsKindedType res_ty
	; let Just subst = tcMatchTy (mkVarSet tmpl_tvs) res_tmpl res_ty'

		-- /Lazily/ figure out the univ_tvs etc
		-- Each univ_tv is either a dc_tv or a tmpl_tv
	      (univ_tvs, eq_spec) = foldr choose ([], []) tidy_tmpl_tvs
	      choose tmpl (univs, eqs)
		| Just ty <- lookupTyVar subst tmpl 
		= case tcGetTyVar_maybe ty of
		    Just tv | not (tv `elem` univs)
			    -> (tv:univs,   eqs)
		    _other  -> (tmpl:univs, (tmpl,ty):eqs)
		| otherwise = pprPanic "tcResultType" (ppr res_ty)
	      ex_tvs = dc_tvs `minusList` univ_tvs

	; return (univ_tvs, ex_tvs, eq_spec, res_ty') }
  where
	-- NB: tmpl_tvs and dc_tvs are distinct, but
	-- we want them to be *visibly* distinct, both for
	-- interface files and general confusion.  So rename
	-- the tc_tvs, since they are not used yet (no 
	-- consequential renaming needed)
    (_, tidy_tmpl_tvs) = mapAccumL tidy_one init_occ_env tmpl_tvs
    init_occ_env       = initTidyOccEnv (map getOccName dc_tvs)
    tidy_one env tv    = (env', setTyVarName tv (tidyNameOcc name occ'))
	      where
		 name = tyVarName tv
		 (env', occ') = tidyOccName env (getOccName name) 

consUseH98Syntax :: [LConDecl a] -> Bool
consUseH98Syntax (L _ (ConDecl { con_res = ResTyGADT _ }) : _) = False
consUseH98Syntax _                                             = True
		 -- All constructors have same shape

conRepresentibleWithH98Syntax :: ConDecl Name -> Bool
conRepresentibleWithH98Syntax
    (ConDecl {con_qvars = tvs, con_cxt = ctxt, con_res = ResTyH98 })
        = null tvs && null (unLoc ctxt)
conRepresentibleWithH98Syntax
    (ConDecl {con_qvars = tvs, con_cxt = ctxt, con_res = ResTyGADT (L _ t) })
        = null (unLoc ctxt) && f t (map (hsTyVarName . unLoc) tvs)
    where -- Each type variable should be used exactly once in the
          -- result type, and the result type must just be the type
          -- constructor applied to type variables
          f (HsAppTy (L _ t1) (L _ (HsTyVar v2))) vs
              = (v2 `elem` vs) && f t1 (delete v2 vs)
          f (HsTyVar _) [] = True
          f _ _ = False

-------------------
tcConArg :: LHsType Name -> TcM (TcType, HsBang)
tcConArg bty
  = do  { arg_ty <- tcHsBangType bty
        ; strict_mark <- chooseBoxingStrategy arg_ty (getBangStrictness bty)
	; return (arg_ty, strict_mark) }

-- We attempt to unbox/unpack a strict field when either:
--   (i)  The field is marked '!!', or
--   (ii) The field is marked '!', and the -funbox-strict-fields flag is on.
--
-- We have turned off unboxing of newtypes because coercions make unboxing 
-- and reboxing more complicated
chooseBoxingStrategy :: TcType -> HsBang -> TcM HsBang
chooseBoxingStrategy arg_ty bang
  = case bang of
	HsNoBang -> return HsNoBang
	HsStrict -> do { unbox_strict <- doptM Opt_UnboxStrictFields
                       ; if unbox_strict then return (can_unbox HsStrict arg_ty)
                                         else return HsStrict }
	HsUnpack -> do { omit_prags <- doptM Opt_OmitInterfacePragmas
            -- Do not respect UNPACK pragmas if OmitInterfacePragmas is on
	    -- See Trac #5252: unpacking means we must not conceal the
	    --                 representation of the argument type
                       ; if omit_prags then return HsStrict
                                       else return (can_unbox HsUnpackFailed arg_ty) }
	HsUnpackFailed -> pprPanic "chooseBoxingStrategy" (ppr arg_ty)
		       	  -- Source code never has shtes
  where
    can_unbox :: HsBang -> TcType -> HsBang
    -- Returns   HsUnpack  if we can unpack arg_ty
    -- 		 fail_bang if we know what arg_ty is but we can't unpack it
    -- 		 HsStrict  if it's abstract, so we don't know whether or not we can unbox it
    can_unbox fail_bang arg_ty 
       = case splitTyConApp_maybe arg_ty of
	    Nothing -> fail_bang

	    Just (arg_tycon, tycon_args) 
              | isAbstractTyCon arg_tycon -> HsStrict	
                      -- See Note [Don't complain about UNPACK on abstract TyCons]
              | not (isRecursiveTyCon arg_tycon) 	-- Note [Recusive unboxing]
	      , isProductTyCon arg_tycon 
	      	    -- We can unbox if the type is a chain of newtypes 
		    -- with a product tycon at the end
              -> if isNewTyCon arg_tycon 
                 then can_unbox fail_bang (newTyConInstRhs arg_tycon tycon_args)
                 else HsUnpack

              | otherwise -> fail_bang
\end{code}

Note [Don't complain about UNPACK on abstract TyCons]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We are going to complain about UnpackFailed, but if we say
   data T = MkT {-# UNPACK #-} !Wobble
and Wobble is a newtype imported from a module that was compiled 
without optimisation, we don't want to complain. Because it might
be fine when optimsation is on.  I think this happens when Haddock
is working over (say) GHC souce files.

Note [Recursive unboxing]
~~~~~~~~~~~~~~~~~~~~~~~~~
Be careful not to try to unbox this!
	data T = MkT {-# UNPACK #-} !T Int
Reason: consider
  data R = MkR {-# UNPACK #-} !S Int
  data S = MkS {-# UNPACK #-} !Int
The representation arguments of MkR are the *representation* arguments
of S (plus Int); the rep args of MkS are Int#.  This is obviously no
good for T, because then we'd get an infinite number of arguments.

But it's the *argument* type that matters. This is fine:
	data S = MkS S !Int
because Int is non-recursive.


%************************************************************************
%*									*
		Validity checking
%*									*
%************************************************************************

Validity checking is done once the mutually-recursive knot has been
tied, so we can look at things freely.

\begin{code}
checkClassCycleErrs :: [LTyClDecl Name] -> TcM ()
checkClassCycleErrs tyclss
  | null cls_cycles
  = return ()
  | otherwise
  = do	{ mapM_ recClsErr cls_cycles
	; failM	}	-- Give up now, because later checkValidTyCl
			-- will loop if the synonym is recursive
  where
    cls_cycles = calcClassCycles tyclss

checkValidTyCl :: TyClDecl Name -> TcM ()
-- We do the validity check over declarations, rather than TyThings
-- only so that we can add a nice context with tcAddDeclCtxt
checkValidTyCl decl
  = tcAddDeclCtxt decl $
    do	{ thing <- tcLookupLocatedGlobal (tcdLName decl)
	; traceTc "Validity of" (ppr thing)	
	; case thing of
	    ATyCon tc -> checkValidTyCon tc
	    AClass cl -> do { checkValidClass cl 
                            ; mapM_ (addLocM checkValidTyCl) (tcdATs decl) }
            AnId _    -> return ()  -- Generic default methods are checked
	    	      	 	    -- with their parent class
            _         -> panic "checkValidTyCl"
	; traceTc "Done validity of" (ppr thing)	
	}

-------------------------
-- For data types declared with record syntax, we require
-- that each constructor that has a field 'f' 
--	(a) has the same result type
--	(b) has the same type for 'f'
-- module alpha conversion of the quantified type variables
-- of the constructor.
--
-- Note that we allow existentials to match becuase the
-- fields can never meet. E.g
--	data T where
--	  T1 { f1 :: b, f2 :: a, f3 ::Int } :: T
--	  T2 { f1 :: c, f2 :: c, f3 ::Int } :: T  
-- Here we do not complain about f1,f2 because they are existential

checkValidTyCon :: TyCon -> TcM ()
checkValidTyCon tc 
  | isSynTyCon tc 
  = case synTyConRhs tc of
      SynFamilyTyCon {} -> return ()
      SynonymTyCon ty   -> checkValidType syn_ctxt ty
  | otherwise
  = do	-- Check the context on the data decl
    checkValidTheta (DataTyCtxt name) (tyConStupidTheta tc)
	
	-- Check arg types of data constructors
    mapM_ (checkValidDataCon tc) data_cons

	-- Check that fields with the same name share a type
    mapM_ check_fields groups

  where
    syn_ctxt  = TySynCtxt name
    name      = tyConName tc
    data_cons = tyConDataCons tc

    groups = equivClasses cmp_fld (concatMap get_fields data_cons)
    cmp_fld (f1,_) (f2,_) = f1 `compare` f2
    get_fields con = dataConFieldLabels con `zip` repeat con
	-- dataConFieldLabels may return the empty list, which is fine

    -- See Note [GADT record selectors] in MkId.lhs
    -- We must check (a) that the named field has the same 
    --                   type in each constructor
    --               (b) that those constructors have the same result type
    --
    -- However, the constructors may have differently named type variable
    -- and (worse) we don't know how the correspond to each other.  E.g.
    --     C1 :: forall a b. { f :: a, g :: b } -> T a b
    --     C2 :: forall d c. { f :: c, g :: c } -> T c d
    -- 
    -- So what we do is to ust Unify.tcMatchTys to compare the first candidate's
    -- result type against other candidates' types BOTH WAYS ROUND.
    -- If they magically agrees, take the substitution and
    -- apply them to the latter ones, and see if they match perfectly.
    check_fields ((label, con1) : other_fields)
	-- These fields all have the same name, but are from
	-- different constructors in the data type
	= recoverM (return ()) $ mapM_ checkOne other_fields
                -- Check that all the fields in the group have the same type
		-- NB: this check assumes that all the constructors of a given
		-- data type use the same type variables
        where
	(tvs1, _, _, res1) = dataConSig con1
        ts1 = mkVarSet tvs1
        fty1 = dataConFieldType con1 label

        checkOne (_, con2)    -- Do it bothways to ensure they are structurally identical
	    = do { checkFieldCompat label con1 con2 ts1 res1 res2 fty1 fty2
		 ; checkFieldCompat label con2 con1 ts2 res2 res1 fty2 fty1 }
	    where        
		(tvs2, _, _, res2) = dataConSig con2
	   	ts2 = mkVarSet tvs2
                fty2 = dataConFieldType con2 label
    check_fields [] = panic "checkValidTyCon/check_fields []"

checkFieldCompat :: Name -> DataCon -> DataCon -> TyVarSet
                 -> Type -> Type -> Type -> Type -> TcM ()
checkFieldCompat fld con1 con2 tvs1 res1 res2 fty1 fty2
  = do	{ checkTc (isJust mb_subst1) (resultTypeMisMatch fld con1 con2)
	; checkTc (isJust mb_subst2) (fieldTypeMisMatch fld con1 con2) }
  where
    mb_subst1 = tcMatchTy tvs1 res1 res2
    mb_subst2 = tcMatchTyX tvs1 (expectJust "checkFieldCompat" mb_subst1) fty1 fty2

-------------------------------
checkValidDataCon :: TyCon -> DataCon -> TcM ()
checkValidDataCon tc con
  = setSrcSpan (srcLocSpan (getSrcLoc con))	$
    addErrCtxt (dataConCtxt con)		$ 
    do	{ traceTc "Validity of data con" (ppr con)
        ; let tc_tvs = tyConTyVars tc
	      res_ty_tmpl = mkFamilyTyConApp tc (mkTyVarTys tc_tvs)
	      actual_res_ty = dataConOrigResTy con
	; checkTc (isJust (tcMatchTy (mkVarSet tc_tvs)
				res_ty_tmpl
				actual_res_ty))
		  (badDataConTyCon con res_ty_tmpl actual_res_ty)
	; checkValidMonoType (dataConOrigResTy con)
		-- Disallow MkT :: T (forall a. a->a)
		-- Reason: it's really the argument of an equality constraint
	; checkValidType ctxt (dataConUserType con)
	; when (isNewTyCon tc) (checkNewDataCon con)
        ; mapM_ check_bang (dataConStrictMarks con `zip` [1..])
    }
  where
    ctxt = ConArgCtxt (dataConName con) 
    check_bang (HsUnpackFailed, n) = addWarnTc (cant_unbox_msg n)
    check_bang _                   = return ()

    cant_unbox_msg n = sep [ ptext (sLit "Ignoring unusable UNPACK pragma on the")
                           , speakNth n <+> ptext (sLit "argument of") <+> quotes (ppr con)]

-------------------------------
checkNewDataCon :: DataCon -> TcM ()
-- Checks for the data constructor of a newtype
checkNewDataCon con
  = do	{ checkTc (isSingleton arg_tys) (newtypeFieldErr con (length arg_tys))
		-- One argument
	; checkTc (null eq_spec) (newtypePredError con)
		-- Return type is (T a b c)
	; checkTc (null ex_tvs && null theta) (newtypeExError con)
		-- No existentials
	; checkTc (not (any isBanged (dataConStrictMarks con))) 
		  (newtypeStrictError con)
		-- No strictness
    }
  where
    (_univ_tvs, ex_tvs, eq_spec, theta, arg_tys, _res_ty) = dataConFullSig con

-------------------------------
checkValidClass :: Class -> TcM ()
checkValidClass cls
  = do	{ constrained_class_methods <- xoptM Opt_ConstrainedClassMethods
	; multi_param_type_classes <- xoptM Opt_MultiParamTypeClasses
	; fundep_classes <- xoptM Opt_FunctionalDependencies

    	-- Check that the class is unary, unless GlaExs
	; checkTc (notNull tyvars) (nullaryClassErr cls)
	; checkTc (multi_param_type_classes || unary) (classArityErr cls)
	; checkTc (fundep_classes || null fundeps) (classFunDepsErr cls)

   	-- Check the super-classes
	; checkValidTheta (ClassSCCtxt (className cls)) theta

	-- Check the class operations
	; mapM_ (check_op constrained_class_methods) op_stuff

  	-- Check that if the class has generic methods, then the
	-- class has only one parameter.  We can't do generic
	-- multi-parameter type classes!
	; checkTc (unary || no_generics) (genericMultiParamErr cls)
	}
  where
    (tyvars, fundeps, theta, _, _, op_stuff) = classExtraBigSig cls
    unary 	= isSingleton tyvars
    no_generics = null [() | (_, (GenDefMeth _)) <- op_stuff]

    check_op constrained_class_methods (sel_id, dm) 
      = addErrCtxt (classOpCtxt sel_id tau) $ do
	{ checkValidTheta SigmaCtxt (tail theta)
		-- The 'tail' removes the initial (C a) from the
		-- class itself, leaving just the method type

	; traceTc "class op type" (ppr op_ty <+> ppr tau)
	; checkValidType (FunSigCtxt op_name) tau

		-- Check that the type mentions at least one of
		-- the class type variables...or at least one reachable
		-- from one of the class variables.  Example: tc223
		--   class Error e => Game b mv e | b -> mv e where
		--      newBoard :: MonadState b m => m ()
		-- Here, MonadState has a fundep m->b, so newBoard is fine
	; let grown_tyvars = growThetaTyVars theta (mkVarSet tyvars)
	; checkTc (tyVarsOfType tau `intersectsVarSet` grown_tyvars)
	          (noClassTyVarErr cls sel_id)

        ; case dm of
            GenDefMeth dm_name -> do { dm_id <- tcLookupId dm_name
                                     ; checkValidType (FunSigCtxt op_name) (idType dm_id) }
            _                  -> return ()
	}
	where
	  op_name = idName sel_id
	  op_ty   = idType sel_id
	  (_,theta1,tau1) = tcSplitSigmaTy op_ty
	  (_,theta2,tau2)  = tcSplitSigmaTy tau1
	  (theta,tau) | constrained_class_methods = (theta1 ++ theta2, tau2)
		      | otherwise = (theta1, mkPhiTy (tail theta1) tau1)
		-- Ugh!  The function might have a type like
		-- 	op :: forall a. C a => forall b. (Eq b, Eq a) => tau2
		-- With -XConstrainedClassMethods, we want to allow this, even though the inner 
		-- forall has an (Eq a) constraint.  Whereas in general, each constraint 
		-- in the context of a for-all must mention at least one quantified
		-- type variable.  What a mess!
\end{code}


%************************************************************************
%*									*
		Building record selectors
%*									*
%************************************************************************

\begin{code}
mkDefaultMethodIds :: [TyThing] -> [Id]
-- See Note [Default method Ids and Template Haskell]
mkDefaultMethodIds things
  = [ mkExportedLocalId dm_name (idType sel_id)
    | AClass cls <- things
    , (sel_id, DefMeth dm_name) <- classOpItems cls ]
\end{code}

Note [Default method Ids and Template Haskell]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this (Trac #4169):
   class Numeric a where
     fromIntegerNum :: a
     fromIntegerNum = ...

   ast :: Q [Dec]
   ast = [d| instance Numeric Int |]

When we typecheck 'ast' we have done the first pass over the class decl
(in tcTyClDecls), but we have not yet typechecked the default-method
declarations (becuase they can mention value declarations).  So we 
must bring the default method Ids into scope first (so they can be seen
when typechecking the [d| .. |] quote, and typecheck them later.

\begin{code}
mkRecSelBinds :: [TyCon] -> HsValBinds Name
-- NB We produce *un-typechecked* bindings, rather like 'deriving'
--    This makes life easier, because the later type checking will add
--    all necessary type abstractions and applications
mkRecSelBinds tycons
  = ValBindsOut [(NonRecursive, b) | b <- binds] sigs
  where
    (sigs, binds) = unzip rec_sels
    rec_sels = map mkRecSelBind [ (tc,fld) 
       	 	     	        | tc <- tycons
				, fld <- tyConFields tc ]

mkRecSelBind :: (TyCon, FieldLabel) -> (LSig Name, LHsBinds Name)
mkRecSelBind (tycon, sel_name)
  = (L loc (IdSig sel_id), unitBag (L loc sel_bind))
  where
    loc    	= getSrcSpan tycon    
    sel_id 	= Var.mkLocalVar rec_details sel_name sel_ty vanillaIdInfo
    rec_details = RecSelId { sel_tycon = tycon, sel_naughty = is_naughty }

    -- Find a representative constructor, con1
    all_cons     = tyConDataCons tycon 
    cons_w_field = [ con | con <- all_cons
                   , sel_name `elem` dataConFieldLabels con ] 
    con1 = ASSERT( not (null cons_w_field) ) head cons_w_field

    -- Selector type; Note [Polymorphic selectors]
    field_ty   = dataConFieldType con1 sel_name
    data_ty    = dataConOrigResTy con1
    data_tvs   = tyVarsOfType data_ty
    is_naughty = not (tyVarsOfType field_ty `subVarSet` data_tvs)  
    (field_tvs, field_theta, field_tau) = tcSplitSigmaTy field_ty
    sel_ty | is_naughty = unitTy  -- See Note [Naughty record selectors]
           | otherwise  = mkForAllTys (varSetElems data_tvs ++ field_tvs) $ 
    	     	          mkPhiTy (dataConStupidTheta con1) $	-- Urgh!
    	     	          mkPhiTy field_theta               $	-- Urgh!
             	          mkFunTy data_ty field_tau

    -- Make the binding: sel (C2 { fld = x }) = x
    --                   sel (C7 { fld = x }) = x
    --    where cons_w_field = [C2,C7]
    sel_bind | is_naughty = mkFunBind sel_lname [mkSimpleMatch [] unit_rhs]
             | otherwise  = mkFunBind sel_lname (map mk_match cons_w_field ++ deflt)
    mk_match con = mkSimpleMatch [L loc (mk_sel_pat con)] 
                                 (L loc (HsVar field_var))
    mk_sel_pat con = ConPatIn (L loc (getName con)) (RecCon rec_fields)
    rec_fields = HsRecFields { rec_flds = [rec_field], rec_dotdot = Nothing }
    rec_field  = HsRecField { hsRecFieldId = sel_lname
                            , hsRecFieldArg = nlVarPat field_var
                            , hsRecPun = False }
    sel_lname = L loc sel_name
    field_var = mkInternalName (mkBuiltinUnique 1) (getOccName sel_name) loc

    -- Add catch-all default case unless the case is exhaustive
    -- We do this explicitly so that we get a nice error message that
    -- mentions this particular record selector
    deflt | not (any is_unused all_cons) = []
	  | otherwise = [mkSimpleMatch [nlWildPat] 
	    	      	    (nlHsApp (nlHsVar (getName rEC_SEL_ERROR_ID))
    	      		    	     (nlHsLit msg_lit))]

	-- Do not add a default case unless there are unmatched
	-- constructors.  We must take account of GADTs, else we
	-- get overlap warning messages from the pattern-match checker
    is_unused con = not (con `elem` cons_w_field 
			 || dataConCannotMatch inst_tys con)
    inst_tys = tyConAppArgs data_ty

    unit_rhs = mkLHsTupleExpr []
    msg_lit = HsStringPrim $ mkFastString $ 
              occNameString (getOccName sel_name)

---------------
tyConFields :: TyCon -> [FieldLabel]
tyConFields tc 
  | isAlgTyCon tc = nub (concatMap dataConFieldLabels (tyConDataCons tc))
  | otherwise     = []
\end{code}

Note [Polymorphic selectors]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When a record has a polymorphic field, we pull the foralls out to the front.
   data T = MkT { f :: forall a. [a] -> a }
Then f :: forall a. T -> [a] -> a
NOT  f :: T -> forall a. [a] -> a

This is horrid.  It's only needed in deeply obscure cases, which I hate.
The only case I know is test tc163, which is worth looking at.  It's far
from clear that this test should succeed at all!

Note [Naughty record selectors]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A "naughty" field is one for which we can't define a record 
selector, because an existential type variable would escape.  For example:
        data T = forall a. MkT { x,y::a }
We obviously can't define       
        x (MkT v _) = v
Nevertheless we *do* put a RecSelId into the type environment
so that if the user tries to use 'x' as a selector we can bleat
helpfully, rather than saying unhelpfully that 'x' is not in scope.
Hence the sel_naughty flag, to identify record selectors that don't really exist.

In general, a field is "naughty" if its type mentions a type variable that
isn't in the result type of the constructor.  Note that this *allows*
GADT record selectors (Note [GADT record selectors]) whose types may look 
like     sel :: T [a] -> a

For naughty selectors we make a dummy binding 
   sel = ()
for naughty selectors, so that the later type-check will add them to the
environment, and they'll be exported.  The function is never called, because
the tyepchecker spots the sel_naughty field.

Note [GADT record selectors]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
For GADTs, we require that all constructors with a common field 'f' have the same
result type (modulo alpha conversion).  [Checked in TcTyClsDecls.checkValidTyCon]
E.g. 
        data T where
          T1 { f :: Maybe a } :: T [a]
          T2 { f :: Maybe a, y :: b  } :: T [a]

and now the selector takes that result type as its argument:
   f :: forall a. T [a] -> Maybe a

Details: the "real" types of T1,T2 are:
   T1 :: forall r a.   (r~[a]) => a -> T r
   T2 :: forall r a b. (r~[a]) => a -> b -> T r

So the selector loooks like this:
   f :: forall a. T [a] -> Maybe a
   f (a:*) (t:T [a])
     = case t of
	 T1 c   (g:[a]~[c]) (v:Maybe c)       -> v `cast` Maybe (right (sym g))
         T2 c d (g:[a]~[c]) (v:Maybe c) (w:d) -> v `cast` Maybe (right (sym g))

Note the forall'd tyvars of the selector are just the free tyvars
of the result type; there may be other tyvars in the constructor's
type (e.g. 'b' in T2).

Note the need for casts in the result!

Note [Selector running example]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
It's OK to combine GADTs and type families.  Here's a running example:

        data instance T [a] where 
          T1 { fld :: b } :: T [Maybe b]

The representation type looks like this
        data :R7T a where
          T1 { fld :: b } :: :R7T (Maybe b)

and there's coercion from the family type to the representation type
        :CoR7T a :: T [a] ~ :R7T a

The selector we want for fld looks like this:

        fld :: forall b. T [Maybe b] -> b
        fld = /\b. \(d::T [Maybe b]).
              case d `cast` :CoR7T (Maybe b) of 
                T1 (x::b) -> x

The scrutinee of the case has type :R7T (Maybe b), which can be
gotten by appying the eq_spec to the univ_tvs of the data con.

%************************************************************************
%*									*
		Error messages
%*									*
%************************************************************************

\begin{code}
resultTypeMisMatch :: Name -> DataCon -> DataCon -> SDoc
resultTypeMisMatch field_name con1 con2
  = vcat [sep [ptext (sLit "Constructors") <+> ppr con1 <+> ptext (sLit "and") <+> ppr con2, 
		ptext (sLit "have a common field") <+> quotes (ppr field_name) <> comma],
	  nest 2 $ ptext (sLit "but have different result types")]

fieldTypeMisMatch :: Name -> DataCon -> DataCon -> SDoc
fieldTypeMisMatch field_name con1 con2
  = sep [ptext (sLit "Constructors") <+> ppr con1 <+> ptext (sLit "and") <+> ppr con2, 
	 ptext (sLit "give different types for field"), quotes (ppr field_name)]

dataConCtxt :: Outputable a => a -> SDoc
dataConCtxt con = ptext (sLit "In the definition of data constructor") <+> quotes (ppr con)

classOpCtxt :: Var -> Type -> SDoc
classOpCtxt sel_id tau = sep [ptext (sLit "When checking the class method:"),
			      nest 2 (ppr sel_id <+> dcolon <+> ppr tau)]

nullaryClassErr :: Class -> SDoc
nullaryClassErr cls
  = ptext (sLit "No parameters for class")  <+> quotes (ppr cls)

classArityErr :: Class -> SDoc
classArityErr cls
  = vcat [ptext (sLit "Too many parameters for class") <+> quotes (ppr cls),
	  parens (ptext (sLit "Use -XMultiParamTypeClasses to allow multi-parameter classes"))]

classFunDepsErr :: Class -> SDoc
classFunDepsErr cls
  = vcat [ptext (sLit "Fundeps in class") <+> quotes (ppr cls),
	  parens (ptext (sLit "Use -XFunctionalDependencies to allow fundeps"))]

noClassTyVarErr :: Class -> Var -> SDoc
noClassTyVarErr clas op
  = sep [ptext (sLit "The class method") <+> quotes (ppr op),
	 ptext (sLit "mentions none of the type variables of the class") <+> 
		ppr clas <+> hsep (map ppr (classTyVars clas))]

genericMultiParamErr :: Class -> SDoc
genericMultiParamErr clas
  = ptext (sLit "The multi-parameter class") <+> quotes (ppr clas) <+> 
    ptext (sLit "cannot have generic methods")

recSynErr :: [LTyClDecl Name] -> TcRn ()
recSynErr syn_decls
  = setSrcSpan (getLoc (head sorted_decls)) $
    addErr (sep [ptext (sLit "Cycle in type synonym declarations:"),
		 nest 2 (vcat (map ppr_decl sorted_decls))])
  where
    sorted_decls = sortLocated syn_decls
    ppr_decl (L loc decl) = ppr loc <> colon <+> ppr decl

recClsErr :: [Located (TyClDecl Name)] -> TcRn ()
recClsErr cls_decls
  = setSrcSpan (getLoc (head sorted_decls)) $
    addErr (sep [ptext (sLit "Cycle in class declarations (via superclasses):"),
		 nest 2 (vcat (map ppr_decl sorted_decls))])
  where
    sorted_decls = sortLocated cls_decls
    ppr_decl (L loc decl) = ppr loc <> colon <+> ppr (decl { tcdSigs = [] })

sortLocated :: [Located a] -> [Located a]
sortLocated things = sortLe le things
  where
    le (L l1 _) (L l2 _) = l1 <= l2

badDataConTyCon :: DataCon -> Type -> Type -> SDoc
badDataConTyCon data_con res_ty_tmpl actual_res_ty
  = hang (ptext (sLit "Data constructor") <+> quotes (ppr data_con) <+>
		ptext (sLit "returns type") <+> quotes (ppr actual_res_ty))
       2 (ptext (sLit "instead of an instance of its parent type") <+> quotes (ppr res_ty_tmpl))

badGadtDecl :: Name -> SDoc
badGadtDecl tc_name
  = vcat [ ptext (sLit "Illegal generalised algebraic data declaration for") <+> quotes (ppr tc_name)
	 , nest 2 (parens $ ptext (sLit "Use -XGADTs to allow GADTs")) ]

badExistential :: Located Name -> SDoc
badExistential con_name
  = hang (ptext (sLit "Data constructor") <+> quotes (ppr con_name) <+>
		ptext (sLit "has existential type variables, a context, or a specialised result type"))
       2 (parens $ ptext (sLit "Use -XExistentialQuantification or -XGADTs to allow this"))

badStupidTheta :: Name -> SDoc
badStupidTheta tc_name
  = ptext (sLit "A data type declared in GADT style cannot have a context:") <+> quotes (ppr tc_name)

newtypeConError :: Name -> Int -> SDoc
newtypeConError tycon n
  = sep [ptext (sLit "A newtype must have exactly one constructor,"),
	 nest 2 $ ptext (sLit "but") <+> quotes (ppr tycon) <+> ptext (sLit "has") <+> speakN n ]

newtypeExError :: DataCon -> SDoc
newtypeExError con
  = sep [ptext (sLit "A newtype constructor cannot have an existential context,"),
	 nest 2 $ ptext (sLit "but") <+> quotes (ppr con) <+> ptext (sLit "does")]

newtypeStrictError :: DataCon -> SDoc
newtypeStrictError con
  = sep [ptext (sLit "A newtype constructor cannot have a strictness annotation,"),
	 nest 2 $ ptext (sLit "but") <+> quotes (ppr con) <+> ptext (sLit "does")]

newtypePredError :: DataCon -> SDoc
newtypePredError con
  = sep [ptext (sLit "A newtype constructor must have a return type of form T a1 ... an"),
	 nest 2 $ ptext (sLit "but") <+> quotes (ppr con) <+> ptext (sLit "does not")]

newtypeFieldErr :: DataCon -> Int -> SDoc
newtypeFieldErr con_name n_flds
  = sep [ptext (sLit "The constructor of a newtype must have exactly one field"), 
	 nest 2 $ ptext (sLit "but") <+> quotes (ppr con_name) <+> ptext (sLit "has") <+> speakN n_flds]

badSigTyDecl :: Name -> SDoc
badSigTyDecl tc_name
  = vcat [ ptext (sLit "Illegal kind signature") <+>
	   quotes (ppr tc_name)
	 , nest 2 (parens $ ptext (sLit "Use -XKindSignatures to allow kind signatures")) ]

badFamInstDecl :: Outputable a => a -> SDoc
badFamInstDecl tc_name
  = vcat [ ptext (sLit "Illegal family instance for") <+>
	   quotes (ppr tc_name)
	 , nest 2 (parens $ ptext (sLit "Use -XTypeFamilies to allow indexed type families")) ]

emptyConDeclsErr :: Name -> SDoc
emptyConDeclsErr tycon
  = sep [quotes (ppr tycon) <+> ptext (sLit "has no constructors"),
	 nest 2 $ ptext (sLit "(-XEmptyDataDecls permits this)")]
\end{code}
