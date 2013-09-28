{-# LANGUAGE DeriveDataTypeable, DeriveFunctor, DeriveFoldable,
             DeriveTraversable, StandaloneDeriving, CPP #-}
module Language.Haskell.Names.Types where

import Language.Haskell.Exts.Annotated
import Data.Typeable
import Data.Data
import Data.Monoid
import Data.Lens.Common
import qualified Data.Set as Set
import {-# SOURCE #-} qualified Language.Haskell.Names.GlobalSymbolTable as Global
import Distribution.Package
import Distribution.Text
import Data.Foldable as F
import Data.Traversable
import Text.Printf
#if ! MIN_VERSION_Cabal(1,17,0)
import Data.Version
#endif

type ExtensionSet = Set.Set KnownExtension

-- | Repesents the symbol's fixity
type SymFixity = (Assoc (), Int)

-- | Information about a value-level entitity
data SymValueInfo name
    = SymValue
      { sv_origName :: name
      , sv_fixity :: Maybe SymFixity
      }
      -- ^ value or function
    | SymMethod
      { sv_origName :: name
      , sv_fixity :: Maybe SymFixity
      , sv_className :: name
      }
      -- ^ class method
    | SymSelector
      { sv_origName :: name
      , sv_fixity :: Maybe SymFixity
      , sv_typeName :: name
      , sv_constructors :: [SelectorInfo name]
      }
      -- ^ record field selector
    | SymConstructor
      { sv_origName :: name
      , sv_fixity :: Maybe SymFixity
      , sv_typeName :: name
      , sv_arity :: Integer
      }
      -- ^ data constructor
    deriving (Eq, Ord, Show, Data, Typeable, Functor, Foldable, Traversable)

-- | Information about a selector w.r.t. a constructor
data SelectorInfo name
    = SelectorInfo
    { selConstructor :: name
    , selPosition :: Integer
    }
    deriving (Eq, Ord, Show, Data, Typeable, Functor, Foldable, Traversable)

-- | Information about a type-level entitity
data SymTypeInfo name
    = SymType
      { st_origName :: name
      , st_fixity :: Maybe SymFixity
      }
      -- ^ type synonym
    | SymData
      { st_origName :: name
      , st_fixity :: Maybe SymFixity
      }
      -- ^ data type
    | SymNewType
      { st_origName :: name
      , st_fixity :: Maybe SymFixity
      }
      -- ^ newtype
    | SymTypeFam
      { st_origName :: name
      , st_fixity :: Maybe SymFixity
      }
      -- ^ type family
    | SymDataFam
      { st_origName :: name
      , st_fixity :: Maybe SymFixity
      }
      -- ^ data family
    | SymClass
      { st_origName :: name
      , st_fixity :: Maybe SymFixity
      }
      -- ^ type class
    deriving (Eq, Ord, Show, Data, Typeable, Functor, Foldable, Traversable)

class HasOrigName i where
  origName :: i n -> n

instance HasOrigName SymValueInfo where
  origName = sv_origName

instance HasOrigName SymTypeInfo where
  origName = st_origName

-- | The set of symbols (entities) exported by a single module. Contains
-- the sets of value-level and type-level entities.
data Symbols = Symbols (Set.Set (SymValueInfo OrigName)) (Set.Set (SymTypeInfo OrigName))
  deriving (Eq, Ord, Show, Data, Typeable)

instance Monoid Symbols where
  mempty = Symbols mempty mempty
  mappend (Symbols s1 t1) (Symbols s2 t2) =
    Symbols (s1 `mappend` s2) (t1 `mappend` t2)

valSyms :: Lens Symbols (Set.Set (SymValueInfo OrigName))
valSyms = lens (\(Symbols vs _) -> vs) (\vs (Symbols _ ts) -> Symbols vs ts)

tySyms :: Lens Symbols (Set.Set (SymTypeInfo OrigName))
tySyms = lens (\(Symbols _ ts) -> ts) (\ts (Symbols vs _) -> Symbols vs ts)

mkVal :: SymValueInfo OrigName -> Symbols
mkVal i = Symbols (Set.singleton i) mempty

mkTy :: SymTypeInfo OrigName -> Symbols
mkTy i = Symbols mempty (Set.singleton i)

-- | String representing an unqualified entity name
type NameS = String
-- | String representing a module name
type ModuleNameS = String

-- | Possibly qualified name. If the name is not qualified,
-- 'ModuleNameS' is the empty string.
data GName = GName
  { gModule :: ModuleNameS
  , gName :: NameS
  }
  deriving (Eq, Ord, Show, Data, Typeable)

-- | Display a 'GName'
ppGName :: GName -> String
ppGName (GName mod name) = printf "%s.%s" mod name

#if ! MIN_VERSION_Cabal(1,17,0)
deriving instance Typeable PackageIdentifier
deriving instance Data PackageIdentifier
deriving instance Typeable PackageName
deriving instance Data PackageName
deriving instance Data Version
#endif

-- | Qualified name, where 'ModuleNameS' points to the module where the
-- name was originally defined. The module part is never empty.
--
-- Also contains name and version of the package where it was defined. If
-- it's 'Nothing', then the entity is defined in the \"current\" package.
data OrigName = OrigName
  { origPackage :: Maybe PackageId
  , origGName :: GName
  }
  deriving (Eq, Ord, Show, Data, Typeable)

-- | Display an 'OrigName'
ppOrigName :: OrigName -> String
ppOrigName (OrigName mbPkg gname) =
  maybe "" (\pkgid -> printf "%s:" $ display pkgid) mbPkg ++
  ppGName gname

-- | A pair of the name information and original annotation. Used as an
-- annotation type for AST.
data Scoped l = Scoped (NameInfo l) l
  deriving (Functor, Foldable, Traversable, Show, Typeable, Data, Eq, Ord)

data NameInfo l
    = GlobalValue (SymValueInfo OrigName) -- ^ global value
    | GlobalType  (SymTypeInfo  OrigName) -- ^ global type
    | LocalValue  SrcLoc -- ^ local value, and location where it is bound
    | TypeVar     SrcLoc -- ^ type variable, and location where it is bound
    | ValueBinder -- ^ here the value name is bound
    | TypeBinder  -- ^ here the type name is defined
    | Import      Global.Table
      -- ^ @import@ declaration, and the table of symbols that it
      -- introduces
    | ImportPart  Symbols
      -- ^ part of an @import@ declaration
    | Export      Symbols
      -- ^ @export@ declaration, and the symbols it exports
    | RecPatWildcard [OrigName]
      -- ^ wildcard in a record pattern. The list contains resolved names
      -- of the fields that are brought in scope by this pattern.
    | RecExpWildcard [(OrigName, NameInfo l)]
      -- ^ wildcard in a record construction expression. The list contains
      -- resolved names of the fields and information about values
      -- assigned to those fields.
    | None
      -- ^ no annotation
    | ScopeError  (Error l)
      -- ^ scope error
    deriving (Functor, Foldable, Traversable, Show, Typeable, Data, Eq, Ord)

data Error l
  = ENotInScope (QName l) -- FIXME annotate with namespace (types/values)
    -- ^ name is not in scope
  | EAmbiguous (QName l) [OrigName]
    -- ^ name is ambiguous
  | ETypeAsClass (QName l)
    -- ^ type is used where a type class is expected
  | EClassAsType (QName l)
    -- ^ type class is used where a type is expected
  | ENotExported
      (Maybe (Name l)) --
      (Name l)         --
      (ModuleName l)
    -- ^ Attempt to explicitly import a name which is not exported (or,
    -- possibly, does not even exist). For example:
    --
    -- >import Prelude(Bool(Right))
    --
    -- The fields are:
    --
    -- 1. optional parent in the import list, e.g. @Bool@ in @Bool(Right)@
    --
    -- 2. the name which is not exported
    --
    -- 3. the module which does not export the name
  | EModNotFound (ModuleName l)
    -- ^ module not found
  | EInternal String
    -- ^ internal error
  deriving (Data, Typeable, Show, Functor, Foldable, Traversable, Eq, Ord)

-- | Display an error.
--
-- Note: can span multiple lines; the trailing newline is included.
ppError :: SrcInfo l => Error l -> String
ppError e =
  case e of
    ENotInScope qn -> printf "%s: not in scope: %s\n"
      (ppLoc qn)
      (prettyPrint qn)
    EAmbiguous qn names ->
      printf "%s: ambiguous name %s\nIt may refer to:\n"
        (ppLoc qn)
        (prettyPrint qn)
      ++
        F.concat (map (printf "  %s\n" . ppOrigName) names)
    ETypeAsClass qn ->
      printf "%s: type %s is used where a class is expected\n"
        (ppLoc qn)
        (prettyPrint qn)
    EClassAsType qn ->
      printf "%s: class %s is used where a type is expected\n"
        (ppLoc qn)
        (prettyPrint qn)
    ENotExported _mbParent name mod ->
      printf "%s: %s does not export %s\n"
        (ppLoc name)
        (prettyPrint mod)
        (prettyPrint name)
        -- FIXME: make use of mbParent
    EModNotFound mod ->
      printf "%s: module not found: %s\n"
        (ppLoc mod)
        (prettyPrint mod)
    EInternal s -> printf "Internal error: %s\n" s

  where
    ppLoc :: (Annotated a, SrcInfo l) => a l -> String
    ppLoc = prettyPrint . getPointLoc . ann

instance (SrcInfo l) => SrcInfo (Scoped l) where
    toSrcInfo l1 ss l2 = Scoped None $ toSrcInfo l1 ss l2
    fromSrcInfo = Scoped None . fromSrcInfo
    getPointLoc = getPointLoc . sLoc
    fileName = fileName . sLoc
    startLine = startLine . sLoc
    startColumn = startColumn . sLoc

sLoc :: Scoped l -> l
sLoc (Scoped _ l) = l
