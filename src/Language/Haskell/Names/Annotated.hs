-- This module uses the open recursion interface
-- ("Language.Haskell.Names.Open") to annotate the AST with binding
-- information.
{-# LANGUAGE FlexibleContexts, MultiParamTypeClasses, ImplicitParams,
    UndecidableInstances, ScopedTypeVariables,
    TypeOperators, GADTs #-}
module Language.Haskell.Names.Annotated
  ( Scoped(..)
  , NameInfo(..)
  , annotateDecl
  ) where


import Language.Haskell.Names.Types
import Language.Haskell.Names.RecordWildcards
import Language.Haskell.Names.Open.Base
import Language.Haskell.Names.Open.Instances ()
import qualified Language.Haskell.Names.GlobalSymbolTable as Global
import qualified Language.Haskell.Names.LocalSymbolTable as Local
import Language.Haskell.Names.SyntaxUtils (dropAnn, annName,setAnn)
import Language.Haskell.Exts
import Language.Haskell.Exts.Syntax
import Data.Proxy
import Data.Lens.Light
import Data.Typeable (
  Typeable, (:~:)(Refl), eqT)
  -- in GHC 7.8 Data.Typeable exports (:~:). Be careful to avoid the clash.
import Control.Applicative


annotateDecl
  :: forall a l .
     (Resolvable (a (Scoped l)), Functor a, Typeable l)
  => Scope -> a l -> a (Scoped l)
annotateDecl sc = annotateRec (Proxy :: Proxy l) sc . fmap (Scoped None)

annotateRec
  :: forall a l .
     (Typeable l, Resolvable a)
  => Proxy l -> Scope -> a -> a
annotateRec _ sc a = go sc a where
  go :: forall a . Resolvable a => Scope -> a -> a
  go sc a
    | ReferenceV <- getL nameCtx sc
    , Just (Refl :: QName (Scoped l) :~: a) <- eqT
      = lookupValue (fmap sLoc a) sc <$ a
    | ReferenceT <- getL nameCtx sc
    , Just (Refl :: QName (Scoped l) :~: a) <- eqT
      = lookupType (fmap sLoc a) sc <$ a
    | ReferenceUV <- getL nameCtx sc
    , Just (Refl :: Name (Scoped l) :~: a) <- eqT
      = lookupMethod (fmap sLoc a) sc <$ a
    | ReferenceUT <- getL nameCtx sc
    , Just (Refl :: QName (Scoped l) :~: a) <- eqT
      = lookupAssociatedType (fmap sLoc a) sc <$ a
    | BindingV <- getL nameCtx sc
    , Just (Refl :: Name (Scoped l) :~: a) <- eqT
      = Scoped ValueBinder (sLoc . ann $ a) <$ a
    | BindingT <- getL nameCtx sc
    , Just (Refl :: Name (Scoped l) :~: a) <- eqT
      = Scoped TypeBinder (sLoc . ann $ a) <$ a
    | Just (Refl :: FieldUpdate (Scoped l) :~: a) <- eqT
      = case a of
          FieldPun l n -> FieldPun l (lookupValue (sLoc <$> n) sc <$ n)
          FieldWildcard l -> FieldWildcard (Scoped (RecExpWildcard namesRes) (sLoc l)) where
            namesRes = do
                f <- sc ^. wcNames
                let qn = setAnn (sLoc l) (UnQual () (annName (wcFieldName f)))
                case lookupValue qn sc of
                    Scoped info@(GlobalSymbol _ _) _ -> return (wcFieldName f,info)
                    Scoped info@(LocalValue _) _ -> return (wcFieldName f,info)
                    _ -> []
          _ -> rmap go sc a
    | Just (Refl :: PatField (Scoped l) :~: a) <- eqT
    , PFieldWildcard l <- a
      = let
            namesRes = do
                f <- sc ^. wcNames
                let qn = UnQual () (annName (wcFieldName f))
                Scoped (GlobalSymbol symbol _) _ <- return (lookupValue qn sc)
                return (symbol {symbolModule = wcFieldModuleName f})
        in PFieldWildcard (Scoped (RecPatWildcard namesRes) (sLoc l))            
    | otherwise
      = rmap go sc a

lookupValue :: QName l -> Scope -> Scoped l
lookupValue (Special l _) _ = Scoped None l
lookupValue qn sc = Scoped nameInfo (ann qn)
  where
    nameInfo =
      case Local.lookupValue qn $ getL lTable sc of
        Right r -> LocalValue r
        _ ->
          case Global.lookupValue qn $ getL gTable sc of
            Global.SymbolFound r -> GlobalSymbol r (dropAnn qn)
            Global.Error e -> ScopeError e
            Global.Special -> None

lookupType :: QName l -> Scope -> Scoped l
lookupType (Special l _) _ = Scoped None l
lookupType qn sc = Scoped nameInfo (ann qn)
  where
    nameInfo =
      case Global.lookupType qn $ getL gTable sc of
        Global.SymbolFound r -> GlobalSymbol r (dropAnn qn)
        Global.Error e -> ScopeError e
        Global.Special -> None

lookupMethod :: Name l -> Scope -> Scoped l
lookupMethod n sc = Scoped nameInfo (ann qn)
  where
    nameInfo =
      case Global.lookupMethodOrAssociate qn $ getL gTable sc of
        Global.SymbolFound r -> GlobalSymbol r (dropAnn qn)
        Global.Error e -> ScopeError e
        Global.Special -> None
    qn = qualifyName (getL instQual sc) n

lookupAssociatedType :: QName l -> Scope -> Scoped l
lookupAssociatedType qn sc = Scoped nameInfo (ann qn)
  where
    nameInfo =
      case Global.lookupMethodOrAssociate qn' $ getL gTable sc of
        Global.SymbolFound r -> GlobalSymbol r (dropAnn qn)
        Global.Error e -> ScopeError e
        Global.Special -> None
    qn' = case qn of
        UnQual _ n -> qualifyName (getL instQual sc) n
        _ -> qn

qualifyName :: Maybe (ModuleName ()) -> Name l -> QName l
qualifyName Nothing n = UnQual (ann n) n
qualifyName (Just (ModuleName () moduleName)) n = Qual (ann n) annotatedModuleName n
  where
    annotatedModuleName = ModuleName (ann n) moduleName
