module Reducing where

import Prelude hiding (True,False,abs,and,or)
import Control.Arrow ((***))
import Base
import Error
import Substitution
import Resolving (disambiguate)
import Control.Applicative ((<$>),(<*>))
import qualified Data.Bool as B (Bool (True,False))
import qualified Data.Map as M (lookup,empty,insert,mapWithKey,elems)

-- * Main functions

evalProg :: Prog -> Either String Prog
evalProg (Prog size ds0 rewr) = do
  (env, tyenv) <- supplyFreshNames (disambiguate ds0 >>= eval size rewr)
  let ds1 = M.mapWithKey (\n e -> Decl n (M.lookup n tyenv) e) env
  return (Prog size (M.elems ds1) rewr)

-- * Evaluation Strategies

type Size = Int

concretize :: Int -> Expr -> Expr
concretize i e = App e (obj i) (Just $ TyCon "t")

class Reducible e where
  reduce :: Env -> Size -> e -> Error e

instance (Reducible e1, Reducible e2) => Reducible (e1,e2) where
  reduce env size (e1,e2) = do
    e1' <- reduce env size e1
    e2' <- reduce env size e2
    return (e1' , e2')

instance (Reducible e1, Reducible e2, Reducible e3) => Reducible (e1,e2,e3) where
  reduce env size (e1,e2,e3) = do
    e1' <- reduce env size e1
    e2' <- reduce env size e2
    e3' <- reduce env size e3
    return (e1' , e2' , e3')

primBOOL :: Bool -> Expr
primBOOL B.True  = prim "TRUE"
primBOOL B.False = prim "FALSE"

primNOT :: (Expr -> Error Expr) -> Expr -> Error Expr
primNOT cont e1 =
  do r1 <- cont e1
     case r1 of
       Var "FALSE" _ -> return (prim "TRUE")
       Var "TRUE"  _ -> return (prim "FALSE")
       _             -> return (fun1 "NOT" r1)

primAND :: (Expr -> Error Expr) -> Expr -> Expr -> Error Expr
primAND cont e1 e2 =
  do r1 <- cont e1
     case r1 of
       Var "FALSE" _ -> return (prim "FALSE")
       Var "TRUE"  _ ->
         do r2 <- cont e2
            case r2 of
              Var "FALSE" _ -> return (prim "FALSE")
              Var "TRUE"  _ -> return (prim "TRUE")
              _             -> return (fun2 "AND" r1 r2)
       _             -> return (fun2 "AND" r1 e2)

primEQUALS :: (Expr -> Error Expr) -> Expr -> Expr -> Error Expr
primEQUALS cont e1 e2 =
  do r1 <- cont e1
     r2 <- cont e2
     case (r1,r2) of
       (Obj i _ , Obj j _) -> return (primBOOL (i == j))
       _                   -> return (fun2 "EQUALS" r1 r2)

primIOTA :: (Expr -> Error Expr) -> Size -> Expr -> Error Expr
primIOTA k d iota@(App (Var "IOTA" _) e1 _) =
  do es <- mapM k [ concretize o e1 | o <- [0 .. d - 1]]
     let is0 = zip [0 ..] es
     let is1 = filter (isTRUE . snd) is0
     case is1 of
       [   ] -> return iota
       [ p ] -> return (obj (fst p))
       _     -> fail ("IOTA: non-unique object for predicate, in " ++ show e1)

rewriteOR :: Expr -> Expr -> Expr
rewriteOR e1 e2 = fun1 "NOT" (fun2 "AND" (fun1 "NOT" e1) (fun1 "NOT" e2))

rewriteIMPLIES :: Expr -> Expr -> Expr
rewriteIMPLIES e1 e2 = fun2 "OR" (fun1 "NOT" e1) e2

rewriteEQUIV :: Expr -> Expr -> Expr
rewriteEQUIV e1 e2 = fun2 "AND" (rewriteIMPLIES e1 e2) (rewriteIMPLIES e2 e1)

rewriteFORALL :: Size -> Expr -> Expr
rewriteFORALL size e =
  foldr1 (fun2 "AND") [ concretize o e | o <- [0 .. size - 1]]

rewriteEXISTS :: Size -> Expr -> Expr
rewriteEXISTS size e =
  foldr1 (fun2 "OR") [ concretize o e | o <- [0 .. size - 1]]

isTRUE :: Expr -> Bool
isTRUE (Var "TRUE" _) = B.True
isTRUE _ = B.False

toBool :: Expr -> Maybe Bool
toBool (Var "TRUE"  _) = Just B.True
toBool (Var "FALSE" _) = Just B.False
toBool _ = Nothing

instance Reducible Expr where
  reduce env size = reduce'
    where
      -- Reduction rules for primitive functions
      reduce' (App (Var "NOT" _) e1 _)                = primNOT reduce' e1
      reduce' (App (App (Var "AND" _) e1 _) e2 _)     = primAND reduce' e1 e2
      reduce' (App (App (Var "EQUALS" _) e1 _) e2 _)  = primEQUALS reduce' e1 e2
      reduce' (App (App (Var "OR" _) e1 _) e2 _)      = reduce' $ rewriteOR e1 e2
      reduce' (App (App (Var "IMPLIES" _) e1 _) e2 _) = reduce' $ rewriteIMPLIES e1 e2
      reduce' (App (App (Var "EQUIV" _) e1 _) e2 _)   = reduce' $ rewriteEQUIV e1 e2
      reduce' (App (Var "FORALL" _) e1 _)             = reduce' $ rewriteFORALL size e1
      reduce' (App (Var "EXISTS" _) e1 _)             = reduce' $ rewriteEXISTS size e1
      reduce' iota@(App (Var "IOTA" _) e1 _)          = primIOTA reduce' size iota

      -- Beta reduction (TODO may be vulnerable to name capturing)
      reduce' (App (Abs n e2 _) e1 _) = reduce' (apply (Subst n e1) e2)

      -- Charasteristic function application (set reduction)
      reduce' (App (App (App (Rel3 es _) e1 _) e2 _) e3 _) = return (primBOOL ((e1,e2,e3) `elem` es))
      reduce' (App (App (Rel2 es _) e1 _) e2 _) = return (primBOOL ((e1,e2) `elem` es))
      reduce' (App (Rel1 es _) e1 _) = return (primBOOL (e1 `elem` es))

      -- Delayed reductions
      reduce' (App e1 e2 t) = do
        r1 <- reduce' e1
        r2 <- reduce' e2
        case r1 of
          Abs  {} -> reduce' (App r1 r2 t)
          Rel1 {} -> reduce' (App r1 r2 t)
          Rel2 {} -> reduce' (App r1 r2 t)
          Rel3 {} -> reduce' (App r1 r2 t)
          _       -> return  (App r1 r2 t)

      -- Simple forwarding rules
      reduce' (Abs n e t)    = do e' <- reduce' e; return (Abs n e' t)
      reduce' v@(Var n _)    = case M.lookup n env of
        Just e' -> reduce' e'
        Nothing -> return  v
      --reduce' (Pair e1 e2 t) = do e1' <- reduce' e1; e2' <- reduce' e2; return (Pair e1' e2' t)
      --reduce' (Case n1 n2 e t) = do e' <- reduce' e; return (Case n1 n2 e' t)
      reduce' o@(Obj _ _)    = return o
      reduce' (Rel1 es t)    = do es' <- mapM reduce' es; return (Rel1 es' t)
      reduce' (Rel2 es t)    = do es' <- mapM (reduce env size) es; return (Rel2 es' t)
      reduce' (Rel3 es t)    = do es' <- mapM (reduce env size) es; return (Rel3 es' t)
      reduce' (Plug e c _)   = do c' <- reduce' c; e' <- reduce' e; reduce' (plug e' c')
      reduce' h@(Hole _)     = return h


plug :: Expr -> Expr -> Expr
plug _ v@(Var _ _)      = v
plug f (Abs x e1 t)     = Abs x (plug f e1) t
plug f (App e1 e2 t)    = App (plug f e1) (plug f e2) t
plug _ o@(Obj _ _)      = o
plug f (Rel1 xs t)      = Rel1 (map (plug  f) xs) t
plug f (Rel2 xs t)      = Rel2 (map (plug2 f) xs) t
plug f (Rel3 xs t)      = Rel3 (map (plug3 f) xs) t
plug f (Hole _)         = f
plug f (Plug e c t)     = Plug (plug f e) c t

plug2 :: Expr -> (Expr,Expr) -> (Expr,Expr)
plug2 f (e1,e2) = (plug f e1 , plug f e2)

plug3 :: Expr -> (Expr,Expr,Expr) -> (Expr,Expr,Expr)
plug3 f (e1,e2,e3) = (plug f e1 , plug f e2 , plug f e3)


eval :: Size -> [Rewr] -> [Decl] -> Error (Env , TyEnv)
eval size rw = evalAcc (M.empty , M.empty)
  where
    evalAcc :: (Env , TyEnv) -> [Decl] -> Error (Env , TyEnv)
    evalAcc (env , tyenv) []
      = return (env , tyenv)
    evalAcc (env , tyenv) (Decl n (Just t) e : ds)
      = do e' <- reduce env size e
           evalAcc (M.insert n e' env , M.insert n t tyenv) ds
