{-# LANGUAGE RankNTypes, NoMonomorphismRestriction, BangPatterns,
  DeriveDataTypeable, GADTs, ScopedTypeVariables,
  ExistentialQuantification, StandaloneDeriving #-}
{-# OPTIONS -Wall #-}

module InterpreterMH where

import System.Random (RandomGen, StdGen, randomR, getStdGen)

import Data.Dynamic
import Data.Maybe

import qualified Data.Map.Strict as M

import Lambda
import RandomChoice
import Visual

{-

Shortcomings of this implementation

* uses parent-conditional sampling for proposal distribution
* re-evaluates entire program at every sample
* lacks way to block sample groups of variables

-}

type DistVal = Dynamic

data Dist a = Dist {logDensity :: a -> Likelihood,
                    sample :: forall g. RandomGen g => g -> (a, g)}
deriving instance Typeable1 Dist
 
-- and what does XRP stand for?
data XRP where
  XRP :: Typeable e => (e, Dist e) -> XRP

unXRP :: Typeable a => XRP -> Maybe (a, Dist a)
unXRP (XRP (e,f)) = cast (e,f)

type Likelihood = Double
type Visited = Bool
type Observed = Bool
type Cond = Maybe DistVal

type Subloc = Int
type Name = [Subloc]
data Seen = Seen { xrp  :: XRP, 
                   llhd :: Likelihood, 
                   vis  :: Visited,
                   obsd :: Observed }
type Database = M.Map Name Seen

-- no idea what to call this, someone else can rename
-- the g will be bound by Measure
data Thing a g where
  T :: { sname :: a,
         ldb :: Database, -- ldb = local database
         llh2 :: (Likelihood, Likelihood),
         conds :: [Cond],
         seed :: g } -> Thing a g

prefix :: Subloc -> Thing Name g -> Thing Name g
prefix n t = t {sname = n : sname t}

upd_sname :: a -> Thing b g -> Thing a g
upd_sname x t = t { sname = x}

newtype Measure a = Measure {unMeasure :: (RandomGen g) =>
  Thing Name g -> Thing a g }
--  (Name, Database, (Likelihood, Likelihood), [Cond], g) ->
--  (a   , Database, (Likelihood, Likelihood), [Cond], g)}
  deriving (Typeable)

-- n  is structural_name
-- d  is database
-- ll is likelihood of expression
-- conds is the observed data
-- g  is the random seed

return_ :: a -> Measure a
return_ x = Measure (upd_sname x)

makeXRP :: (Typeable a, RandomGen g) => Cond -> Dist a
        -> Name -> Database -> g
        -> (a, Database, Likelihood, Likelihood, g)
makeXRP obs dist' n db g =
    case M.lookup n db of
      Just (Seen xd lb _ ob) ->
        let Just (xb, dist) = unXRP xd
            (x,_) = case obs of
                      Just yd ->
                          let Just y = fromDynamic yd
                          in (y, logDensity dist y)
                      Nothing -> (xb, lb)
            l' = logDensity dist' x
            d1 = M.insert n (Seen (XRP (x,dist)) l' True ob) db
        in (x, d1, l', 0, g)
      Nothing ->
        let (xnew, l, g1) = case obs of
             Just xdnew ->
                 let Just xnew2 = fromDynamic xdnew
                 in (xnew2, logDensity dist' xnew2, g)
             Nothing ->
                 (xnew, logDensity dist' xnew2, g2)
                where (xnew2, g2) = sample dist' g
            d1 = M.insert n (Seen (XRP (xnew, dist')) l True (isJust obs)) db
        in (xnew, d1, l, l, g1)

-- this is probably not the 'right' arguments to give here
updateLikelihood :: (Typeable a, RandomGen g) => 
                    Likelihood -> Likelihood ->
                    (a, Database, Likelihood, Likelihood, g) ->
                    [Cond] ->
                    Thing a g
updateLikelihood llTotal llFresh (x,d,l,lf,g) cds =
    T x d (llTotal+l, llFresh+lf) cds g

diracDist :: Eq a => a -> Dist a
diracDist theta = Dist {logDensity = (\ x -> if x == theta then 0 else log 0),
                            sample = (\ g -> (theta,g))}

bernDist :: Double -> Dist Bool
bernDist p = Dist {logDensity = (\ x -> log (if x then p else 1 - p)),
                       sample = (\ g -> case randomR (0, 1) g of
                                          (t, g') -> (t <= p, g'))}

poissonDist :: Double -> Dist Int
poissonDist l' =
    let poissonLogDensity l x | l > 0 && x> 0 = (fromIntegral x)*(log l) - lnFact x - l
        poissonLogDensity l x | x==0 = -l
        poissonLogDensity _ _ = log 0 in
     Dist {logDensity = poissonLogDensity l',
               sample = poisson_rng l'}

gammaDist :: (Double, Double) -> Dist Double
gammaDist (shape, scale) = 
    Dist {logDensity = gammaLogDensity shape scale,
              sample = gamma_rng shape scale}

betaDist :: (Double, Double) -> Dist Double
betaDist (a,b) = 
    Dist {logDensity = betaLogDensity a b,
              sample = beta_rng a b}

uniformDist :: (Double, Double) -> Dist Double
uniformDist (l,h) =
    let uniformLogDensity lo hi x | lo <= x && x <= hi = log (recip (hi - lo))
        uniformLogDensity _ _  _ = log 0 in
    Dist {logDensity = uniformLogDensity l h,
              sample = (\ g -> randomR (l, h) g)}

normalDist :: (Double, Double) -> Dist Double
normalDist (mu, sd) = 
    Dist {logDensity = normalLogDensity mu sd,
              sample = normal_rng mu sd}

laplaceDist :: (Double, Double) -> Dist Double
laplaceDist (mu, sd) = 
    Dist {logDensity = laplaceLogDensity mu sd,
              sample = laplace_rng mu sd}

categoricalDist :: (Eq a, Typeable a) => [(a, Double)] -> Dist a
categoricalDist list =
    let categoricalLogDensity lst x = log $ fromMaybe 0 (lookup x lst)
        categoricalSample lst g = (el, g1)
           where
             (p, g1) = randomR (0, total) g
             el = fst $ head $ filter (\(_,p0) -> p <= p0) sumList
             sumList = scanl1 (\acc (a, b) -> (a, b + snd(acc))) lst
             total = sum $ map snd lst
    in Dist {logDensity = categoricalLogDensity list,
                 sample = categoricalSample list}

-- and now lift all the distributions to measures
liftDistToMeas :: Typeable b => (a -> Dist b) -> a -> Cond -> Measure b
liftDistToMeas f x obs = Measure $ 
  \(T n d (llTotal,llFresh) cds g) ->
    let new_xrp = makeXRP obs (f x) n d g
    in updateLikelihood llTotal llFresh new_xrp cds

dirac :: (Eq a, Typeable a) => a -> Cond -> Measure a
dirac = liftDistToMeas diracDist

bern :: Double -> Cond -> Measure Bool
bern = liftDistToMeas bernDist

poisson :: Double -> Cond -> Measure Int
poisson = liftDistToMeas poissonDist

gamma :: Double -> Double -> Cond -> Measure Double
gamma shape scale = liftDistToMeas gammaDist (shape, scale)

beta :: Double -> Double -> Cond -> Measure Double
beta a b = liftDistToMeas betaDist (a,b)

uniform :: Double -> Double -> Cond -> Measure Double
uniform lo hi = liftDistToMeas uniformDist (lo,hi)

normal :: Double -> Double -> Cond -> Measure Double
normal mu sd = liftDistToMeas normalDist (mu, sd)

laplace :: Double -> Double -> Cond -> Measure Double
laplace mu sd = liftDistToMeas laplaceDist (mu, sd)

categorical :: (Eq a, Typeable a) => [(a,Double)] 
            -> Cond -> Measure a
categorical = liftDistToMeas categoricalDist

factor :: Likelihood -> Measure ()
factor l = Measure $ \t -> 
    let (llTotal, llFresh) = llh2 t in
    t {sname = (), llh2 = (llTotal + l, llFresh) }

resample :: RandomGen g => XRP -> g ->
            (XRP, Likelihood, Likelihood, Likelihood, g)
resample (XRP (x, dist)) g =
    let (x', g1) = sample dist g
        fwd = logDensity dist x'
        rvs = logDensity dist x
        l' = fwd
    in (XRP (x', dist), l', fwd, rvs, g1)

bind :: Measure a -> (a -> Measure b) -> Measure b
bind (Measure m) cont = Measure $ \ t ->
    let t' = m (prefix 0 t)
    in unMeasure (cont $ sname t') (upd_sname (1:sname t) t')

conditioned :: (Cond -> Measure a) -> Measure a
conditioned f = Measure $ \ t@(T {conds = cond:cds}) ->
    unMeasure (f cond) (t {conds = cds})

unconditioned :: (Cond -> Measure a) -> Measure a
unconditioned f = f Nothing

instance Monad Measure where
  return = return_
  (>>=)  = bind

run :: Measure a -> [Cond] -> IO (a, Database, Likelihood)
run (Measure prog) cds = do
  g <- getStdGen
  let T v d ll _ _ = prog (T [0] M.empty (0,0) cds g)
  return (v, d, fst ll)

traceUpdate :: RandomGen g => Measure a -> Database -> [Cond] -> g
            -> (a, Database, Likelihood, Likelihood, Likelihood, g)
traceUpdate (Measure prog) d cds g = do
  -- let d1 = M.map (\ (x, l, _, ob) -> (x, l, False, ob)) d
  let d1 = M.map (\ s -> s { vis = False }) d
  let T v d2 (llTotal, llFresh) _ g1 = prog (T [0] d1 (0,0) cds g)
  let (d3, stale_d) = M.partition vis d2
  let llStale = M.foldl' (\ llStale' s -> llStale' + llhd s) 0 stale_d
  (v, d3, llTotal, llFresh, llStale, g1)

initialStep :: Measure a -> [Cond] ->
               IO (a, Database,
                   Likelihood, Likelihood, Likelihood, StdGen)
initialStep prog cds = do
  g <- getStdGen
  return $ traceUpdate prog M.empty cds g

-- TODO: Make a way of passing user-provided proposal distributions
updateDB :: (RandomGen g) => 
            Name -> Database -> Observed -> XRP -> g
         -> (Database, Likelihood, Likelihood, Likelihood, g)
updateDB name db ob xd g = (db', l', fwd, rvs, g)
    where db' = M.insert name (Seen x' l' True ob) db
          (x', l', fwd, rvs, _) = resample xd g

transition :: (Typeable a, RandomGen g) => Measure a -> [Cond]
           -> a -> Database -> Likelihood -> g -> [a]
transition prog cds v db ll g =
  let dbSize = M.size db
      -- choose an unconditioned choice
      (_, uncondDb) = M.partition obsd db
      (choice, g1) = randomR (0, (M.size uncondDb) -1) g
      (name, (Seen xd _ _ ob))  = M.elemAt choice uncondDb
      (db', _, fwd, rvs, g2) = updateDB name db ob xd g1
      (v', db2, llTotal, llFresh, llStale, g3) = traceUpdate prog db' cds g2
      a = llTotal - ll
          + rvs - fwd
          + log (fromIntegral dbSize) - log (fromIntegral $ M.size db2)
          + llStale - llFresh
      (u, g4) = randomR (0 :: Double, 1) g3 in

  if (log u < a) then
      v' : (transition prog cds v' db2 llTotal g4)
  else
      v : (transition prog cds v db ll g4)

mcmc :: Typeable a => Measure a -> [Cond] -> IO [a]
mcmc prog cds = do
  (v, d, llTotal, _, _, g) <- initialStep prog cds
  return $ transition prog cds v d llTotal g

test :: Measure Bool
test = unconditioned (bern (dbl 0.5)) `bind` \c ->
       ifThenElse c (conditioned (normal (dbl 1) (dbl 1)))
                    (conditioned (uniform (dbl 0) (dbl 0))) `bind` \_ ->
       return_ c

main_run_test :: IO (Bool, Database, Likelihood)
main_run_test = run test [Just (toDyn (-2 :: Double))]

main_test :: IO [Bool]
main_test = mcmc test [Just (toDyn (-2 :: Double))]

test_two_normals :: Measure Bool
test_two_normals = unconditioned (bern 0.5) `bind` \coin ->
       ifThenElse coin (conditioned (normal 0 1))
                       (conditioned (normal 100 1)) `bind` \_ ->
       return_ coin

main_test2 :: IO [Bool]
main_test2 = mcmc test_two_normals [Just (toDyn (1 :: Double))]

main :: IO ()
main = do
  l <- mcmc (unconditioned
             (normal (dbl 1) (dbl 3)) `bind` \n ->
             return_ n) [] :: IO [Double]
  viz 10000 ["normal"] (map return l)
