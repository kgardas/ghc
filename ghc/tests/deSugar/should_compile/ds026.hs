-- !!! ds026 -- classes -- incl. polymorphic method

module ShouldSucceed where

class Foo a where
  op :: a -> a

class Foo a => Boo a where
  op1 :: a -> a

class Boo a => Noo a where
  op2 :: (Eq b) => a -> b -> a

f x y = op (op2 x y)
