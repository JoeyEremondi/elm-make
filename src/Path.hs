module Path (toInterface, toObjectFile, toPackageCacheFile, toSource) where

import qualified Data.List as List
import System.FilePath ((</>), (<.>))

import Elm.Compiler.Module as Module
import Elm.Package as Pkg
import qualified TheMasterPlan as TMP


toInterface :: FilePath -> Module.CanonicalName -> FilePath
toInterface root (Module.CanonicalName pnm pvr (Module.Name names)) =
    root </> inPackage (pnm, pvr) (List.intercalate "-" names <.> "elmi")


toObjectFile :: FilePath -> Module.CanonicalName -> FilePath
toObjectFile root (Module.CanonicalName pnm pvr (Module.Name names)) =
    root </> inPackage (pnm, pvr) (List.intercalate "-" names <.> "elmo")


toPackageCacheFile :: FilePath -> Pkg.Package -> FilePath
toPackageCacheFile root pkg =
    root </> inPackage pkg "graph.dat"


toSource :: TMP.Location -> FilePath
toSource (TMP.Location relativePath _package) =
    relativePath


inPackage :: Pkg.Package -> FilePath -> FilePath
inPackage (name, version) relativePath =
    Pkg.toFilePath name </> Pkg.versionToString version </> relativePath
