-- -----------------------------------------------------------------------------
-- | This is the top-level module in the LLVM code generator.
--

module LlvmCodeGen ( llvmCodeGen, llvmFixupAsm ) where

#include "HsVersions.h"

import Llvm
import LlvmCodeGen.Base
import LlvmCodeGen.CodeGen
import LlvmCodeGen.Data
import LlvmCodeGen.Ppr
import LlvmMangler

import CgUtils ( fixStgRegisters )
import OldCmm
import OldPprCmm

import BufWrite
import DynFlags
import ErrUtils
import FastString
import Outputable
import qualified Pretty as Prt
import UniqSupply
import Util
import SysTools ( figureLlvmVersion )

import Data.Maybe ( fromMaybe )
import System.IO

-- -----------------------------------------------------------------------------
-- | Top-level of the LLVM Code generator
--
llvmCodeGen :: DynFlags -> Handle -> UniqSupply -> [RawCmm] -> IO ()
llvmCodeGen dflags h us cmms
  = let cmm = concat $ map (\(Cmm top) -> top) cmms
        (cdata,env) = foldr split ([],initLlvmEnv) cmm
        split (CmmData s d' ) (d,e) = ((s,d'):d,e)
        split (CmmProc i l _) (d,e) =
            let lbl = strCLabel_llvm $ case i of
                        Nothing                   -> l
                        Just (Statics info_lbl _) -> info_lbl
                env' = funInsert lbl llvmFunTy e
            in (d,env')
    in do
        bufh <- newBufHandle h
        Prt.bufLeftRender bufh $ pprLlvmHeader
        ver  <- (fromMaybe defaultLlvmVersion) `fmap` figureLlvmVersion dflags
        env' <- cmmDataLlvmGens dflags bufh (setLlvmVer ver env) cdata []
        cmmProcLlvmGens dflags bufh us env' cmm 1 []
        bFlush bufh
        return  ()


-- -----------------------------------------------------------------------------
-- | Do LLVM code generation on all these Cmms data sections.
--
cmmDataLlvmGens :: DynFlags -> BufHandle -> LlvmEnv -> [(Section,CmmStatics)]
                -> [LlvmUnresData] -> IO ( LlvmEnv )

cmmDataLlvmGens dflags h env [] lmdata
  = let (env', lmdata') = resolveLlvmDatas env lmdata []
        lmdoc = Prt.vcat $ map pprLlvmData lmdata'
    in do
        dumpIfSet_dyn dflags Opt_D_dump_llvm "LLVM Code" $ docToSDoc lmdoc
        Prt.bufLeftRender h lmdoc
        return env'

cmmDataLlvmGens dflags h env (cmm:cmms) lmdata
  = let lmdata'@(l, _, ty, _) = genLlvmData cmm
        env' = funInsert (strCLabel_llvm l) ty env
    in cmmDataLlvmGens dflags h env' cmms (lmdata ++ [lmdata'])


-- -----------------------------------------------------------------------------
-- | Do LLVM code generation on all these Cmms procs.
--
cmmProcLlvmGens :: DynFlags -> BufHandle -> UniqSupply -> LlvmEnv -> [RawCmmTop]
      -> Int         -- ^ count, used for generating unique subsections
      -> [[LlvmVar]] -- ^ info tables that need to be marked as 'used'
      -> IO ()

cmmProcLlvmGens _ _ _ _ [] _ []
  = return ()

cmmProcLlvmGens _ h _ _ [] _ ivars
  = let ivars' = concat ivars
        cast x = LMBitc (LMStaticPointer (pVarLift x)) i8Ptr
        ty     = (LMArray (length ivars') i8Ptr)
        usedArray = LMStaticArray (map cast ivars') ty
        lmUsed = (LMGlobalVar (fsLit "llvm.used") ty Appending
                  (Just $ fsLit "llvm.metadata") Nothing False, Just usedArray)
    in Prt.bufLeftRender h $ pprLlvmData ([lmUsed], [])

cmmProcLlvmGens dflags h us env ((CmmData _ _) : cmms) count ivars
 = cmmProcLlvmGens dflags h us env cmms count ivars

cmmProcLlvmGens dflags h us env ((CmmProc _ _ (ListGraph [])) : cmms) count ivars
 = cmmProcLlvmGens dflags h us env cmms count ivars

cmmProcLlvmGens dflags h us env (cmm : cmms) count ivars = do
    (us', env', llvm) <- cmmLlvmGen dflags us (clearVars env) cmm
    let (docs, ivar) = mapAndUnzip (pprLlvmCmmTop env' count) llvm
    Prt.bufLeftRender h $ Prt.vcat docs
    cmmProcLlvmGens dflags h us' env' cmms (count + 2) (ivar ++ ivars)


-- | Complete LLVM code generation phase for a single top-level chunk of Cmm.
cmmLlvmGen :: DynFlags -> UniqSupply -> LlvmEnv -> RawCmmTop
            -> IO ( UniqSupply, LlvmEnv, [LlvmCmmTop] )
cmmLlvmGen dflags us env cmm = do
    -- rewrite assignments to global regs
    let fixed_cmm = fixStgRegisters cmm

    dumpIfSet_dyn dflags Opt_D_dump_opt_cmm "Optimised Cmm"
        (pprCmm (targetPlatform dflags) $ Cmm [fixed_cmm])

    -- generate llvm code from cmm
    let ((env', llvmBC), usGen) = initUs us $ genLlvmProc env fixed_cmm

    dumpIfSet_dyn dflags Opt_D_dump_llvm "LLVM Code"
        (vcat $ map (docToSDoc . fst . pprLlvmCmmTop env' 0) llvmBC)

    return (usGen, env', llvmBC)

