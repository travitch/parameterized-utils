------------------------------------------------------------------------
-- |
-- Module           : Data.Parameterized.SafeContext
-- Copyright        : (c) Galois, Inc 2014-2015
-- Maintainer       : Joe Hendrix <jhendrix@galois.com>
--
-- This module defines type contexts as a data-kind that consists of
-- a list of types.  Indexes are defined with respect to these contexts.
-- In addition, finite dependent products (Assignements) are defined over
-- type contexts.  The elements of an assignment can be accessed using
-- appropriately-typed indices.
--
-- This implementation is entirely typesafe, and provides a proof that
-- the signature implemented by this module is consistent.  Contexts,
-- indexes, and assignements are represented naively by linear sequences.
--
-- Compared to the implementation in UnsafeTypeContext, this one suffers
-- from the fact that the operation of extending an the context of an index
-- is _not_ a no-op.  We therefore cannot use Data.Coerce.coerce to understand
-- indexes in a new context without actually breaking things.
--------------------------------------------------------------------------
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE IncoherentInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
module Data.Parameterized.SafeContext
  ( module Data.Parameterized.Ctx
  , Size
  , sizeInt
  , zeroSize
  , incSize
  , extSize
  , KnownContext(..)
    -- * Diff
  , Diff
  , noDiff
  , extendRight
  , KnownDiff(..)
    -- * Indexing
  , Index
  , indexVal
  , base
  , skip

  , nextIndex
  , extendIndex
  , extendIndex'
  , forIndex
  , intIndex
    -- * Assignments
  , Assignment
  , size
  , replicate
  , generate
  , generateM
  , empty
  , null
  , extend
  , update
  , adjust
  , init
  , AssignView(..)
  , view
  , (!)
  , (!!)
  , toList
  , zipWith
  , zipWithM
  , (%>)
  , traverseWithIndex
  ) where

import qualified Control.Category as Cat
import Control.DeepSeq
import qualified Control.Lens as Lens
import Control.Monad.Identity (Identity(..))
import Data.Hashable
import Data.List (intercalate)
import Data.Maybe (listToMaybe)
import Data.Type.Equality
import Prelude hiding (init, map, null, replicate, succ, zipWith, (!!))

#if !MIN_VERSION_base(4,8,0)
import Data.Functor
import Control.Applicative (Applicative(..))
#endif

import Data.Parameterized.Classes
import Data.Parameterized.Ctx
import Data.Parameterized.Some
import Data.Parameterized.TraversableFC

------------------------------------------------------------------------
-- Size

-- | Represents the size of a context.
data Size (ctx :: Ctx k) where
  SizeZero :: Size 'EmptyCtx
  SizeSucc :: Size ctx -> Size (ctx '::> tp)

sizeInt :: Size ctx -> Int
sizeInt SizeZero = 0
sizeInt (SizeSucc sz) = (+1) $! sizeInt sz

-- | The size of an empty context.
zeroSize :: Size 'EmptyCtx
zeroSize = SizeZero

-- | Increment the size to the next value.
incSize :: Size ctx -> Size (ctx '::> tp)
incSize sz = SizeSucc sz

------------------------------------------------------------------------
-- Size

-- | A context that can be determined statically at compiler time.
class KnownContext (ctx :: Ctx k) where
  knownSize :: Size ctx

instance KnownContext 'EmptyCtx where
  knownSize = zeroSize

instance KnownContext ctx => KnownContext (ctx '::> tp) where
  knownSize = incSize knownSize

------------------------------------------------------------------------
-- Diff

-- | Difference in number of elements between two contexts.
-- The first context must be a sub-context of the other.
data Diff (l :: Ctx k) (r :: Ctx k) where
  DiffHere :: Diff ctx ctx
  DiffThere :: Diff ctx1 ctx2 -> Diff ctx1 (ctx2 '::> tp)

-- | The identity difference.
noDiff :: Diff l l
noDiff = DiffHere

-- | Extend the difference to a sub-context of the right side.
extendRight :: Diff l r -> Diff l (r '::> tp)
extendRight diff = DiffThere diff

composeDiff :: Diff a b -> Diff b c -> Diff a c
composeDiff x DiffHere = x
composeDiff x (DiffThere y) = DiffThere (composeDiff x y)

instance Cat.Category Diff where
  id = DiffHere
  d1 . d2 = composeDiff d2 d1

-- | Extend the size by a given difference.
extSize :: Size l -> Diff l r -> Size r
extSize sz DiffHere = sz
extSize sz (DiffThere diff) = incSize (extSize sz diff)

------------------------------------------------------------------------
-- KnownDiff

-- | A difference that can be automatically inferred at compile time.
class KnownDiff (l :: Ctx k) (r :: Ctx k) where
  knownDiff :: Diff l r

instance KnownDiff l l where
  knownDiff = noDiff

instance KnownDiff l r => KnownDiff l (r '::> tp) where
  knownDiff = extendRight knownDiff

------------------------------------------------------------------------
-- Index

-- | An index is a reference to a position with a particular type in a
-- context.
data Index (ctx :: Ctx k) (tp :: k) where
  IndexHere :: Size ctx -> Index (ctx '::> tp) tp
  IndexThere :: Index ctx tp -> Index (ctx '::> tp') tp

indexVal :: Index ctx tp -> Int
indexVal (IndexHere sz) = sizeInt sz
indexVal (IndexThere idx) = indexVal idx

instance Eq (Index ctx tp) where
  idx1 == idx2 = isJust (testEquality idx1 idx2)

instance TestEquality (Index ctx) where
  testEquality (IndexHere _) (IndexHere _) = Just Refl
  testEquality (IndexHere _) (IndexThere _) = Nothing
  testEquality (IndexThere _) (IndexHere _) = Nothing
  testEquality (IndexThere idx1) (IndexThere idx2) =
     case testEquality idx1 idx2 of
         Just Refl -> Just Refl
         Nothing -> Nothing

instance Ord (Index ctx tp) where
  compare i j = toOrdering (compareF i j)

instance OrdF (Index ctx) where
  compareF (IndexHere _) (IndexHere _) = EQF
  compareF (IndexThere _) (IndexHere _) = LTF
  compareF (IndexHere _) (IndexThere _) = GTF
  compareF (IndexThere idx1) (IndexThere idx2) =
     case compareF idx1 idx2 of
        EQF -> EQF
        LTF -> LTF
        GTF -> GTF

-- | Index for first element in context.
base :: Index ('EmptyCtx '::> tp) tp
base = IndexHere SizeZero

-- | Increase context while staying at same index.
skip :: Index ctx x -> Index (ctx '::> y) x
skip idx = IndexThere idx

_indexSize :: Index ctx tp -> Size ctx
_indexSize (IndexHere sz) = SizeSucc sz
_indexSize (IndexThere idx) = SizeSucc (_indexSize idx)

-- | Return the index of a element one past the size.
nextIndex :: Size ctx -> Index (ctx '::> tp) tp
nextIndex sz = IndexHere sz

{-# INLINE extendIndex #-}
extendIndex :: KnownDiff l r => Index l tp -> Index r tp
extendIndex = extendIndex' knownDiff

{-# INLINE extendIndex' #-}
extendIndex' :: Diff l r -> Index l tp -> Index r tp
extendIndex' DiffHere idx = idx
extendIndex' (DiffThere diff) idx = IndexThere (extendIndex' diff idx)

-- | Given a size @n@, an initial value @v0@, and a function @f@, @forIndex n v0 f@,
-- calls @f@ on each index less than @n@ starting from @0@ and @v0@, with the value @v@ obtained
-- from the last call.
forIndex :: forall ctx r
          . Size ctx
         -> (forall tp . r -> Index ctx tp -> r)
         -> r
         -> r
forIndex sz_top f = go id sz_top
 where go :: forall ctx'. (forall tp. Index ctx' tp -> Index ctx tp) -> Size ctx' -> r -> r
       go _ SizeZero = id
       go g (SizeSucc sz) = \r -> go (\i -> g (IndexThere i)) sz  $ f r (g (IndexHere sz))


indexList :: forall ctx. Size ctx -> [Some (Index ctx)]
indexList sz_top = go id [] sz_top
 where go :: (forall tp. Index ctx' tp -> Index ctx tp)
          -> [Some (Index ctx)]
          -> Size ctx'
          -> [Some (Index ctx)]
       go _ ls SizeZero       = ls
       go g ls (SizeSucc sz)  = go (\i -> g (IndexThere i)) (Some (g (IndexHere sz)) : ls) sz

-- | Return index at given integer or nothing if integer is out of bounds.
intIndex :: Int -> Size ctx -> Maybe (Some (Index ctx))
intIndex n sz = listToMaybe $ drop n $ indexList sz

instance Show (Index ctx tp) where
   show = show . indexVal

instance ShowF (Index ctx) where
   showF = show

------------------------------------------------------------------------
-- Assignment

type Assignment = AssignView

data AssignView f ctx where
  AssignEmpty :: AssignView f EmptyCtx
  AssignExtend :: Assignment f ctx
               -> f tp
               -> AssignView f (ctx::>tp)

view :: forall f ctx . Assignment f ctx -> AssignView f ctx
view asgn = asgn

instance NFData (Assignment f ctx) where
  rnf AssignEmpty = ()
  rnf (AssignExtend asgn x) = rnf asgn `seq` x `seq` ()

size :: Assignment f ctx -> Size ctx
size AssignEmpty = SizeZero
size (AssignExtend asgn _) = SizeSucc (size asgn)

-- | Generate an assignment
generate :: forall ctx f
          . Size ctx
         -> (forall tp . Index ctx tp -> f tp)
         -> Assignment f ctx
generate sz_top f = go id sz_top
 where go :: forall ctx'
           . (forall tp. Index ctx' tp -> Index ctx tp)
          -> Size ctx'
          -> Assignment f ctx'
       go _ SizeZero = AssignEmpty
       go g (SizeSucc sz) =
            let ctx = go (\i -> g (IndexThere i)) sz
                x = f (g (IndexHere sz))
             in AssignExtend ctx x

-- | Generate an assignment
generateM :: forall ctx m f
           . Applicative m
          => Size ctx
          -> (forall tp . Index ctx tp -> m (f tp))
          -> m (Assignment f ctx)
generateM sz_top f = go id sz_top
 where go :: forall ctx'. (forall tp. Index ctx' tp -> Index ctx tp) -> Size ctx' -> m (Assignment f ctx')
       go _ SizeZero = pure AssignEmpty
       go g (SizeSucc sz) =
             AssignExtend <$> (go (\i -> g (IndexThere i)) sz) <*> f (g (IndexHere sz))

-- | @replicate n@ make a context with different copies of the same
-- polymorphic value.
replicate :: Size ctx -> (forall tp . f tp) -> Assignment f ctx
replicate n c = generate n (\_ -> c)

-- | Create empty indexec vector.
empty :: Assignment f 'EmptyCtx
empty = AssignEmpty

-- | Return true if assignment is empty.
null :: Assignment f ctx -> Bool
null AssignEmpty = True
null _ = False

extend :: Assignment f ctx -> f tp -> Assignment f (ctx '::> tp)
extend asgn e = AssignExtend asgn e

update :: Index ctx tp -> f tp -> Assignment f ctx -> Assignment f ctx
update idx e asgn = adjust (\_ -> e) idx asgn

adjust :: forall f ctx tp. (f tp -> f tp) -> Index ctx tp -> Assignment f ctx -> Assignment f ctx
adjust f = go (\x -> x)
 where
  go :: (forall tp'. g tp' -> f tp') -> Index ctx' tp -> Assignment g ctx' -> Assignment f ctx'
  go g (IndexHere _)    (AssignExtend asgn x) = AssignExtend (map g asgn) (f (g x))
  go g (IndexThere idx) (AssignExtend asgn x) = AssignExtend (go g idx asgn) (g x)
--  go _ (IndexHere _) AssignEmpty = undefined
--  go _ (IndexThere _) AssignEmpty = undefined
  go _ _ _ = error "SafeTypeContext.adjust: impossible!"


-- | Return assignment with all but the last block.
init :: Assignment f (ctx '::> tp) -> Assignment f ctx
init (AssignExtend asgn _) = asgn

idxlookup :: (forall tp. a tp -> b tp) -> Assignment a ctx -> forall tp. Index ctx tp -> b tp
idxlookup f (AssignExtend _   x) (IndexHere _) = f x
idxlookup f (AssignExtend ctx _) (IndexThere idx) = idxlookup f ctx idx
idxlookup _ AssignEmpty _ = error "Data.Parameterized.SafeContext.lookup: impossible case"

-- | Return value of assignment.
(!) :: Assignment f ctx -> Index ctx tp -> f tp
(!) asgn idx = idxlookup id asgn idx

-- | Return value of assignment.
(!!) :: KnownDiff l r => Assignment f r -> Index l tp -> f tp
a !! i = a ! extendIndex i

instance TestEquality f => Eq (Assignment f ctx) where
  x == y = isJust (testEquality x y)

testEq :: TestEquality f => Assignment f cxt1 -> Assignment f cxt2 -> Maybe (cxt1 :~: cxt2)
testEq AssignEmpty AssignEmpty = Just Refl
testEq (AssignExtend ctx1 x1) (AssignExtend ctx2 x2) =
     case testEq ctx1 ctx2 of
       Nothing -> Nothing
       Just Refl ->
          case testEquality x1 x2 of
             Nothing -> Nothing
             Just Refl -> Just Refl
testEq AssignEmpty (AssignExtend _ctx2 _x2) = Nothing
testEq (AssignExtend _ctx1 _x1) AssignEmpty = Nothing


instance TestEquality f => TestEquality (Assignment f) where
   testEquality x y = testEq x y

instance TestEquality f => PolyEq (Assignment f x) (Assignment f y) where
  polyEqF x y = fmap (\Refl -> Refl) $ testEquality x y

compareAsgn :: OrdF f => Assignment f ctx1 -> Assignment f ctx2 -> OrderingF ctx1 ctx2
compareAsgn AssignEmpty AssignEmpty = EQF
compareAsgn AssignEmpty _ = GTF
compareAsgn _ AssignEmpty = LTF
compareAsgn (AssignExtend ctx1 x) (AssignExtend ctx2 y) =
  case compareAsgn ctx1 ctx2 of
    LTF -> LTF
    GTF -> GTF
    EQF -> case compareF x y of
              LTF -> LTF
              GTF -> GTF
              EQF -> EQF

instance OrdF f => OrdF (Assignment f) where
  compareF = compareAsgn

instance OrdF f => Ord (Assignment f ctx) where
  compare x y = toOrdering (compareF x y)



instance Hashable (Index ctx tp) where
  hashWithSalt = hashWithSaltF
instance HashableF (Index ctx) where
  hashWithSaltF s i = hashWithSalt s (indexVal i)

instance HashableF f => HashableF (Assignment f) where
  hashWithSaltF = hashWithSalt

instance HashableF f => Hashable (Assignment f ctx) where
  hashWithSalt s AssignEmpty = s
  hashWithSalt s (AssignExtend asgn x) = (s `hashWithSalt` asgn) `hashWithSaltF` x

instance ShowF f => ShowF (Assignment f) where
  showF a = "[" ++ intercalate ", " (toList showF a) ++ "]"

instance ShowF f => Show (Assignment f ctx) where
  show a = showF a

instance FunctorFC Assignment where
  fmapFC = fmapFCDefault

instance FoldableFC Assignment where
  foldMapFC = foldMapFCDefault

instance TraversableFC Assignment where
  traverseFC = traverseF

-- | Map assignment
map :: (forall tp . f tp -> g tp) -> Assignment f c -> Assignment g c
map = fmapFC

traverseF :: forall (f:: k -> *) (g::k -> *) (m:: * -> *) (c::Ctx k)
           . Applicative m
          => (forall tp . f tp -> m (g tp))
          -> Assignment f c
          -> m (Assignment g c)
traverseF _ AssignEmpty = pure AssignEmpty
traverseF f (AssignExtend asgn x) = pure AssignExtend <*> traverseF f asgn <*> f x

-- | Convert assignment to list.
toList :: (forall tp . f tp -> a)
       -> Assignment f c
       -> [a]
toList = toListFC

zipWithM :: Applicative m
         => (forall tp . f tp -> g tp -> m (h tp))
         -> Assignment f c
         -> Assignment g c
         -> m (Assignment h c)
zipWithM f x y = go x y
 where go AssignEmpty AssignEmpty = pure AssignEmpty
       go (AssignExtend asgn1 x1) (AssignExtend asgn2 x2) =
             AssignExtend <$> (zipWithM f asgn1 asgn2) <*> (f x1 x2)

zipWith :: (forall x . f x -> g x -> h x)
        -> Assignment f a
        -> Assignment g a
        -> Assignment h a
zipWith f = \x y -> runIdentity $ zipWithM (\u v -> pure (f u v)) x y
{-# INLINE zipWith #-}

(%>) :: Assignment f x -> f tp -> Assignment f (x '::> tp)
a %> v = extend a v

traverseWithIndex :: Applicative m
                  => (forall tp . Index ctx tp -> f tp -> m (g tp))
                  -> Assignment f ctx
                  -> m (Assignment g ctx)
traverseWithIndex f a = generateM (size a) $ \i -> f i (a ! i)


--------------------------------------------------------------------------------------
-- lookups and update for lenses

data MyNat where
  MyZ :: MyNat
  MyS :: MyNat -> MyNat

type MyZ = 'MyZ
type MyS = 'MyS

data MyNatRepr :: MyNat -> * where
  MyZR :: MyNatRepr MyZ
  MySR :: MyNatRepr n -> MyNatRepr (MyS n)

type family StrongCtxUpdate (n::MyNat) (ctx::Ctx k) (z::k) :: Ctx k where
  StrongCtxUpdate n       EmptyCtx     z = EmptyCtx
  StrongCtxUpdate MyZ     (ctx::>x)    z = ctx ::> z
  StrongCtxUpdate (MyS n) (ctx::>x)    z = (StrongCtxUpdate n ctx z) ::> x

type family MyNatLookup (n::MyNat) (ctx::Ctx k) (f::k -> *) :: * where
  MyNatLookup n       EmptyCtx  f = ()
  MyNatLookup MyZ     (ctx::>x) f = f x
  MyNatLookup (MyS n) (ctx::>x) f = MyNatLookup n ctx f

mynat_lookup :: MyNatRepr n -> Assignment f ctx -> MyNatLookup n ctx f
mynat_lookup _   AssignEmpty = ()
mynat_lookup MyZR     (AssignExtend _    x) = x
mynat_lookup (MySR n) (AssignExtend asgn _) = mynat_lookup n asgn

strong_ctx_update :: MyNatRepr n -> Assignment f ctx -> f tp -> Assignment f (StrongCtxUpdate n ctx tp)
strong_ctx_update _        AssignEmpty           _ = AssignEmpty
strong_ctx_update MyZR     (AssignExtend asgn _) z = AssignExtend asgn z
strong_ctx_update (MySR n) (AssignExtend asgn x) z = AssignExtend (strong_ctx_update n asgn z) x

------------------------------------------------------------------------
-- 1 field lens combinators

type Assignment1 f x1 = Assignment f ('EmptyCtx '::> x1)

instance Lens.Field1 (Assignment1 f t) (Assignment1 f u) (f t) (f u) where

  _1 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MyZR

------------------------------------------------------------------------
-- 2 field lens combinators

type Assignment2 f x1 x2
   = Assignment f ('EmptyCtx '::> x1 '::> x2)

instance Lens.Field1 (Assignment2 f t x2) (Assignment2 f u x2) (f t) (f u) where
  _1 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MyZR

instance Lens.Field2 (Assignment2 f x1 t) (Assignment2 f x1 u) (f t) (f u) where
  _2 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MyZR


------------------------------------------------------------------------
-- 3 field lens combinators

type Assignment3 f x1 x2 x3
   = Assignment f ('EmptyCtx '::> x1 '::> x2 '::> x3)

instance Lens.Field1 (Assignment3 f t x2 x3)
                     (Assignment3 f u x2 x3)
                     (f t)
                     (f u) where
  _1 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MyZR

instance Lens.Field2 (Assignment3 f x1 t x3)
                     (Assignment3 f x1 u x3)
                     (f t)
                     (f u) where
  _2 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MyZR

instance Lens.Field3 (Assignment3 f x1 x2 t)
                     (Assignment3 f x1 x2 u)
                     (f t)
                     (f u) where
  _3 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MyZR

------------------------------------------------------------------------
-- 4 field lens combinators

type Assignment4 f x1 x2 x3 x4
   = Assignment f ('EmptyCtx '::> x1 '::> x2 '::> x3 '::> x4)

instance Lens.Field1 (Assignment4 f t x2 x3 x4)
                     (Assignment4 f u x2 x3 x4)
                     (f t)
                     (f u) where
  _1 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MyZR

instance Lens.Field2 (Assignment4 f x1 t x3 x4)
                     (Assignment4 f x1 u x3 x4)
                     (f t)
                     (f u) where
  _2 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MyZR

instance Lens.Field3 (Assignment4 f x1 x2 t x4)
                     (Assignment4 f x1 x2 u x4)
                     (f t)
                     (f u) where
  _3 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MyZR

instance Lens.Field4 (Assignment4 f x1 x2 x3 t)
                     (Assignment4 f x1 x2 x3 u)
                     (f t)
                     (f u) where
  _4 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MyZR


------------------------------------------------------------------------
-- 5 field lens combinators

type Assignment5 f x1 x2 x3 x4 x5
   = Assignment f ('EmptyCtx '::> x1 '::> x2 '::> x3 '::> x4 '::> x5)

instance Lens.Field1 (Assignment5 f t x2 x3 x4 x5)
                     (Assignment5 f u x2 x3 x4 x5)
                     (f t)
                     (f u) where
  _1 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MyZR

instance Lens.Field2 (Assignment5 f x1 t x3 x4 x5)
                     (Assignment5 f x1 u x3 x4 x5)
                     (f t)
                     (f u) where
  _2 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MyZR

instance Lens.Field3 (Assignment5 f x1 x2 t x4 x5)
                     (Assignment5 f x1 x2 u x4 x5)
                     (f t)
                     (f u) where
  _3 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MyZR

instance Lens.Field4 (Assignment5 f x1 x2 x3 t x5)
                     (Assignment5 f x1 x2 x3 u x5)
                     (f t)
                     (f u) where
  _4 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MyZR

instance Lens.Field5 (Assignment5 f x1 x2 x3 x4 t)
                     (Assignment5 f x1 x2 x3 x4 u)
                     (f t)
                     (f u) where
  _5 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MyZR

------------------------------------------------------------------------
-- 6 field lens combinators

type Assignment6 f x1 x2 x3 x4 x5 x6
   = Assignment f ('EmptyCtx '::> x1 '::> x2 '::> x3 '::> x4 '::> x5 '::> x6)

instance Lens.Field1 (Assignment6 f t x2 x3 x4 x5 x6)
                     (Assignment6 f u x2 x3 x4 x5 x6)
                     (f t)
                     (f u) where
  _1 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MySR $ MyZR

instance Lens.Field2 (Assignment6 f x1 t x3 x4 x5 x6)
                     (Assignment6 f x1 u x3 x4 x5 x6)
                     (f t)
                     (f u) where
  _2 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MyZR

instance Lens.Field3 (Assignment6 f x1 x2 t x4 x5 x6)
                     (Assignment6 f x1 x2 u x4 x5 x6)
                     (f t)
                     (f u) where
  _3 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MyZR

instance Lens.Field4 (Assignment6 f x1 x2 x3 t x5 x6)
                     (Assignment6 f x1 x2 x3 u x5 x6)
                     (f t)
                     (f u) where
  _4 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MyZR

instance Lens.Field5 (Assignment6 f x1 x2 x3 x4 t x6)
                     (Assignment6 f x1 x2 x3 x4 u x6)
                     (f t)
                     (f u) where
  _5 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MyZR

instance Lens.Field6 (Assignment6 f x1 x2 x3 x4 x5 t)
                     (Assignment6 f x1 x2 x3 x4 x5 u)
                     (f t)
                     (f u) where
  _6 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MyZR

------------------------------------------------------------------------
-- 7 field lens combinators

type Assignment7 f x1 x2 x3 x4 x5 x6 x7
   = Assignment f ('EmptyCtx '::> x1 '::> x2 '::> x3 '::> x4 '::> x5 '::> x6 '::> x7)

instance Lens.Field1 (Assignment7 f t x2 x3 x4 x5 x6 x7)
                     (Assignment7 f u x2 x3 x4 x5 x6 x7)
                     (f t)
                     (f u) where
  _1 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MySR $ MySR $ MyZR

instance Lens.Field2 (Assignment7 f x1 t x3 x4 x5 x6 x7)
                     (Assignment7 f x1 u x3 x4 x5 x6 x7)
                     (f t)
                     (f u) where
  _2 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MySR $ MyZR

instance Lens.Field3 (Assignment7 f x1 x2 t x4 x5 x6 x7)
                     (Assignment7 f x1 x2 u x4 x5 x6 x7)
                     (f t)
                     (f u) where
  _3 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MyZR

instance Lens.Field4 (Assignment7 f x1 x2 x3 t x5 x6 x7)
                     (Assignment7 f x1 x2 x3 u x5 x6 x7)
                     (f t)
                     (f u) where
  _4 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MyZR

instance Lens.Field5 (Assignment7 f x1 x2 x3 x4 t x6 x7)
                     (Assignment7 f x1 x2 x3 x4 u x6 x7)
                     (f t)
                     (f u) where
  _5 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MyZR

instance Lens.Field6 (Assignment7 f x1 x2 x3 x4 x5 t x7)
                     (Assignment7 f x1 x2 x3 x4 x5 u x7)
                     (f t)
                     (f u) where
  _6 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MyZR

instance Lens.Field7 (Assignment7 f x1 x2 x3 x4 x5 x6 t)
                     (Assignment7 f x1 x2 x3 x4 x5 x6 u)
                     (f t)
                     (f u) where
  _7 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MyZR

------------------------------------------------------------------------
-- 8 field lens combinators

type Assignment8 f x1 x2 x3 x4 x5 x6 x7 x8
   = Assignment f ('EmptyCtx '::> x1 '::> x2 '::> x3 '::> x4 '::> x5 '::> x6 '::> x7 '::> x8)

instance Lens.Field1 (Assignment8 f t x2 x3 x4 x5 x6 x7 x8)
                     (Assignment8 f u x2 x3 x4 x5 x6 x7 x8)
                     (f t)
                     (f u) where
  _1 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MySR $ MySR $ MySR $ MyZR


instance Lens.Field2 (Assignment8 f x1 t x3 x4 x5 x6 x7 x8)
                     (Assignment8 f x1 u x3 x4 x5 x6 x7 x8)
                     (f t)
                     (f u) where
  _2 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MySR $ MySR $ MyZR

instance Lens.Field3 (Assignment8 f x1 x2 t x4 x5 x6 x7 x8)
                     (Assignment8 f x1 x2 u x4 x5 x6 x7 x8)
                     (f t)
                     (f u) where
  _3 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MySR $ MyZR

instance Lens.Field4 (Assignment8 f x1 x2 x3 t x5 x6 x7 x8)
                     (Assignment8 f x1 x2 x3 u x5 x6 x7 x8)
                     (f t)
                     (f u) where
  _4 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MyZR

instance Lens.Field5 (Assignment8 f x1 x2 x3 x4 t x6 x7 x8)
                     (Assignment8 f x1 x2 x3 x4 u x6 x7 x8)
                     (f t)
                     (f u) where
  _5 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MyZR

instance Lens.Field6 (Assignment8 f x1 x2 x3 x4 x5 t x7 x8)
                     (Assignment8 f x1 x2 x3 x4 x5 u x7 x8)
                     (f t)
                     (f u) where
  _6 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MyZR

instance Lens.Field7 (Assignment8 f x1 x2 x3 x4 x5 x6 t x8)
                     (Assignment8 f x1 x2 x3 x4 x5 x6 u x8)
                     (f t)
                     (f u) where
  _7 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MyZR

instance Lens.Field8 (Assignment8 f x1 x2 x3 x4 x5 x6 x7 t)
                     (Assignment8 f x1 x2 x3 x4 x5 x6 x7 u)
                     (f t)
                     (f u) where
  _8 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MyZR

------------------------------------------------------------------------
-- 9 field lens combinators

type Assignment9 f x1 x2 x3 x4 x5 x6 x7 x8 x9
   = Assignment f ('EmptyCtx '::> x1 '::> x2 '::> x3 '::> x4 '::> x5 '::> x6 '::> x7 '::> x8 '::> x9)


instance Lens.Field1 (Assignment9 f t x2 x3 x4 x5 x6 x7 x8 x9)
                     (Assignment9 f u x2 x3 x4 x5 x6 x7 x8 x9)
                     (f t)
                     (f u) where
  _1 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MySR $ MySR $ MySR $ MySR $ MyZR

instance Lens.Field2 (Assignment9 f x1 t x3 x4 x5 x6 x7 x8 x9)
                     (Assignment9 f x1 u x3 x4 x5 x6 x7 x8 x9)
                     (f t)
                     (f u) where
  _2 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MySR $ MySR $ MySR $ MyZR

instance Lens.Field3 (Assignment9 f x1 x2 t x4 x5 x6 x7 x8 x9)
                     (Assignment9 f x1 x2 u x4 x5 x6 x7 x8 x9)
                     (f t)
                     (f u) where
  _3 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MySR $ MySR $ MyZR

instance Lens.Field4 (Assignment9 f x1 x2 x3 t x5 x6 x7 x8 x9)
                     (Assignment9 f x1 x2 x3 u x5 x6 x7 x8 x9)
                     (f t)
                     (f u) where
  _4 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MySR $ MyZR

instance Lens.Field5 (Assignment9 f x1 x2 x3 x4 t x6 x7 x8 x9)
                     (Assignment9 f x1 x2 x3 x4 u x6 x7 x8 x9)
                     (f t)
                     (f u) where
  _5 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MySR $ MyZR

instance Lens.Field6 (Assignment9 f x1 x2 x3 x4 x5 t x7 x8 x9)
                     (Assignment9 f x1 x2 x3 x4 x5 u x7 x8 x9)
                     (f t)
                     (f u) where
  _6 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MySR $ MyZR

instance Lens.Field7 (Assignment9 f x1 x2 x3 x4 x5 x6 t x8 x9)
                     (Assignment9 f x1 x2 x3 x4 x5 x6 u x8 x9)
                     (f t)
                     (f u) where
  _7 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MySR $ MyZR

instance Lens.Field8 (Assignment9 f x1 x2 x3 x4 x5 x6 x7 t x9)
                     (Assignment9 f x1 x2 x3 x4 x5 x6 x7 u x9)
                     (f t)
                     (f u) where
  _8 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MySR $ MyZR

instance Lens.Field9 (Assignment9 f x1 x2 x3 x4 x5 x6 x7 x8 t)
                     (Assignment9 f x1 x2 x3 x4 x5 x6 x7 x8 u)
                     (f t)
                     (f u) where
  _9 = Lens.lens (mynat_lookup n) (strong_ctx_update n)
        where n = MyZR
