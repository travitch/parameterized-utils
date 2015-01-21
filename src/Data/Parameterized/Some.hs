------------------------------------------------------------------------
-- |
-- Module           : Data.Parameterized.Some
-- Description      : Provides a simple GADT for hiding a type parameter.
-- Copyright        : (c) Galois, Inc 2014
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
-- Stability        : provisional
--
-- This module provides Some, a GADT that hides a type parameter.
------------------------------------------------------------------------
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
module Data.Parameterized.Some
  ( Some(..)
  , viewSome
  , mapSome
  , traverseSome
  , traverseSome_
  ) where

import Data.Hashable
import Data.Parameterized.Classes


data Some (f:: k -> *) = forall x . Some (f x)

instance TestEquality f => Eq (Some f) where
  Some x == Some y = isJust (testEquality x y)

instance OrdF f => Ord (Some f) where
  compare (Some x) (Some y) = toOrdering (compareF x y)

instance HashableF f => Hashable (Some f) where
  hashWithSalt s (Some x) = hashWithSaltF s x
  hash (Some x) = hashF x

instance ShowF f => Show (Some f) where
  show (Some x) = showF x

-- | Project out of Some.
viewSome :: (forall tp . f tp -> r) -> Some f -> r
viewSome f (Some x) = f x

-- | Apply function to inner value.
mapSome :: (forall tp . f tp -> g tp) -> Some f -> Some g
mapSome f (Some x) = Some $! f x

{-# INLINE traverseSome #-}
-- | Modify the inner value.
traverseSome :: Functor m
             => (forall tp . f tp -> m (g tp))
             -> Some f
             -> m (Some g)
traverseSome f (Some x) = Some `fmap` f x

{-# INLINE traverseSome_ #-}
-- | Modify the inner value.
traverseSome_ :: Functor m => (forall tp . f tp -> m ()) -> Some f -> m ()
traverseSome_ f (Some x) = (\_ -> ()) `fmap` f x