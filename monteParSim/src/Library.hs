{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Library (bernoulli, monteCarloAsian, validateInputs, monteCarloAsianParallel,
bernoulliParallel, unfoldsSMGen, monteCarloAsianVector, monteCarloAsianParallelVector,
unfoldBernoulli, vectorTrial) where

import System.Random
import System.Random.SplitMix
import qualified Data.Vector as V
import Control.Monad (replicateM, unless, when)
import Control.Parallel.Strategies (rdeepseq, Eval, parListChunk, runEval, withStrategy)

-- Sequential Content Begins --
monteCarloAsian :: Int -> Int -> Double -> Double -> Double -> Double -> Double -> IO Double
monteCarloAsian n t r u d s0 k = do
  -- Calculate discount factor and probability of an up movement
  let discount = 1 / ((1 + r) ^ t)
      pStar    = (1 + r - d) / (u - d)

  -- Perform a single trial of the simulation
  let seqTrial = do
        -- Recursively calculate the sum of prices along a path
        let seqCalcPrice i sumPrices price
              | i == t = return sumPrices
              | otherwise = do
                b <- bernoulli pStar
                if b == 1
                    then seqCalcPrice (i + 1) (sumPrices + (price * u)) (price * u)
                    else seqCalcPrice (i + 1) (sumPrices + (price * d)) (price * d)

        -- Calculate the difference between average simulate price and strike price
        sumPrices <- seqCalcPrice 0 0.0 s0
        let diffVal = (sumPrices / fromIntegral t) - k
        return $ diffVal `max` 0

  -- Perform 'n' trials and compute the average
  total <- sum <$> replicateM n seqTrial
  return $ (total * discount) / fromIntegral n

-- Main function for sequential vectors
monteCarloAsianVector :: Int -> Int -> Double -> Double -> Double -> Double -> Double -> IO Double
monteCarloAsianVector n t r u d s0 k = do
  let discount = 1 / ((1 + r) ** fromIntegral t)
      pStar    = (1 + r - d) / (u - d)

  let vectorTrialSeq = do
        steps <- V.replicateM t (bernoulli pStar)
        let priceVector = V.scanl' (\price step -> price * (if step == 1 then u else d)) s0 steps
            sumPrices   = V.sum priceVector - V.head priceVector
            avgPrice    = sumPrices / fromIntegral t
            diffVal     = avgPrice - k
        return $ max diffVal 0

  total <- sum <$> replicateM n vectorTrialSeq
  return $ (total * discount) / fromIntegral n

-- Helper function for sequential algorithm to generate random values
bernoulli :: Double -> IO Int
bernoulli p = do
    randomVal <- randomIO -- :: IO Double
    return $ if randomVal < p then 1 else 0

-- Sequential Content Ends --
-- Parallel Content Begins --

-- Main function for the parallel simulations
monteCarloAsianParallel :: Int -> Int -> Int -> Double -> Double -> Double -> Double -> Double -> SMGen -> Double
monteCarloAsianParallel numCores n t r u d s0 k init_gen =
  let !discount = 1 / ((1 + r) ^ t)
      !pStar = (1 + r - d) / (u - d)
      chunkSize = n `div` (10 * numCores)
      gens = unfoldsSMGen init_gen n
      trials = withStrategy (parListChunk chunkSize rdeepseq) $
               map (runEval . trial pStar u d s0 k t) gens
      !result = sum trials * discount / fromIntegral n
  in result

-- Helper function to unfold SMGen into a list of n generators
unfoldsSMGen :: SMGen -> Int -> [SMGen]
unfoldsSMGen gen n = take n $ iterate (snd . splitSMGen) gen

-- Helper function to complete a single trial
trial :: Double -> Double -> Double -> Double -> Double -> Int -> SMGen -> Eval Double
trial pStar u d s0 k t genTrial = do
  let (!sumPrices, _) = calcPrice 0 t pStar u d 0 s0 genTrial
      !diffVal = (sumPrices / fromIntegral t) - k
  return $ max diffVal 0

-- Helper function to calculate the price in a given trial
calcPrice :: Int -> Int -> Double -> Double -> Double -> Double -> Double -> SMGen -> (Double, SMGen)
calcPrice i t pStar u d !sumPrices !price genCalc
  | i == t    = (sumPrices, genCalc)
  | otherwise = let (b, genNext) = bernoulliParallel pStar genCalc
                    (!newPrice, newGen) = if b == 1
                                          then (price * u, genNext)
                                          else (price * d, genNext)
                in calcPrice (i + 1) t pStar u d (sumPrices + newPrice) newPrice newGen

-- Helper function to generate a Bernoulli trial result given a probability and a generator
bernoulliParallel :: Double -> SMGen -> (Int, SMGen)
bernoulliParallel p gen = let (!randomVal, gen') = nextDouble gen
                          in (if randomVal < p then 1 else 0, gen')

-- Main function for vectors in parallel
monteCarloAsianParallelVector :: Int -> Int -> Int -> Double -> Double -> Double -> Double -> Double -> SMGen -> Double
monteCarloAsianParallelVector numCores n t r u d s0 k init_gen =
  let !discount = 1 / ((1 + r) ** fromIntegral t)
      !pStar = (1 + r - d) / (u - d)
      chunkSize = n `div` (10 * numCores)
      gens = unfoldsSMGen init_gen n
      trials = withStrategy (parListChunk chunkSize rdeepseq) $
               map (runEval . vectorTrial pStar u d s0 k t) gens
      !result = sum trials * discount / fromIntegral n
  in result

-- Helper function to complete a single vector trial
vectorTrial :: Double -> Double -> Double -> Double -> Double -> Int -> SMGen -> Eval Double
vectorTrial pStar u d s0 k t gen = do
  let steps = V.unfoldrN t (unfoldBernoulli pStar) gen
      priceVector = V.scanl' (\price step -> price * (if step == 1 then u else d)) s0 steps
      sumPrices = V.sum priceVector - V.head priceVector
      avgPrice = sumPrices / fromIntegral t
      diffVal = avgPrice - k
  return $ max diffVal 0

-- Helper function to generate the bernoullis
unfoldBernoulli :: Double -> SMGen -> Maybe (Int, SMGen)
unfoldBernoulli p gen = Just $ bernoulliParallel p gen
-- Parallel Content Ends --

-- General All purpose helper functions below -- 
-- Helper function to validate the provided inputs from the user
validateInputs :: Int -> Int -> Double -> Double -> Double -> Double -> Double -> IO ()
validateInputs n t r u d s0 k = do
  when (n <= 0) $ error "Invalid value for n. Number of trials (n) must be greater than 0."
  when (t < 1) $ error "Invalid value for t. Number of time steps (t) must be greater than or equal to 1."
  when (r <= 0) $ error "Invalid value for r. The interest rate (r) must be greater than 0."
  when (u <= 0) $ error "Invalid value for u. The up factor (u) must be greater than 0."
  when (d <= 0) $ error "Invalid value for d. The down factor (d) must be greater than 0."
  when (s0 <= 0) $ error "Invalid value for s0. Initial stock price (s0) must be greater than 0."
  when (k <= 0) $ error "Invalid value for k. Strike price (k) must be greater than 0."
  unless (0 < d && d < 1 + r && 1 + r < u) $
    error "Invalid values for r, u, and d entered.\nThe relationship 0 < d < r < u must be maintained to get valid results."