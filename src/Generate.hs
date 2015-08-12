{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
module Generate where

import Control.Monad.Except (MonadError, MonadIO, forM_, forM, liftIO, throwError)
import qualified Data.Graph as Graph
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import qualified Data.Text.Lazy as LazyText
import qualified Data.Text.Lazy.Encoding as LazyText
import qualified Data.Text.Lazy.IO as LazyText
import qualified Data.Tree as Tree
import System.Directory ( createDirectoryIfMissing )
import System.FilePath ( dropFileName, takeExtension )
import System.IO ( IOMode(WriteMode) )
import qualified Text.Blaze as Blaze
import Text.Blaze.Html5 ((!))
import qualified Text.Blaze.Html5 as H
import qualified Text.Blaze.Html5.Attributes as A
import qualified Text.Blaze.Renderer.Text as Blaze

import Elm.Utils ((|>))
import qualified Elm.Compiler.Module as Module
import qualified Elm.Compiler as Compiler
import qualified Elm.Docs as Docs
import qualified Path
import TheMasterPlan ( ModuleID(ModuleID), Location )
import qualified Utils.File as File


-- GENERATE DOCS

docs :: (MonadIO m) => [Docs.Documentation] -> FilePath -> m ()
docs docsList path =
  Docs.prettyJson docsList
    |> LazyText.decodeUtf8
    |> LazyText.replace "\\u003e" ">"
    |> LazyText.writeFile path
    |> liftIO


-- GENERATE ELM STUFF

generate
    :: (MonadIO m, MonadError String m)
    => FilePath
    -> Map.Map ModuleID [ModuleID]
    -> Map.Map ModuleID Location
    -> [ModuleID]
    -> [Module.Interface]
    -> FilePath
    -> m ()

generate _cachePath _dependencies _natives [] _targetNames _outputFile =
  return ()

generate cachePath dependencies natives moduleIDs targetNames outputFile =
  do  let objectFiles =
            setupNodes cachePath dependencies natives
              |> getReachableObjectFiles moduleIDs

      liftIO (createDirectoryIfMissing True (dropFileName outputFile))

      case takeExtension outputFile of
        ".html" ->
          case moduleIDs of
            [ModuleID moduleName _] ->
              liftIO $
                do  js <- combineObjects objectFiles
                    let outputText = html (Text.concat ([header, js])) moduleName
                    LazyText.writeFile outputFile outputText

            _ ->
              throwError (errorNotOneModule moduleIDs)

        _ ->
          liftIO $
          File.withFileUtf8 outputFile WriteMode $ \handle ->
              do  Text.hPutStrLn handle header
                  objJS <- combineObjects objectFiles
                  Text.hPutStrLn handle objJS

      liftIO (putStrLn ("Successfully generated " ++ outputFile))


combineObjects :: [String] -> IO Text.Text
combineObjects objectFiles =
  fmap Text.concat $ forM objectFiles $ \jsFile ->
    do  objText <- readFile jsFile
        return $ (objToJS . read ) objText
        

objToJS :: Compiler.Object -> Text.Text
objToJS obj =
  Text.concat
  [ Compiler._topHeader obj
  , Text.pack "function(_elm){\n"
  , Compiler._fnHeader obj
  , Text.concat $ map snd $ Compiler._fnDefs obj
  , Compiler._fnFooter obj
  , Text.pack "};"
  ]


header :: Text.Text
header =
    "var Elm = Elm || { Native: {} };"


errorNotOneModule :: [ModuleID] -> String
errorNotOneModule names =
    unlines
    [ "You have specified an HTML output file, so elm-make is attempting to\n"
    , "generate a fullscreen Elm program as HTML. To do this, elm-make must get\n"
    , "exactly one input file, but you have given " ++ show (length names) ++ "."
    ]


setupNodes
    :: FilePath
    -> Map.Map ModuleID [ModuleID]
    -> Map.Map ModuleID Location
    -> [(FilePath, ModuleID, [ModuleID])]
setupNodes cachePath dependencies natives =
    let nativeNodes =
            Map.toList natives
              |> map (\(name, loc) -> (Path.toSource loc, name, []))

        dependencyNodes =
            Map.toList dependencies
              |> map (\(name, deps) -> (Path.toObjectFile cachePath name, name, deps))
    in
        nativeNodes ++ dependencyNodes


getReachableObjectFiles
    :: [ModuleID]
    -> [(FilePath, ModuleID, [ModuleID])]
    -> [FilePath]
getReachableObjectFiles moduleNames nodes =
    let (dependencyGraph, vertexToKey, keyToVertex) =
            Graph.graphFromEdges nodes
    in
        Maybe.mapMaybe keyToVertex moduleNames
          |> Graph.dfs dependencyGraph
          |> concatMap Tree.flatten
          |> Set.fromList
          |> Set.toList
          |> map vertexToKey
          |> map (\(path, _, _) -> path)


-- GENERATE HTML

html :: Text.Text -> Module.Name -> LazyText.Text
html generatedJavaScript moduleName =
  Blaze.renderMarkup $
    H.docTypeHtml $ do
      H.head $ do
        H.meta ! A.charset "UTF-8"
        H.title (H.toHtml (Module.nameToString moduleName))
        H.style $ Blaze.preEscapedToMarkup
            ("html,head,body { padding:0; margin:0; }\n\
             \body { font-family: calibri, helvetica, arial, sans-serif; }" :: Text.Text)
        H.script ! A.type_ "text/javascript" $
            Blaze.preEscapedToMarkup generatedJavaScript
      H.body $ do
        H.script ! A.type_ "text/javascript" $
            Blaze.preEscapedToMarkup ("Elm.fullscreen(Elm." ++ Module.nameToString moduleName ++ ")")
