{-|
Copyright        : (c) Galois, Inc 2014-2015
Maintainer       : Joe Hendrix <jhendrix@galois.com>

This defines a type family 'SymbolRepr' for representing a type-level string
(AKA symbol) at runtime.  This can be used to branch on a type-level value.

The 'TestEquality' and 'OrdF' instances for 'SymbolRepr' are implemented using
'unsafeCoerce'.  This should be typesafe because we maintain the invariant
that the string value contained in a SymolRepr value matches its static type.

At the type level, symbols have very few operations, so SymbolRepr
correspondingly has very few functions that manipulate them.
-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExplicitNamespaces #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE Trustworthy #-}
module Data.Parameterized.SymbolRepr
  ( -- * SymbolRepr
    SymbolRepr
  , symbolRepr
  , knownSymbol
    -- * Re-exports
  , type GHC.Symbol
  , GHC.KnownSymbol
  ) where

import GHC.TypeLits as GHC
import Unsafe.Coerce (unsafeCoerce)

import Data.Hashable
import Data.Proxy
import qualified Data.Text as Text

import Data.Parameterized.Classes

-- | A runtime representation of a GHC type-level symbol.
newtype SymbolRepr (nm::GHC.Symbol)
  = SymbolRepr { symbolRepr :: Text.Text
                 -- ^ The underlying text representation of the symbol
               }
-- INVARIANT: The contained runtime text value matches the value
-- of the type level symbol.  The SymbolRepr constructor
-- is not exported so we can maintain this invariant in this
-- module.

-- | Generate a value representative for the type level
--   symbol.  This is the only way to generate values
--   of `SymbolRepr`.
knownSymbol :: GHC.KnownSymbol s => SymbolRepr s
knownSymbol = go Proxy
  where go :: GHC.KnownSymbol s => Proxy s -> SymbolRepr s
        go p = SymbolRepr $! packSymbol (GHC.symbolVal p)

        -- NOTE here we explicitly test that unpacking the packed text value
        -- gives the desired string.  This is to avoid pathological corner cases
        -- involving string values that have no text representation.
        packSymbol str
           | Text.unpack txt == str = txt
           | otherwise = error $ "Unrepresentable symbol! "++ str
         where txt = Text.pack str

instance TestEquality SymbolRepr where
   testEquality (SymbolRepr x :: SymbolRepr x) (SymbolRepr y)
      | x == y    = Just (unsafeCoerce (Refl :: x :~: x))
      | otherwise = Nothing
instance OrdF SymbolRepr where
   compareF (SymbolRepr x :: SymbolRepr x) (SymbolRepr y)
      | x <  y    = LTF
      | x == y    = unsafeCoerce (EQF :: OrderingF x x)
      | otherwise = GTF

-- These instances are trivial by the invariant
-- that the contained string matches the type-level
-- symbol
instance Eq (SymbolRepr x) where
   _ == _ = True
instance Ord (SymbolRepr x) where
   compare _ _ = EQ

instance HashableF SymbolRepr where
  hashWithSaltF = hashWithSalt
instance Hashable (SymbolRepr nm) where
  hashWithSalt s (SymbolRepr nm) = hashWithSalt s nm

instance ShowF SymbolRepr where
  showF = show
instance Show (SymbolRepr nm) where
  show (SymbolRepr nm) = Text.unpack nm
