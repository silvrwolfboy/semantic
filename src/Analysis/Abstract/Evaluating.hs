{-# LANGUAGE DataKinds, GADTs, GeneralizedNewtypeDeriving, MultiParamTypeClasses, Rank2Types, ScopedTypeVariables,
             StandaloneDeriving, TypeApplications, TypeFamilies, TypeOperators, UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Analysis.Abstract.Evaluating
( type Evaluating
, evaluate
, evaluates
, require
, load
) where

import           Control.Abstract.Evaluator
import           Control.Monad.Effect
import           Control.Monad.Effect.Internal
import           Data.Abstract.Configuration
import           Data.Abstract.Environment (Environment)
import qualified Data.Abstract.Environment as Env
import           Data.Abstract.Evaluatable
import           Data.Abstract.Exports (Exports)
import qualified Data.Abstract.Exports as Export
import           Data.Abstract.ModuleTable
import           Data.Abstract.Value
import           Data.Blob
import qualified Data.ByteString.Char8 as BC
import qualified Data.IntMap as IntMap
import           Data.Language
import           Data.List.Split (splitWhen)
import qualified Data.Map as Map
import           Prelude hiding (fail)
import           Prologue hiding (throwError)
import           System.FilePath.Posix

-- | Evaluate a term to a value.
evaluate :: forall value term effects
         .  ( effects ~ RequiredEffects term value (Evaluating term value effects)
            , Evaluatable (Base term)
            , FreeVariables term
            , MonadAddressable (LocationFor value) value (Evaluating term value effects)
            , MonadValue value (Evaluating term value effects)
            , Recursive term
            , Show (LocationFor value)
            )
         => term
         -> Final effects value
evaluate = runAnalysis @(Evaluating term value) . evaluateModule

-- | Evaluate terms and an entry point to a value.
evaluates :: forall value term effects
          .  ( effects ~ RequiredEffects term value (Evaluating term value effects)
             , Evaluatable (Base term)
             , FreeVariables term
             , MonadAddressable (LocationFor value) value (Evaluating term value effects)
             , MonadValue value (Evaluating term value effects)
             , Recursive term
             , Show (LocationFor value)
             )
          => [(Blob, term)] -- List of (blob, term) pairs that make up the program to be evaluated
          -> (Blob, term)   -- Entrypoint
          -> Final effects value
evaluates pairs (b, t) = runAnalysis @(Evaluating term value) (withModules b pairs (evaluateModule t))

-- | Run an action with the passed ('Blob', @term@) pairs available for imports.
withModules :: MonadAnalysis term value m => Blob -> [(Blob, term)] -> m a -> m a
withModules Blob{..} pairs = localModuleTable (const moduleTable)
  where
    moduleTable = ModuleTable (Map.fromListWith (<>) (map (bimap moduleName pure) pairs))
    rootDir = dropFileName blobPath
    moduleName Blob{..} = let path = dropExtensions (makeRelative rootDir blobPath)
     in case blobLanguage of
      -- TODO: Need a better way to handle module registration and resolution
      Just Go -> toName (takeDirectory path) -- Go allows defining modules across multiple files in the same directory.
      _       ->  toName path
    toName str = qualifiedName (fmap BC.pack (splitWhen (== pathSeparator) str))

-- | Require/import another module by name and return it's environment and value.
--
-- Looks up the term's name in the cache of evaluated modules first, returns if found, otherwise loads/evaluates the module.
require :: (MonadAnalysis term value m, MonadValue value m)
        => ModuleName
        -> m (EnvironmentFor value, value)
require name = getModuleTable >>= maybe (load name) pure . moduleTableLookup name

-- | Load another module by name and return it's environment and value.
--
-- Always loads/evaluates.
load :: (MonadAnalysis term value m, MonadValue value m)
     => ModuleName
     -> m (EnvironmentFor value, value)
load name = askModuleTable >>= maybe notFound evalAndCache . moduleTableLookup name
  where
    notFound = fail ("cannot load module: " <> show name)
    evalAndCache :: (MonadAnalysis term value m, MonadValue value m) => [term] -> m (EnvironmentFor value, value)
    evalAndCache []     = (,) <$> pure mempty <*> unit
    evalAndCache [x]    = evalAndCache' x
    evalAndCache (x:xs) = do
      (env, _) <- evalAndCache' x
      (env', v') <- evalAndCache xs
      pure (env <> env', v')

    evalAndCache' :: (MonadAnalysis term value m) => term -> m (EnvironmentFor value, value)
    evalAndCache' x = do
      v <- evaluateModule x
      env <- filterEnv <$> getExports <*> getEnv
      modifyModuleTable (moduleTableInsert name (env, v))
      pure (env, v)

    -- TODO: If the set of exports is empty because no exports have been
    -- defined, do we export all terms, or no terms? This behavior varies across
    -- languages. We need better semantics rather than doing it ad-hoc.
    filterEnv :: Exports l a -> Environment l a -> Environment l a
    filterEnv ports env
      | Export.null ports = env
      | otherwise = Export.toEnvironment ports <> Env.overwrite (Export.aliases ports) env

-- | An analysis evaluating @term@s to @value@s with a list of @effects@ using 'Evaluatable', and producing incremental results of type @a@.
newtype Evaluating term value effects a = Evaluating (Eff effects a)
  deriving (Applicative, Functor, Effectful, Monad)

deriving instance Member Fail      effects => MonadFail   (Evaluating term value effects)
deriving instance Member Fresh     effects => MonadFresh  (Evaluating term value effects)
deriving instance Member NonDet    effects => Alternative (Evaluating term value effects)
deriving instance Member NonDet    effects => MonadNonDet (Evaluating term value effects)

-- | Effects necessary for evaluating (whether concrete or abstract).
type EvaluatingEffects term value
  = '[
       Resumable1 ValueExc
     , Resumable1 (Unspecialized value)
     , Fail                                        -- Failure with an error message
     , State  (EnvironmentFor value)               -- Environments (both local and global)
     , State  (HeapFor value)                      -- The heap
     , Reader (ModuleTable [term])                 -- Cache of unevaluated modules
     , State  (ModuleTable (EnvironmentFor value, value)) -- Cache of evaluated modules
     , State  (ExportsFor value)                   -- Exports (used to filter environments when they are imported)
     , State  (IntMap.IntMap term)                 -- For jumps
     ]


data Resumable1 (exc :: * -> *) a where
  Resumable1 :: exc v -> Resumable1 exc v

throwError1 :: forall exc v e. (Resumable1 exc :< e) => exc v -> Eff e v
throwError1 e = send (Resumable1 e :: Resumable1 exc v)

runError1 :: Eff (Resumable1 exc ': e) a -> Eff e (Either (SomeExc exc) a)
runError1 = relay (pure . Right) (\ (Resumable1 e) _k -> pure (Left (SomeExc e)))

resumeError1 :: forall exc e a. (Resumable1 exc :< e) =>
       Eff e a -> (forall v. Arrow e v a -> exc v -> Eff e a) -> Eff e a
resumeError1 m handle = interpose @(Resumable1 exc) pure (\(Resumable1 e) yield -> handle yield e) m

-- catchError1 :: forall exc e a. (Resumable1 exc :< e) => Eff e a -> (forall v. exc v -> Eff e a) -> Eff e a
-- catchError1 m handle = resumeError1 m (const handle)

resumeException :: forall exc m e a. (Effectful m, Resumable1 exc :< e) => m e a -> (forall v. (v -> m e a) -> exc v -> m e a) -> m e a
resumeException m handle = raise (resumeError1 (lower m) (\yield -> lower . handle (raise . yield)))


data SomeExc exc where
  SomeExc :: exc v -> SomeExc exc

instance Eq1 exc => Eq (SomeExc exc) where
  SomeExc exc1 == SomeExc exc2 = liftEq (const (const True)) exc1 exc2

instance (Show1 exc) => Show (SomeExc exc) where
  showsPrec num (SomeExc exc) = liftShowsPrec (const (const id)) (const id) num exc

-- | 'Resumable' effects are interpreted into 'Either' s.t. failures are in 'Left' and successful results are in 'Right'.
instance RunEffect (Resumable1 exc) a where
  type Result (Resumable1 exc) a = Either (SomeExc exc) a
  runEffect = runError1


instance (Monad (m effects), Effectful m, Members '[Resumable1 exc] effects) => MonadThrow exc (m effects) where
   throwException = raise . throwError1

instance Members '[Fail, State (IntMap.IntMap term)] effects => MonadControl term (Evaluating term value effects) where
  label term = do
    m <- raise get
    let i = IntMap.size m
    raise (put (IntMap.insert i term m))
    pure i

  goto label = IntMap.lookup label <$> raise get >>= maybe (fail ("unknown label: " <> show label)) pure

instance Members '[State (ExportsFor value), State (EnvironmentFor value)] effects => MonadEnvironment value (Evaluating term value effects) where
  getEnv = raise get
  putEnv = raise . put
  withEnv s = raise . localState s . lower

  getExports = raise get
  putExports = raise . put
  withExports s = raise . localState s . lower

  localEnv f a = do
    modifyEnv (f . Env.push)
    result <- a
    result <$ modifyEnv Env.pop

instance Member (State (HeapFor value)) effects => MonadHeap value (Evaluating term value effects) where
  getHeap = raise get
  putHeap = raise . put

instance Members '[Reader (ModuleTable [term]), State (ModuleTable (EnvironmentFor value, value))] effects => MonadModuleTable term value (Evaluating term value effects) where
  getModuleTable = raise get
  putModuleTable = raise . put

  askModuleTable = raise ask
  localModuleTable f a = raise (local f (lower a))

instance Members (EvaluatingEffects term value) effects => MonadEvaluator term value (Evaluating term value effects) where
  getConfiguration term = Configuration term mempty <$> getEnv <*> getHeap

instance ( Evaluatable (Base term)
         , FreeVariables term
         , Members (EvaluatingEffects term value) effects
         , MonadAddressable (LocationFor value) value (Evaluating term value effects)
         , MonadValue value (Evaluating term value effects)
         , Recursive term
         , Show (LocationFor value)
         )
         => MonadAnalysis term value (Evaluating term value effects) where
  type RequiredEffects term value (Evaluating term value effects) = EvaluatingEffects term value

  analyzeTerm term = resumeException @(Unspecialized value) (eval term) (\yield (Unspecialized str) -> string (BC.pack str) >>= yield)
