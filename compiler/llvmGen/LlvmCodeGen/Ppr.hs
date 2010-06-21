-- ----------------------------------------------------------------------------
-- | Pretty print helpers for the LLVM Code generator.
--

module LlvmCodeGen.Ppr (
        pprLlvmHeader, pprLlvmCmmTop, pprLlvmData
    ) where

#include "HsVersions.h"

import Llvm
import LlvmCodeGen.Base
import LlvmCodeGen.Data

import CLabel
import Cmm

import FastString
import Pretty
import Unique
import Util

-- ----------------------------------------------------------------------------
-- * Top level
--

-- | LLVM module layout description for the host target
moduleLayout :: Doc
moduleLayout =
#if i386_TARGET_ARCH

#if darwin_TARGET_OS
    text "target datalayout = \"e-p:32:32:32-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:32:64-f32:32:32-f64:32:64-v64:64:64-v128:128:128-a0:0:64-f80:128:128-n8:16:32\""
    $+$ text "target triple = \"i386-apple-darwin9.8\""
#elif mingw32_TARGET_OS
    text "target datalayout = \"e-p:32:32:32-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-f80:128:128-v64:64:64-v128:128:128-a0:0:64-f80:32:32-n8:16:32\""
    $+$ text "target triple = \"i686-pc-win32\""
#else /* Linux */
    text "target datalayout = \"e-p:32:32:32-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:32:64-f32:32:32-f64:32:64-v64:64:64-v128:128:128-a0:0:64-f80:32:32-n8:16:32\""
    $+$ text "target triple = \"i386-pc-linux-gnu\""
#endif

#elif x86_64_TARGET_ARCH

#if darwin_TARGET_OS
    text "target datalayout = \"e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v64:64:64-v128:128:128-a0:0:64-s0:64:64-f80:128:128-n8:16:32:64\""
    $+$ text "target triple = \"x86_64-apple-darwin10.0.0\""
#else /* Linux */
    text "target datalayout = \"e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v64:64:64-v128:128:128-a0:0:64-s0:64:64-f80:128:128-n8:16:32:64\""
    $+$ text "target triple = \"x86_64-linux-gnu\""
#endif

#else /* Not x86 */
    -- FIX: Other targets
    empty
#endif


-- | Header code for LLVM modules
pprLlvmHeader :: Doc
pprLlvmHeader = moduleLayout


-- | Pretty print LLVM data code
pprLlvmData :: LlvmData -> Doc
pprLlvmData (globals, types) =
    let tryConst (v, Just s )   = ppLlvmGlobal (v, Just s)
        tryConst g@(_, Nothing) = ppLlvmGlobal g

        types'   = ppLlvmTypes types
        globals' = vcat $ map tryConst globals
    in types' $+$ globals'


-- | Pretty print LLVM code
pprLlvmCmmTop :: LlvmEnv -> Int -> LlvmCmmTop -> (Doc, [LlvmVar])
pprLlvmCmmTop _ _ (CmmData _ lmdata)
  = (vcat $ map pprLlvmData lmdata, [])

pprLlvmCmmTop env count (CmmProc info lbl _ (ListGraph blks))
  = let static = CmmDataLabel lbl : info
        (idoc, ivar) = if not (null info)
                          then pprCmmStatic env count static
                          else (empty, [])
    in (idoc $+$ (
        let sec = mkLayoutSection (count + 1)
            (lbl',sec') = if not (null info)
                            then (entryLblToInfoLbl lbl, sec)
                            else (lbl, Nothing)
            link = if externallyVisibleCLabel lbl'
                      then ExternallyVisible
                      else Internal
            funDec = llvmFunSig lbl' link
            lmblocks = map (\(BasicBlock id stmts) ->
                                LlvmBlock (getUnique id) stmts) blks
            fun = LlvmFunction funDec [NoUnwind] sec' lmblocks
        in ppLlvmFunction fun
    ), ivar)


-- | Pretty print CmmStatic
pprCmmStatic :: LlvmEnv -> Int -> [CmmStatic] -> (Doc, [LlvmVar])
pprCmmStatic env count stat
  = let unres = genLlvmData (Text, stat)
        (_, (ldata, ltypes)) = resolveLlvmData env unres

        setSection (gv@(LMGlobalVar s ty l _ _ c), d)
            = let v = if l == Internal then [gv] else []
                  sec = mkLayoutSection count
              in ((LMGlobalVar s ty l sec llvmInfAlign c, d), v)
        setSection v = (v,[])

        (ldata', llvmUsed) = mapAndUnzip setSection ldata
    in (pprLlvmData (ldata', ltypes), concat llvmUsed)


-- | Create an appropriate section declaration for subsection <n> of text
-- WARNING: This technique could fail as gas documentation says it only
-- supports up to 8192 subsections per section. Inspection of the source
-- code and some test programs seem to suggest it supports more than this
-- so we are hoping it does.
mkLayoutSection :: Int -> LMSection
mkLayoutSection n
  = Just (fsLit $ ".text;.text " ++ show n ++ " #")
