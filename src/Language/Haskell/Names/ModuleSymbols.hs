{-# LANGUAGE ScopedTypeVariables #-}
module Language.Haskell.Names.ModuleSymbols
  ( moduleSymbols
  , moduleTable
  , getTopDeclSymbols
  )
  where

import Data.Maybe
import Data.Either
import Data.Lens.Common
import Data.Monoid
import Data.Data
import qualified Data.Set as Set
import qualified Data.Map as Map
import Control.Monad

import Language.Haskell.Exts.Annotated
import Language.Haskell.Names.Types
import qualified Language.Haskell.Names.GlobalSymbolTable as Global
import Language.Haskell.Names.SyntaxUtils
import Language.Haskell.Names.ScopeUtils
import Language.Haskell.Names.GetBound

-- | Compute module's global table. It contains both the imported entities
-- and the global entities defined in this module.
moduleTable
  :: (Eq l, Data l)
  => Global.Table -- ^ the import table for this module
  -> Module l
  -> Global.Table
moduleTable impTbl m =
  impTbl <>
  computeSymbolTable False (getModuleName m) (moduleSymbols impTbl m)

-- | Compute the symbols that are defined in the given module.
--
-- The import table is needed to resolve possible top-level record
-- wildcard bindings, such as
--
-- >A {..} = foo
moduleSymbols
  :: (Eq l, Data l)
  => Global.Table -- ^ the import table for this module
  -> Module l
  -> Symbols
moduleSymbols impTbl m =
  let (vs,ts) =
        partitionEithers $
          concatMap
            (getTopDeclSymbols impTbl $ getModuleName m)
            (getModuleDecls m)
  in
    setL valSyms (Set.fromList vs) $
    setL tySyms  (Set.fromList ts) mempty

type TypeName = GName
type ConName = Name ()
type SelectorName = Name ()
type Constructors = [(ConName, [SelectorName])]

-- Extract names that get bound by a top level declaration.
getTopDeclSymbols
  :: forall l . (Eq l, Data l)
  => Global.Table -- ^ the import table for this module
  -> ModuleName l
  -> Decl l
  -> [Either (SymValueInfo OrigName) (SymTypeInfo OrigName)]
getTopDeclSymbols impTbl mdl d =
  map (either (Left . fmap toOrig) (Right . fmap toOrig)) $
  case d of
    TypeDecl _ dh _ ->
      let tn = hname dh
      in  [ Right (SymType        { st_origName = tn, st_fixity = Nothing })]

    TypeFamDecl _ dh _ ->
      let tn = hname dh
      in  [ Right (SymTypeFam     { st_origName = tn, st_fixity = Nothing })]

    DataDecl _ dataOrNew _ dh qualConDecls _ ->
      let
        cons :: Constructors
        cons = do -- list monad
          QualConDecl _ _ _ conDecl <- qualConDecls
          case conDecl of
            ConDecl _ n _ -> return (void n, [])
            InfixConDecl _ _ n _ -> return (void n, [])
            RecDecl _ n fields ->
              return (void n , [void f | FieldDecl _ fNames _ <- fields, f <- fNames])

        dq = hname dh

        infos = constructorsToInfos dq cons

      in
        Right (dataOrNewCon dataOrNew dq Nothing) : map Left infos

    GDataDecl _ dataOrNew _ dh _ gadtDecls _ ->
      -- As of 1.14.0, HSE doesn't support GADT records.
      -- When it does, this code should be rewritten similarly to the
      -- DataDecl case.
      -- (Also keep in mind that GHC doesn't create selectors for fields
      -- with existential type variables.)
      let
        dq = hname dh
      in
          Right (dataOrNewCon dataOrNew dq Nothing) :
        [ Left (SymConstructor { sv_origName = qname cn, sv_fixity = Nothing, sv_typeName = dq })
        | GadtDecl _ cn _ <- gadtDecls
        ]

    ClassDecl _ _ dh _ mds ->
      let
        ms = getBound impTbl d
        cq = hname dh
        cdecls = fromMaybe [] mds
      in
          Right (SymClass   { st_origName = cq,       st_fixity = Nothing }) :
        [ Right (SymTypeFam { st_origName = hname dh, st_fixity = Nothing }) | ClsTyFam   _   dh _ <- cdecls ] ++
        [ Right (SymDataFam { st_origName = hname dh, st_fixity = Nothing }) | ClsDataFam _ _ dh _ <- cdecls ] ++
        [ Left  (SymMethod  { sv_origName = qname mn, sv_fixity = Nothing, sv_className = cq }) | mn <- ms ]

    FunBind _ ms ->
      let vn : _ = getBound impTbl ms
      in  [ Left  (SymValue { sv_origName = qname vn, sv_fixity = Nothing }) ]

    PatBind _ p _ _ _ ->
      [ Left  (SymValue { sv_origName = qname vn, sv_fixity = Nothing }) | vn <- getBound impTbl p ]

    ForImp _ _ _ _ fn _ ->
      [ Left  (SymValue { sv_origName = qname fn, sv_fixity = Nothing }) ]

    _ -> []
  where
    ModuleName _ smdl = mdl
    qname = GName smdl . nameToString
    hname = qname . fst . splitDeclHead
    toOrig = OrigName Nothing
    dataOrNewCon dataOrNew = case dataOrNew of DataType {} -> SymData; NewType {} -> SymNewType

    constructorsToInfos :: TypeName -> Constructors -> [SymValueInfo GName]
    constructorsToInfos ty cons = conInfos ++ selInfos
      where
        conInfos =
          [ SymConstructor { sv_origName = qname con, sv_fixity = Nothing, sv_typeName = ty }
          | (con, _) <- cons
          ]

        selectorsMap :: Map.Map SelectorName [ConName]
        selectorsMap =
          Map.unionsWith (++) . flip map cons $ \(c, fs) ->
            Map.unionsWith (++) . flip map fs $ \f ->
              Map.singleton f [c]

        selInfos =
          [ (SymSelector { sv_origName = qname f, sv_fixity = Nothing, sv_typeName = ty, sv_constructors = map qname fCons })
          | (f, fCons) <- Map.toList selectorsMap
          ]
