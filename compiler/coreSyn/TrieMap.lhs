%
% (c) The University of Glasgow 2006
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%

\begin{code}
{-# LANGUAGE TypeFamilies #-}
module TrieMap(
   CoreMap, emptyCoreMap, extendCoreMap, lookupCoreMap, foldCoreMap,
   TypeMap, 
   CoercionMap, 
   MaybeMap, 
   ListMap,
   TrieMap(..)
 ) where

import CoreSyn
import Coercion
import Literal
import Name
import Type
import TypeRep
import Var
import CostCentre
import UniqFM
import Unique( Unique )

import qualified Data.Map    as Map
import qualified Data.IntMap as IntMap
import VarEnv
import NameEnv
import Outputable
import Control.Monad( (>=>) )
\end{code}

This module implements TrieMaps, which are finite mappings
whose key is a structured value like a CoreExpr or Type.

The code is very regular and boilerplate-like, but there is
some neat handling of *binders*.  In effect they are deBruijn 
numbered on the fly.

%************************************************************************
%*									*
                   The TrieMap class
%*									*
%************************************************************************

\begin{code}
type XT a = Maybe a -> Maybe a	-- How to alter a non-existent elt (Nothing)
     	    	       		--               or an existing elt (Just)

class TrieMap m where
   type Key m :: *
   emptyTM  :: m a
   lookupTM :: forall b. Key m -> m b -> Maybe b
   alterTM  :: forall b. Key m -> XT b -> m b -> m b

   foldTM   :: (a -> b -> b) -> m a -> b -> b
      -- The unusual argument order here makes 
      -- it easy to compose calls to foldTM; 
      -- see for example fdE below

----------------------
-- Recall that 
--   Control.Monad.(>=>) :: (a -> Maybe b) -> (b -> Maybe c) -> a -> Maybe c

(>.>) :: (a -> b) -> (b -> c) -> a -> c
-- Reverse function composition (do f first, then g)
infixr 1 >.>
(f >.> g) x = g (f x)
infixr 1 |>, |>>

(|>) :: a -> (a->b) -> b     -- Reverse application
x |> f = f x

----------------------
(|>>) :: TrieMap m2 
      => (XT (m2 a) -> m1 (m2 a) -> m1 (m2 a))
      -> (m2 a -> m2 a)
      -> m1 (m2 a) -> m1 (m2 a)
(|>>) f g = f (Just . g . deMaybe)

deMaybe :: TrieMap m => Maybe (m a) -> m a
deMaybe Nothing  = emptyTM
deMaybe (Just m) = m
\end{code}

%************************************************************************
%*									*
                   IntMaps
%*									*
%************************************************************************

\begin{code}
instance TrieMap IntMap.IntMap where
  type Key IntMap.IntMap = Int
  emptyTM = IntMap.empty
  lookupTM k m = IntMap.lookup k m
  alterTM = xtInt
  foldTM k m z = IntMap.fold k z m

xtInt :: Int -> XT a -> IntMap.IntMap a -> IntMap.IntMap a
xtInt k f m = IntMap.alter f k m

instance Ord k => TrieMap (Map.Map k) where
  type Key (Map.Map k) = k
  emptyTM = Map.empty
  lookupTM = Map.lookup
  alterTM k f m = Map.alter f k m
  foldTM k m z = Map.fold k z m

instance TrieMap UniqFM where
  type Key UniqFM = Unique
  emptyTM = emptyUFM
  lookupTM k m = lookupUFM m k
  alterTM k f m = alterUFM f m k
  foldTM k m z = foldUFM k z m
\end{code}


%************************************************************************
%*									*
                   Lists
%*									*
%************************************************************************

\begin{code}
data MaybeMap m a = MM { mm_nothing  :: Maybe a, mm_just :: m a }

instance TrieMap m => TrieMap (MaybeMap m) where
   type Key (MaybeMap m) = Maybe (Key m)
   emptyTM  = MM { mm_nothing = Nothing, mm_just = emptyTM }
   lookupTM = lkMaybe lookupTM
   alterTM  = xtMaybe alterTM
   foldTM   = fdMaybe 

lkMaybe :: TrieMap m => (forall b. k -> m b -> Maybe b)
        -> Maybe k -> MaybeMap m a -> Maybe a
lkMaybe _  Nothing  = mm_nothing
lkMaybe lk (Just x) = mm_just >.> lk x

xtMaybe :: TrieMap m => (forall b. k -> XT b -> m b -> m b)
        -> Maybe k -> XT a -> MaybeMap m a -> MaybeMap m a
xtMaybe _  Nothing  f m = m { mm_nothing  = f (mm_nothing m) }
xtMaybe tr (Just x) f m = m { mm_just = mm_just m |> tr x f }

fdMaybe :: TrieMap m => (a -> b -> b) -> MaybeMap m a -> b -> b
fdMaybe k m = foldMaybe k (mm_nothing m)
            . foldTM k (mm_just m)

--------------------
data ListMap m a
  = LM { lm_nil  :: Maybe a
       , lm_cons :: m (ListMap m a) }

instance TrieMap m => TrieMap (ListMap m) where
   type Key (ListMap m) = [Key m]
   emptyTM  = LM { lm_nil = Nothing, lm_cons = emptyTM }
   lookupTM = lkList lookupTM
   alterTM = xtList alterTM
   foldTM   = fdList 

lkList :: TrieMap m => (forall b. k -> m b -> Maybe b)
        -> [k] -> ListMap m a -> Maybe a
lkList _  []     = lm_nil
lkList lk (x:xs) = lm_cons >.> lk x >=> lkList lk xs

xtList :: TrieMap m => (forall b. k -> XT b -> m b -> m b)
        -> [k] -> XT a -> ListMap m a -> ListMap m a
xtList _  []     f m = m { lm_nil  = f (lm_nil m) }
xtList tr (x:xs) f m = m { lm_cons = lm_cons m |> tr x |>> xtList tr xs f }

fdList :: forall m a b. TrieMap m 
       => (a -> b -> b) -> ListMap m a -> b -> b
fdList k m = foldMaybe k          (lm_nil m)
           . foldTM    (fdList k) (lm_cons m)

foldMaybe :: (a -> b -> b) -> Maybe a -> b -> b
foldMaybe _ Nothing  b = b
foldMaybe k (Just a) b = k a b
\end{code}


%************************************************************************
%*									*
                   Basic maps
%*									*
%************************************************************************

\begin{code}
lkNamed :: NamedThing n => n -> NameEnv a -> Maybe a
lkNamed n env = lookupNameEnv env (getName n)

xtNamed :: NamedThing n => n -> XT a -> NameEnv a -> NameEnv a
xtNamed tc f m = alterNameEnv f m (getName tc)

------------------------
type LiteralMap  a = Map.Map Literal a

emptyLiteralMap :: LiteralMap a
emptyLiteralMap = emptyTM

lkLit :: Literal -> LiteralMap a -> Maybe a
lkLit = lookupTM

xtLit :: Literal -> XT a -> LiteralMap a -> LiteralMap a
xtLit = alterTM
\end{code}

%************************************************************************
%*									*
                   CoreMap
%*									*
%************************************************************************

Note [Binders]
~~~~~~~~~~~~~~
 * In general we check binders as late as possible because types are
   less likely to differ than expression structure.  That's why
      cm_lam :: CoreMap (TypeMap a)
   rather than
      cm_lam :: TypeMap (CoreMap a)

 * We don't need to look at the type of some binders, notalby
     - the case binder in (Case _ b _ _)
     - the binders in an alternative
   because they are totally fixed by the context


\begin{code}
data CoreMap a
  = EmptyCM
  | CM { cm_var  :: VarMap a
       , cm_lit  :: LiteralMap a
       , cm_co   :: CoercionMap a
       , cm_type :: TypeMap a
       , cm_cast :: CoreMap (CoercionMap a)
       , cm_scc  :: CoreMap (CostCentreMap a)
       , cm_app  :: CoreMap (CoreMap a)
       , cm_lam  :: CoreMap (TypeMap a)
       , cm_letn :: CoreMap (CoreMap (BndrMap a))
       , cm_letr :: ListMap CoreMap (CoreMap (ListMap BndrMap a))
       , cm_case :: CoreMap (ListMap AltMap a)
       	 -- Note [Binders]
     }


wrapEmptyCM :: CoreMap a
wrapEmptyCM = CM { cm_var = emptyTM, cm_lit = emptyLiteralMap
 		 , cm_co = emptyTM, cm_type = emptyTM
 		 , cm_cast = emptyTM, cm_app = emptyTM 
 		 , cm_lam = emptyTM, cm_letn = emptyTM 
 		 , cm_letr = emptyTM, cm_case = emptyTM
                 , cm_scc = emptyTM } 

instance TrieMap CoreMap where
   type Key CoreMap = CoreExpr
   emptyTM  = EmptyCM
   lookupTM = lkE emptyCME
   alterTM = xtE emptyCME
   foldTM   = fdE

--------------------------
lookupCoreMap :: CoreMap a -> CoreExpr -> Maybe a
lookupCoreMap cm e = lkE emptyCME e cm

extendCoreMap :: CoreMap a -> CoreExpr -> a -> CoreMap a
extendCoreMap m e v = xtE emptyCME e (\_ -> Just v) m

foldCoreMap :: (a -> b -> b) -> b -> CoreMap a -> b
foldCoreMap k z m = fdE k m z

emptyCoreMap :: CoreMap a
emptyCoreMap = EmptyCM

instance Outputable a => Outputable (CoreMap a) where
  ppr m = text "CoreMap elts" <+> ppr (foldCoreMap (:) [] m)

-------------------------
fdE :: (a -> b -> b) -> CoreMap a -> b -> b
fdE _ EmptyCM = \z -> z
fdE k m 
  = foldTM k (cm_var m) 
  . foldTM k (cm_lit m)
  . foldTM k (cm_co m)
  . foldTM k (cm_type m)
  . foldTM (foldTM k) (cm_cast m)
  . foldTM (foldTM k) (cm_scc m)
  . foldTM (foldTM k) (cm_app m)
  . foldTM (foldTM k) (cm_lam m)
  . foldTM (foldTM (foldTM k)) (cm_letn m)
  . foldTM (foldTM (foldTM k)) (cm_letr m)
  . foldTM (foldTM k) (cm_case m)

lkE :: CmEnv -> CoreExpr -> CoreMap a -> Maybe a
-- lkE: lookup in trie for expressions
lkE env expr cm
  | EmptyCM <- cm = Nothing
  | otherwise     = go expr cm
  where 
    go (Var v)  	    = cm_var  >.> lkVar env v
    go (Lit l)              = cm_lit  >.> lkLit l
    go (Type t) 	    = cm_type >.> lkT env t
    go (Coercion c)         = cm_co   >.> lkC env c
    go (Cast e c)           = cm_cast >.> lkE env e >=> lkC env c
    go (Note (SCC cc) e)    = cm_scc  >.> lkE env e >=> lkCC cc
    go (Note _        e)    = lkE env e
    go (App e1 e2)          = cm_app >.> lkE env e2 >=> lkE env e1
    go (Lam v e)            = cm_lam >.> lkE (extendCME env v) e >=> lkBndr env v
    go (Let (NonRec b r) e) = cm_letn >.> lkE env r 
                              >=> lkE (extendCME env b) e >=> lkBndr env b
    go (Let (Rec prs) e)    = let (bndrs,rhss) = unzip prs
                                  env1 = extendCMEs env bndrs
                              in cm_letr
                                 >.> lkList (lkE env1) rhss >=> lkE env1 e
                                 >=> lkList (lkBndr env1) bndrs
    go (Case e b _ as)      = cm_case >.> lkE env e 
                              >=> lkList (lkA (extendCME env b)) as

xtE :: CmEnv -> CoreExpr -> XT a -> CoreMap a -> CoreMap a
xtE env e              f EmptyCM = xtE env e f wrapEmptyCM
xtE env (Var v)              f m = m { cm_var  = cm_var m  |> xtVar env v f }
xtE env (Type t) 	     f m = m { cm_type = cm_type m |> xtT env t f }
xtE env (Coercion c)         f m = m { cm_co   = cm_co m   |> xtC env c f }
xtE _   (Lit l)              f m = m { cm_lit  = cm_lit m  |> xtLit l f }
xtE env (Cast e c)           f m = m { cm_cast = cm_cast m |> xtE env e |>>
                                                 xtC env c f }
xtE env (Note (SCC cc) e)    f m = m { cm_scc = cm_scc m |> xtE env e |>> xtCC cc f }
xtE env (Note _        e)    f m = xtE env e f m
xtE env (App e1 e2)          f m = m { cm_app = cm_app m |> xtE env e2 |>> xtE env e1 f }
xtE env (Lam v e)            f m = m { cm_lam = cm_lam m |> xtE (extendCME env v) e
                                                 |>> xtBndr env v f }
xtE env (Let (NonRec b r) e) f m = m { cm_letn = cm_letn m 
                                                 |> xtE (extendCME env b) e 
                                                 |>> xtE env r |>> xtBndr env b f }
xtE env (Let (Rec prs) e)    f m = m { cm_letr = let (bndrs,rhss) = unzip prs
                                                     env1 = extendCMEs env bndrs
                                                 in cm_letr m 
                                                    |>  xtList (xtE env1) rhss 
                                                    |>> xtE env1 e 
                                                    |>> xtList (xtBndr env1) bndrs f }
xtE env (Case e b _ as)      f m = m { cm_case = cm_case m |> xtE env e 
                                                 |>> let env1 = extendCME env b
                                                     in xtList (xtA env1) as f }

type CostCentreMap a = Map.Map CostCentre a
lkCC :: CostCentre -> CostCentreMap a -> Maybe a
lkCC = lookupTM

xtCC :: CostCentre -> XT a -> CostCentreMap a -> CostCentreMap a
xtCC = alterTM

------------------------
data AltMap a	-- A single alternative
  = AM { am_deflt :: CoreMap a
       , am_data  :: NameEnv (CoreMap a)
       , am_lit   :: LiteralMap (CoreMap a) }

instance TrieMap AltMap where
   type Key AltMap = CoreAlt
   emptyTM  = AM { am_deflt = emptyTM
                 , am_data = emptyNameEnv
                 , am_lit  = emptyLiteralMap }
   lookupTM = lkA emptyCME
   alterTM = xtA emptyCME
   foldTM = fdA

lkA :: CmEnv -> CoreAlt -> AltMap a -> Maybe a
lkA env (DEFAULT,    _, rhs)  = am_deflt >.> lkE env rhs
lkA env (LitAlt lit, _, rhs)  = am_lit >.> lkLit lit >=> lkE env rhs
lkA env (DataAlt dc, bs, rhs) = am_data >.> lkNamed dc >=> lkE (extendCMEs env bs) rhs

xtA :: CmEnv -> CoreAlt -> XT a -> AltMap a -> AltMap a
xtA env (DEFAULT, _, rhs)    f m = m { am_deflt = am_deflt m |> xtE env rhs f }
xtA env (LitAlt l, _, rhs)   f m = m { am_lit   = am_lit m   |> xtLit l |>> xtE env rhs f }
xtA env (DataAlt d, bs, rhs) f m = m { am_data  = am_data m  |> xtNamed d 
                                                             |>> xtE (extendCMEs env bs) rhs f }

fdA :: (a -> b -> b) -> AltMap a -> b -> b
fdA k m = foldTM k (am_deflt m)
        . foldTM (foldTM k) (am_data m)
        . foldTM (foldTM k) (am_lit m)
\end{code}

%************************************************************************
%*									*
                   Coercions
%*									*
%************************************************************************

\begin{code}
data CoercionMap a 
  = EmptyKM
  | KM { km_refl :: TypeMap a
       , km_tc_app :: NameEnv (ListMap CoercionMap a)
       , km_app    :: CoercionMap (CoercionMap a)
       , km_forall :: CoercionMap (TypeMap a)
       , km_var    :: VarMap a
       , km_axiom  :: NameEnv (ListMap CoercionMap a)
       , km_unsafe :: TypeMap (TypeMap a)
       , km_sym    :: CoercionMap a
       , km_trans  :: CoercionMap (CoercionMap a)
       , km_nth    :: IntMap.IntMap (CoercionMap a)
       , km_inst   :: CoercionMap (TypeMap a) }

wrapEmptyKM :: CoercionMap a
wrapEmptyKM = KM { km_refl = emptyTM, km_tc_app = emptyNameEnv
                 , km_app = emptyTM, km_forall = emptyTM
                 , km_var = emptyTM, km_axiom = emptyNameEnv
                 , km_unsafe = emptyTM, km_sym = emptyTM, km_trans = emptyTM
                 , km_nth = emptyTM, km_inst = emptyTM }

instance TrieMap CoercionMap where
   type Key CoercionMap = Coercion
   emptyTM  = EmptyKM
   lookupTM = lkC emptyCME
   alterTM = xtC emptyCME
   foldTM = fdC

lkC :: CmEnv -> Coercion -> CoercionMap a -> Maybe a
lkC env co m 
  | EmptyKM <- m = Nothing
  | otherwise    = go co m
  where
    go (Refl ty)           = km_refl   >.> lkT env ty
    go (TyConAppCo tc cs)  = km_tc_app >.> lkNamed tc >=> lkList (lkC env) cs
    go (AxiomInstCo ax cs) = km_axiom  >.> lkNamed ax >=> lkList (lkC env) cs
    go (AppCo c1 c2)       = km_app    >.> lkC env c1 >=> lkC env c2
    go (TransCo c1 c2)     = km_trans  >.> lkC env c1 >=> lkC env c2
    go (UnsafeCo t1 t2)    = km_unsafe >.> lkT env t1 >=> lkT env t2
    go (InstCo c t)        = km_inst   >.> lkC env c  >=> lkT env t
    go (ForAllCo v c)      = km_forall >.> lkC (extendCME env v) c >=> lkBndr env v
    go (CoVarCo v)         = km_var    >.> lkVar env v
    go (SymCo c)           = km_sym    >.> lkC env c
    go (NthCo n c)         = km_nth    >.> lookupTM n >=> lkC env c

xtC :: CmEnv -> Coercion -> XT a -> CoercionMap a -> CoercionMap a
xtC env co f EmptyKM = xtC env co f wrapEmptyKM
xtC env (Refl ty)           f m = m { km_refl   = km_refl m   |> xtT env ty f }
xtC env (TyConAppCo tc cs)  f m = m { km_tc_app = km_tc_app m |> xtNamed tc |>> xtList (xtC env) cs f }
xtC env (AxiomInstCo ax cs) f m = m { km_axiom  = km_axiom m  |> xtNamed ax |>> xtList (xtC env) cs f }
xtC env (AppCo c1 c2)       f m = m { km_app    = km_app m    |> xtC env c1 |>> xtC env c2 f }
xtC env (TransCo c1 c2)     f m = m { km_trans  = km_trans m  |> xtC env c1 |>> xtC env c2 f }
xtC env (UnsafeCo t1 t2)    f m = m { km_unsafe = km_unsafe m |> xtT env t1 |>> xtT env t2 f }
xtC env (InstCo c t)        f m = m { km_inst   = km_inst m   |> xtC env c  |>> xtT env t  f }
xtC env (ForAllCo v c)      f m = m { km_forall = km_forall m |> xtC (extendCME env v) c 
                                                  |>> xtBndr env v f }
xtC env (CoVarCo v)         f m = m { km_var 	= km_var m |> xtVar env  v f }
xtC env (SymCo c)           f m = m { km_sym 	= km_sym m |> xtC env    c f }
xtC env (NthCo n c)         f m = m { km_nth 	= km_nth m |> xtInt n |>> xtC env c f } 

fdC :: (a -> b -> b) -> CoercionMap a -> b -> b
fdC _ EmptyKM = \z -> z
fdC k m = foldTM k (km_refl m)
        . foldTM (foldTM k) (km_tc_app m)
        . foldTM (foldTM k) (km_app m)
        . foldTM (foldTM k) (km_forall m)
        . foldTM k (km_var m)
        . foldTM (foldTM k) (km_axiom m)
        . foldTM (foldTM k) (km_unsafe m)
        . foldTM k (km_sym m)
        . foldTM (foldTM k) (km_trans m)
        . foldTM (foldTM k) (km_nth m)
        . foldTM (foldTM k) (km_inst m)
\end{code}


%************************************************************************
%*									*
                   Types
%*									*
%************************************************************************

\begin{code}
data TypeMap a
  = EmptyTM
  | TM { tm_var   :: VarMap a
       , tm_app    :: TypeMap (TypeMap a)
       , tm_fun    :: TypeMap (TypeMap a)
       , tm_tc_app :: NameEnv (ListMap TypeMap a)
       , tm_forall :: TypeMap (BndrMap a) }

wrapEmptyTypeMap :: TypeMap a
wrapEmptyTypeMap = TM { tm_var  = emptyTM
                      , tm_app  = EmptyTM
                      , tm_fun  = EmptyTM
                      , tm_tc_app = emptyNameEnv
                      , tm_forall = EmptyTM }

instance TrieMap TypeMap where
   type Key TypeMap = Type
   emptyTM  = EmptyTM
   lookupTM = lkT emptyCME
   alterTM = xtT emptyCME
   foldTM = fdT

-----------------
lkT :: CmEnv -> Type -> TypeMap a -> Maybe a
lkT env ty m
  | EmptyTM <- m = Nothing
  | otherwise    = go ty m
  where
    go ty | Just ty' <- coreView ty = go ty'
    go (TyVarTy v)       = tm_var    >.> lkVar env v
    go (AppTy t1 t2)     = tm_app    >.> lkT env t1 >=> lkT env t2
    go (FunTy t1 t2)     = tm_fun    >.> lkT env t1 >=> lkT env t2
    go (TyConApp tc tys) = tm_tc_app >.> lkNamed tc >=> lkList (lkT env) tys
    go (ForAllTy tv ty)  = tm_forall >.> lkT (extendCME env tv) ty >=> lkBndr env tv
    go (PredTy {})       = panic "lkT"  -- Dealt with by coreView

-----------------
xtT :: CmEnv -> Type -> XT a -> TypeMap a -> TypeMap a
xtT env ty f m
  | EmptyTM <- m            = xtT env ty  f wrapEmptyTypeMap 
  | Just ty' <- coreView ty = xtT env ty' f m                

xtT env (TyVarTy v)       f  m = m { tm_var    = tm_var m |> xtVar env v f }
xtT env (AppTy t1 t2)     f  m = m { tm_app    = tm_app m |> xtT env t1 |>> xtT env t2 f }
xtT env (FunTy t1 t2)     f  m = m { tm_fun    = tm_fun m |> xtT env t1 |>> xtT env t2 f }
xtT env (ForAllTy tv ty)  f  m = m { tm_forall = tm_forall m |> xtT (extendCME env tv) ty 
                                                 |>> xtBndr env tv f }
xtT env (TyConApp tc tys) f  m = m { tm_tc_app = tm_tc_app m |> xtNamed tc 
                                                 |>> xtList (xtT env) tys f }
xtT _   (PredTy {})       _  _ = panic "xtT"  -- Dealt with by coreView

fdT :: (a -> b -> b) -> TypeMap a -> b -> b
fdT _ EmptyTM = \z -> z
fdT k m = foldTM k (tm_var m)
        . foldTM (foldTM k) (tm_app m)
        . foldTM (foldTM k) (tm_fun m)
        . foldTM (foldTM k) (tm_tc_app m)
        . foldTM (foldTM k) (tm_forall m)
\end{code}


%************************************************************************
%*									*
                   Variables
%*									*
%************************************************************************

\begin{code}
type BoundVar = Int  -- Bound variables are deBruijn numbered
type BoundVarMap a = IntMap.IntMap a

data CmEnv = CME { cme_next :: BoundVar
                 , cme_env  :: VarEnv BoundVar } 

emptyCME :: CmEnv
emptyCME = CME { cme_next = 0, cme_env = emptyVarEnv }

extendCME :: CmEnv -> Var -> CmEnv
extendCME (CME { cme_next = bv, cme_env = env }) v
  = CME { cme_next = bv+1, cme_env = extendVarEnv env v bv }

extendCMEs :: CmEnv -> [Var] -> CmEnv
extendCMEs env vs = foldl extendCME env vs

lookupCME :: CmEnv -> Var -> Maybe BoundVar
lookupCME (CME { cme_env = env }) v = lookupVarEnv env v

--------- Variable binders -------------
type BndrMap = TypeMap 

lkBndr :: CmEnv -> Var -> BndrMap a -> Maybe a
lkBndr env v m = lkT env (varType v) m

xtBndr :: CmEnv -> Var -> XT a -> BndrMap a -> BndrMap a
xtBndr env v f = xtT env (varType v) f

--------- Variable occurrence -------------
data VarMap a = VM { vm_bvar   :: BoundVarMap a  -- Bound variable
                   , vm_fvar   :: VarEnv a }  	  -- Free variable

instance TrieMap VarMap where
   type Key VarMap = Var
   emptyTM = VM { vm_bvar = IntMap.empty, vm_fvar = emptyVarEnv }
   lookupTM = lkVar emptyCME
   alterTM = xtVar emptyCME
   foldTM = fdVar

lkVar :: CmEnv -> Var -> VarMap a -> Maybe a
lkVar env v 
  | Just bv <- lookupCME env v = vm_bvar >.> lookupTM bv
  | otherwise                  = vm_fvar >.> lkFreeVar v

xtVar :: CmEnv -> Var -> XT a -> VarMap a -> VarMap a
xtVar env v f m
  | Just bv <- lookupCME env v = m { vm_bvar = vm_bvar m |> xtInt bv f }
  | otherwise                  = m { vm_fvar = vm_fvar m |> xtFreeVar v f }

fdVar :: (a -> b -> b) -> VarMap a -> b -> b
fdVar k m = foldTM k (vm_bvar m)
          . foldTM k (vm_fvar m)

lkFreeVar :: Var -> VarEnv a -> Maybe a
lkFreeVar var env = lookupVarEnv env var

xtFreeVar :: Var -> XT a -> VarEnv a -> VarEnv a
xtFreeVar v f m = alterVarEnv f m v
\end{code}