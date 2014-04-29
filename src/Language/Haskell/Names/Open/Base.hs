-- | This module provides a more flexible way to process Haskell code —
-- using an open-recursive traversal.
--
-- You can look at "Language.Haskell.Exts.Annotated" source as an example
-- of how to use this module.
{-# LANGUAGE RankNTypes, FlexibleInstances, FlexibleContexts, UndecidableInstances, DefaultSignatures, OverlappingInstances, TemplateHaskell, ScopedTypeVariables #-}
{-# LANGUAGE ImplicitParams, KindSignatures #-}
module Language.Haskell.Names.Open.Base where

import qualified Language.Haskell.Names.GlobalSymbolTable as Global
import qualified Language.Haskell.Names.LocalSymbolTable as Local
import Language.Haskell.Names.GetBound
import Language.Haskell.Names.RecordWildcards
import Language.Haskell.Exts.Annotated
import Control.Applicative
import Control.Monad.Identity
import Data.List
import Data.Lens.Common
import Data.Lens.Template
import Data.Generics.Traversable
import Data.Typeable
import Data.Monoid
import Data.Functor.Constant
import GHC.Exts (Constraint)

-- | Describes how we should treat names in the current context
data NameContext
  = BindingT
  | BindingV
  | ReferenceT
  | ReferenceV
  | Other

-- | Contains information about the node's enclosing scope. Can be
-- accessed through the lenses: 'gTable', 'lTable', 'nameCtx', 'wcNames'.
data Scope = Scope
  { _gTable :: Global.Table
  , _lTable :: Local.Table
  , _nameCtx :: NameContext
  , _wcNames :: WcNames
  }

makeLens ''Scope

-- | Create an initial scope
initialScope :: Global.Table -> Scope
initialScope tbl = Scope tbl Local.empty Other []

-- | Merge local tables of two scopes. The other fields of the scopes are
-- assumed to be the same.
mergeLocalScopes :: Scope -> Scope -> Scope
mergeLocalScopes sc1 sc2 =
  modL lTable (<> sc2 ^. lTable) sc1

-- | The algebra for 'rtraverse'. It's newtype-wrapped because an implicit
-- parameter cannot be polymorphic.
newtype Alg w = Alg
  { runAlg :: forall d . Resolvable d => d -> Scope -> w d }

alg :: (?alg :: Alg w, Resolvable d) => d -> Scope -> w d
alg = runAlg ?alg

data ConstraintProxy (p :: * -> Constraint) = ConstraintProxy

defaultRtraverse
  :: (GTraversable Resolvable a, Applicative f, ?alg :: Alg f)
  => a -> Scope -> f a
defaultRtraverse a sc =
  let ?c = ConstraintProxy :: ConstraintProxy Resolvable
  in gtraverse (\a -> alg a sc) a

-- | A type that implements 'Resolvable' provides a way to perform
-- a shallow scope-aware traversal.

-- There is a generic implementation, 'defaultRtraverse', which is based on
-- 'GTraversable'. It can be used when there the scope of all the immediate
-- children is the same as the scope of the current node.
--
-- We use 'Typeable' here rather than a class-based approach.
-- Otherwise, hand-written instances would carry extremely long lists of
-- constraints, saying that the subterms satisfy the user-supplied class.
class Typeable a => Resolvable a where
  rtraverse
    :: (Applicative f, ?alg :: Alg f)
    => a -> Scope -> f a

instance (Typeable a, GTraversable Resolvable a) => Resolvable a where
  rtraverse = defaultRtraverse

-- | Analogous to 'gmap', but for 'Resolvable'
rmap
  :: Resolvable a
  => (forall b. Resolvable b => Scope -> b -> b)
  -> Scope -> a -> a
rmap f sc =
  let ?alg = Alg $ \a sc -> Identity (f sc a)
  in runIdentity . flip rtraverse sc

-- | Analogous to 'gmap', but for 'Resolvable'
rfoldMap
  :: (Monoid r, Resolvable a)
  => (forall b. Resolvable b => Scope -> b -> r)
  -> Scope -> a -> r
rfoldMap f sc =
  let ?alg = Alg $ \a sc -> Constant (f sc a)
  in getConstant . flip rtraverse sc

intro :: (SrcInfo l, GetBound a l) => a -> Scope -> Scope
intro node sc =
  modL lTable
    (\tbl -> foldl' (flip Local.addValue) tbl $
      getBound (sc ^. gTable) node)
    sc

setNameCtx :: NameContext -> Scope -> Scope
setNameCtx = setL nameCtx

setWcNames :: WcNames -> Scope -> Scope
setWcNames = setL wcNames

getWcNames :: Scope -> WcNames
getWcNames = getL wcNames

binderV :: Scope -> Scope
binderV = setNameCtx BindingV

binderT :: Scope -> Scope
binderT = setNameCtx BindingT

exprV :: Scope -> Scope
exprV = setNameCtx ReferenceV

exprT :: Scope -> Scope
exprT = setNameCtx ReferenceT
