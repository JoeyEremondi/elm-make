{-# LANGUAGE FlexibleContexts #-}
module Build where

import Control.Concurrent (ThreadId, myThreadId, forkIO)
import qualified Control.Concurrent.Chan as Chan
import qualified Data.List as List
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set

import qualified Elm.Compiler as Compiler
import qualified Elm.Compiler.Module as Module
import qualified Elm.Docs as Docs
import qualified Elm.Package.Name as Pkg
import qualified Path
import qualified Report
import qualified Utils.File as File
import qualified Utils.Queue as Queue
import qualified TheMasterPlan as TMP
import TheMasterPlan
    ( ModuleID, Location, PackageID
    , BuildSummary(BuildSummary), BuildData(..)
    )


data Env = Env
    { maxActiveThreads :: Int
    , numTasks :: Int
    , resultChan :: Chan.Chan Result
    , reportChan :: Chan.Chan Report.Message
    , docsChan :: Chan.Chan [Docs.Documentation]
    , reverseDependencies :: Map.Map ModuleID [ModuleID]
    , cachePath :: FilePath
    , exposedModules :: Set.Set ModuleID
    , modulesForGeneration :: Set.Set ModuleID
    }


data State = State
    { currentState :: CurrentState
    , activeThreads :: Set.Set ThreadId
    , readyQueue :: Queue.Queue (ModuleID, Location)
    , blockedModules :: Map.Map ModuleID BuildData
    , completedInterfaces :: Map.Map ModuleID Module.Interface
    , documentation :: [Docs.Documentation]
    }


data CurrentState = Wait | Update


-- HELPERS for ENV and STATE

initEnv
    :: Int
    -> FilePath
    -> Set.Set ModuleID
    -> [ModuleID]
    -> Map.Map ModuleID [ModuleID]
    -> BuildSummary
    -> IO Env
initEnv numProcessors cachePath exposedModules modulesForGeneration dependencies (BuildSummary blocked _completed) =
  do  resultChan <- Chan.newChan
      reportChan <- Chan.newChan
      docsChan <- Chan.newChan
      return $ Env
        { maxActiveThreads = numProcessors
        , numTasks = Map.size blocked
        , resultChan = resultChan
        , reportChan = reportChan
        , docsChan = docsChan
        , reverseDependencies = reverseGraph dependencies
        , cachePath = cachePath
        , exposedModules = exposedModules
        , modulesForGeneration = Set.fromList modulesForGeneration
        }


-- reverse dependencies, "who depends on me?"
reverseGraph :: (Ord a) => Map.Map a [a] -> Map.Map a [a]
reverseGraph graph =
    Map.foldrWithKey flipEdges Map.empty graph
  where
    flipEdges name dependencies reversedGraph =
        foldr (insertDependency name) reversedGraph dependencies

    insertDependency name dep reversedGraph =
        Map.insertWith (++) dep [name] reversedGraph


initState :: BuildSummary -> State
initState (BuildSummary blocked completed) =
    State
      { currentState = Update
      , activeThreads = Set.empty
      , readyQueue = Queue.fromList (Map.elems readyModules)
      , blockedModules = blockedModules
      , completedInterfaces = completed
      , documentation = []
      }
  where
    (readyModules, blockedModules) =
        Map.mapEitherWithKey categorize blocked

    categorize name buildData@(BuildData blocking location) =
        case blocking of
          [] -> Left (name, location)
          _  -> Right buildData


numIncompleteTasks :: State -> Int
numIncompleteTasks state =
    Set.size (activeThreads state)
    + Queue.size (readyQueue state)


-- PARALLEL BUILDS!!!

build
    :: Report.Type
    -> Bool
    -> Int
    -> PackageID
    -> FilePath
    -> Set.Set ModuleID
    -> [ModuleID]
    -> Map.Map ModuleID [ModuleID]
    -> BuildSummary
    -> IO [Docs.Documentation]
build reportType warn numProcessors rootPkg cachePath exposedModules modulesForGeneration dependencies summary =
  do  env <- initEnv numProcessors cachePath exposedModules modulesForGeneration dependencies summary
      forkIO (buildManager env (initState summary))
      Report.thread reportType warn (reportChan env) rootPkg (numTasks env)
      Chan.readChan (docsChan env)


buildManager :: Env -> State -> IO ()
buildManager env state =
  case currentState state of
    _ | numIncompleteTasks state == 0 ->
      do  Chan.writeChan (reportChan env) Report.Close
          Chan.writeChan (docsChan env) (documentation state)

    Wait ->
      do  (Result source path moduleID threadId dealiaser warnings result) <-
              Chan.readChan (resultChan env)

          if null warnings
            then return ()
            else
              Chan.writeChan (reportChan env)
                  (Report.Warn moduleID dealiaser path source warnings)

          case result of
            Right (Compiler.Result maybeDocs interface js) ->
              do  let cache = cachePath env
                  File.writeBinary (Path.toInterface cache moduleID) interface
                  writeFile (Path.toObjectFile cache moduleID) (show js)
                  Chan.writeChan (reportChan env) (Report.Complete moduleID)
                  buildManager env (registerSuccess env state moduleID interface maybeDocs threadId)

            Left errors ->
              do  Chan.writeChan (reportChan env) (Report.Error moduleID dealiaser path source errors)
                  buildManager env (registerFailure state threadId)

    Update ->
      do  let interfaces = completedInterfaces state
          let compile = buildModule env interfaces
          threadIds <- mapM (forkIO . compile) runNow
          buildManager env $
              state
              { currentState = Wait
              , activeThreads = foldr Set.insert (activeThreads state) threadIds
              , readyQueue = runLater
              }
      where
        (runNow, runLater) =
            Queue.dequeue
                (maxActiveThreads env - Set.size (activeThreads state))
                (readyQueue state)


-- WAIT - REGISTER RESULTS

registerFailure :: State -> ThreadId -> State
registerFailure state threadId =
  state
    { currentState = Update
    , activeThreads = Set.delete threadId (activeThreads state)
    }


registerSuccess
    :: Env
    -> State
    -> ModuleID
    -> Module.Interface
    -> Maybe Docs.Documentation
    -> ThreadId
    -> State
registerSuccess env state name interface maybeDocs threadId =
  let
    (updatedBlockedModules, readyModules) =
      List.mapAccumR
          (updateBlockedModules name interface)
          (blockedModules state)
          (Maybe.fromMaybe [] (Map.lookup name (reverseDependencies env)))

    newReadyQueue =
      Queue.enqueue (Maybe.catMaybes readyModules) (readyQueue state)

    newCompletedInterfaces =
      Map.insert name interface (completedInterfaces state)
  in
    state
      { currentState = Update
      , activeThreads = Set.delete threadId (activeThreads state)
      , blockedModules = updatedBlockedModules
      , readyQueue = newReadyQueue
      , completedInterfaces = newCompletedInterfaces
      , documentation = maybe id (:) maybeDocs (documentation state)
      }


updateBlockedModules
    :: ModuleID
    -> Module.Interface
    -> Map.Map ModuleID BuildData
    -> ModuleID
    -> (Map.Map ModuleID BuildData, Maybe (ModuleID, Location))
updateBlockedModules name interface blockedModules potentiallyFreedModule =
  case Map.lookup potentiallyFreedModule blockedModules of
    Nothing ->
        (blockedModules, Nothing)

    Just (BuildData blocking location) ->
          case filter (/= name) blocking of
          [] ->
              ( Map.delete potentiallyFreedModule blockedModules
              , Just (potentiallyFreedModule, location)
              )

          newBlocking ->
              ( Map.insert
                  potentiallyFreedModule
                  (BuildData newBlocking location)
                  blockedModules
              , Nothing
              )


-- UPDATE - BUILD SOME MODULES

buildModule
    :: Env
    -> Map.Map ModuleID Module.Interface
    -> (ModuleID, Location)
    -> IO ()
buildModule env interfaces (moduleID, location) =
  let
    (Pkg.Name user project) = fst (TMP.packageID moduleID)
    path = Path.toSource location
    ifaces = Map.mapKeysMonotonic TMP.moduleName interfaces
    isRoot = Set.member moduleID (modulesForGeneration env)
    isExposed = Set.member moduleID (exposedModules env)
  in
  do  source <- readFile path

      let context =
            Compiler.Context user project isRoot isExposed

      let (dealiaser, warnings, rawResult) =
            Compiler.compile context source ifaces

      threadId <- myThreadId
      let result =
            Result source path moduleID threadId dealiaser warnings rawResult

      Chan.writeChan (resultChan env) result


data Result = Result
    { _source :: String
    , _path :: FilePath
    , _moduleID :: ModuleID
    , _threadId :: ThreadId
    , _dealiaser :: Compiler.Dealiaser
    , _warnings :: [Compiler.Warning]
    , _result :: Either [Compiler.Error] Compiler.Result
    }
