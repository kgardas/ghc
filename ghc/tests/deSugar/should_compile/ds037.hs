-- !!! AbsBinds with tyvars, no dictvars, but some dict binds
--
module ShouldSucceed where

f x y = (fst (g y x), x+(1::Int))
g x y = (fst (f x y), y+(1::Int))
