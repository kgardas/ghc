(c) The University of Glasgow 2002-2006

\begin{code}
module IfaceEnv (
	newGlobalBinder, newIPName, newImplicitBinder, 
	lookupIfaceTop,
	lookupOrig, lookupOrigNameCache, extendNameCache,
	newIfaceName, newIfaceNames,
	extendIfaceIdEnv, extendIfaceTyVarEnv, 
	tcIfaceLclId, tcIfaceTyVar, lookupIfaceTyVar,
	tcIfaceTick,

	ifaceExportNames,

	-- Name-cache stuff
	allocateGlobalBinder, initNameCache, updNameCache,
        getNameCache, mkNameCacheUpdater, NameCacheUpdater
   ) where

#include "HsVersions.h"

import TcRnMonad
import TysWiredIn
import HscTypes
import TyCon
import DataCon
import Var
import Name
import PrelNames
import Module
import UniqFM
import FastString
import UniqSupply
import BasicTypes
import SrcLoc
import MkId

import Outputable
import Exception     ( evaluate )

import Data.IORef    ( atomicModifyIORef, readIORef )
import qualified Data.Map as Map
\end{code}


%*********************************************************
%*							*
	Allocating new Names in the Name Cache
%*							*
%*********************************************************

\begin{code}
newGlobalBinder :: Module -> OccName -> SrcSpan -> TcRnIf a b Name
-- Used for source code and interface files, to make the
-- Name for a thing, given its Module and OccName
--
-- The cache may already already have a binding for this thing,
-- because we may have seen an occurrence before, but now is the
-- moment when we know its Module and SrcLoc in their full glory

newGlobalBinder mod occ loc
  = do mod `seq` occ `seq` return ()	-- See notes with lookupOrig
--     traceIf (text "newGlobalBinder" <+> ppr mod <+> ppr occ <+> ppr loc)
       updNameCache $ \name_cache ->
         allocateGlobalBinder name_cache mod occ loc

allocateGlobalBinder
  :: NameCache 
  -> Module -> OccName -> SrcSpan
  -> (NameCache, Name)
allocateGlobalBinder name_supply mod occ loc
  = case lookupOrigNameCache (nsNames name_supply) mod occ of
	-- A hit in the cache!  We are at the binding site of the name.
	-- This is the moment when we know the SrcLoc
	-- of the Name, so we set this field in the Name we return.
	--
	-- Then (bogus) multiple bindings of the same Name
	-- get different SrcLocs can can be reported as such.
	--
	-- Possible other reason: it might be in the cache because we
	-- 	encountered an occurrence before the binding site for an
	--	implicitly-imported Name.  Perhaps the current SrcLoc is
	--	better... but not really: it'll still just say 'imported'
	--
	-- IMPORTANT: Don't mess with wired-in names.  
	-- 	      Their wired-in-ness is in their NameSort
	--	      and their Module is correct.

	Just name | isWiredInName name -> (name_supply, name)
		  | otherwise -> (new_name_supply, name')
		  where
		    uniq      = nameUnique name
		    name'     = mkExternalName uniq mod occ loc
		    new_cache = extendNameCache (nsNames name_supply) mod occ name'
		    new_name_supply = name_supply {nsNames = new_cache}		     

	-- Miss in the cache!
	-- Build a completely new Name, and put it in the cache
	Nothing -> (new_name_supply, name)
		where
		  (uniq, us')     = takeUniqFromSupply (nsUniqs name_supply)
		  name            = mkExternalName uniq mod occ loc
		  new_cache       = extendNameCache (nsNames name_supply) mod occ name
		  new_name_supply = name_supply {nsUniqs = us', nsNames = new_cache}


newImplicitBinder :: Name			-- Base name
	          -> (OccName -> OccName) 	-- Occurrence name modifier
	          -> TcRnIf m n Name		-- Implicit name
-- Called in BuildTyCl to allocate the implicit binders of type/class decls
-- For source type/class decls, this is the first occurrence
-- For iface ones, the LoadIface has alrady allocated a suitable name in the cache
newImplicitBinder base_name mk_sys_occ
  | Just mod <- nameModule_maybe base_name
  = newGlobalBinder mod occ loc
  | otherwise	  	-- When typechecking a [d| decl bracket |], 
    			-- TH generates types, classes etc with Internal names,
			-- so we follow suit for the implicit binders
  = do	{ uniq <- newUnique
	; return (mkInternalName uniq occ loc) }
  where
    occ = mk_sys_occ (nameOccName base_name)
    loc = nameSrcSpan base_name

ifaceExportNames :: [IfaceExport] -> TcRnIf gbl lcl [AvailInfo]
ifaceExportNames exports = return exports

lookupOrig :: Module -> OccName ->  TcRnIf a b Name
lookupOrig mod occ
  = do 	{ 	-- First ensure that mod and occ are evaluated
		-- If not, chaos can ensue:
		-- 	we read the name-cache
		-- 	then pull on mod (say)
		--	which does some stuff that modifies the name cache
		-- This did happen, with tycon_mod in TcIface.tcIfaceAlt (DataAlt..)
	  mod `seq` occ `seq` return ()	
--	; traceIf (text "lookup_orig" <+> ppr mod <+> ppr occ)

        ; updNameCache $ \name_cache ->
            case lookupOrigNameCache (nsNames name_cache) mod occ of {
	      Just name -> (name_cache, name);
	      Nothing   ->
              case takeUniqFromSupply (nsUniqs name_cache) of {
              (uniq, us) ->
                  let
                    name      = mkExternalName uniq mod occ noSrcSpan
                    new_cache = extendNameCache (nsNames name_cache) mod occ name
                  in (name_cache{ nsUniqs = us, nsNames = new_cache }, name)
    }}}

newIPName :: IPName OccName -> TcRnIf m n (IPName Name)
newIPName occ_name_ip =
  updNameCache $ \name_cache ->
    let
	ipcache = nsIPs name_cache
        key = occ_name_ip  -- Ensures that ?x and %x get distinct Names
    in
    case Map.lookup key ipcache of
      Just name_ip -> (name_cache, name_ip)
      Nothing      -> (new_ns, name_ip)
	  where
	    (uniq, us') = takeUniqFromSupply (nsUniqs name_cache)
	    name_ip     = mapIPName (mkIPName uniq) occ_name_ip
	    new_ipcache = Map.insert key name_ip ipcache
	    new_ns      = name_cache {nsUniqs = us', nsIPs = new_ipcache}
\end{code}

%************************************************************************
%*									*
		Name cache access
%*									*
%************************************************************************

\begin{code}
lookupOrigNameCache :: OrigNameCache -> Module -> OccName -> Maybe Name
lookupOrigNameCache _ mod occ
  -- XXX Why is gHC_UNIT not mentioned here?
  | mod == gHC_TUPLE || mod == gHC_PRIM,		-- Boxed tuples from one, 
    Just tup_info <- isTupleOcc_maybe occ	-- unboxed from the other
  = 	-- Special case for tuples; there are too many
	-- of them to pre-populate the original-name cache
    Just (mk_tup_name tup_info)
  where
    mk_tup_name (ns, boxity, arity)
	| ns == tcName   = tyConName (tupleTyCon boxity arity)
	| ns == dataName = dataConName (tupleCon boxity arity)
	| otherwise      = Var.varName (dataConWorkId (tupleCon boxity arity))

lookupOrigNameCache nc mod occ	-- The normal case
  = case lookupModuleEnv nc mod of
	Nothing      -> Nothing
	Just occ_env -> lookupOccEnv occ_env occ

extendOrigNameCache :: OrigNameCache -> Name -> OrigNameCache
extendOrigNameCache nc name 
  = ASSERT2( isExternalName name, ppr name ) 
    extendNameCache nc (nameModule name) (nameOccName name) name

extendNameCache :: OrigNameCache -> Module -> OccName -> Name -> OrigNameCache
extendNameCache nc mod occ name
  = extendModuleEnvWith combine nc mod (unitOccEnv occ name)
  where
    combine _ occ_env = extendOccEnv occ_env occ name

getNameCache :: TcRnIf a b NameCache
getNameCache = do { HscEnv { hsc_NC = nc_var } <- getTopEnv; 
		    readMutVar nc_var }

updNameCache :: (NameCache -> (NameCache, c)) -> TcRnIf a b c
updNameCache upd_fn = do
  HscEnv { hsc_NC = nc_var } <- getTopEnv
  atomicUpdMutVar' nc_var upd_fn

-- | A function that atomically updates the name cache given a modifier
-- function.  The second result of the modifier function will be the result
-- of the IO action.
type NameCacheUpdater c = (NameCache -> (NameCache, c)) -> IO c

-- | Return a function to atomically update the name cache.
mkNameCacheUpdater :: TcRnIf a b (NameCacheUpdater c)
mkNameCacheUpdater = do
  nc_var <- hsc_NC `fmap` getTopEnv
  let update_nc f = do r <- atomicModifyIORef nc_var f
                       _ <- evaluate =<< readIORef nc_var
                       return r
  return update_nc
\end{code}


\begin{code}
initNameCache :: UniqSupply -> [Name] -> NameCache
initNameCache us names
  = NameCache { nsUniqs = us,
		nsNames = initOrigNames names,
		nsIPs   = Map.empty }

initOrigNames :: [Name] -> OrigNameCache
initOrigNames names = foldl extendOrigNameCache emptyModuleEnv names
\end{code}



%************************************************************************
%*									*
		Type variables and local Ids
%*									*
%************************************************************************

\begin{code}
tcIfaceLclId :: FastString -> IfL Id
tcIfaceLclId occ
  = do	{ lcl <- getLclEnv
	; case (lookupUFM (if_id_env lcl) occ) of
            Just ty_var -> return ty_var
            Nothing     -> failIfM (text "Iface id out of scope: " <+> ppr occ)
        }

extendIfaceIdEnv :: [Id] -> IfL a -> IfL a
extendIfaceIdEnv ids thing_inside
  = do	{ env <- getLclEnv
	; let { id_env' = addListToUFM (if_id_env env) pairs
	      ;	pairs   = [(occNameFS (getOccName id), id) | id <- ids] }
	; setLclEnv (env { if_id_env = id_env' }) thing_inside }


tcIfaceTyVar :: FastString -> IfL TyVar
tcIfaceTyVar occ
  = do	{ lcl <- getLclEnv
	; case (lookupUFM (if_tv_env lcl) occ) of
            Just ty_var -> return ty_var
            Nothing     -> failIfM (text "Iface type variable out of scope: " <+> ppr occ)
        }

lookupIfaceTyVar :: FastString -> IfL (Maybe TyVar)
lookupIfaceTyVar occ
  = do	{ lcl <- getLclEnv
	; return (lookupUFM (if_tv_env lcl) occ) }

extendIfaceTyVarEnv :: [TyVar] -> IfL a -> IfL a
extendIfaceTyVarEnv tyvars thing_inside
  = do	{ env <- getLclEnv
	; let { tv_env' = addListToUFM (if_tv_env env) pairs
	      ;	pairs   = [(occNameFS (getOccName tv), tv) | tv <- tyvars] }
	; setLclEnv (env { if_tv_env = tv_env' }) thing_inside }
\end{code}


%************************************************************************
%*									*
		Getting from RdrNames to Names
%*									*
%************************************************************************

\begin{code}
lookupIfaceTop :: OccName -> IfL Name
-- Look up a top-level name from the current Iface module
lookupIfaceTop occ
  = do	{ env <- getLclEnv; lookupOrig (if_mod env) occ }

newIfaceName :: OccName -> IfL Name
newIfaceName occ
  = do	{ uniq <- newUnique
	; return $! mkInternalName uniq occ noSrcSpan }

newIfaceNames :: [OccName] -> IfL [Name]
newIfaceNames occs
  = do	{ uniqs <- newUniqueSupply
	; return [ mkInternalName uniq occ noSrcSpan
		 | (occ,uniq) <- occs `zip` uniqsFromSupply uniqs] }
\end{code}

%************************************************************************
%*									*
		(Re)creating tick boxes
%*									*
%************************************************************************

\begin{code}
tcIfaceTick :: Module -> Int -> IfL Id
tcIfaceTick modName tickNo 
  = do { uniq <- newUnique
       ; return $ mkTickBoxOpId uniq modName tickNo
       }
\end{code}


