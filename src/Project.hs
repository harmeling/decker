{-- Author: Henrik Tramberend <henrik@tramberend.de> --}
module Project
  ( findFile
  -- , readResource
  , resourcePathes
  , copyResource
  , linkResource
  , relRefResource
  , absRefResource
  , removeCommonPrefix
  , isPrefix
  , makeRelativeTo
  , findProjectDirectory
  , projectDirectories
  , resolveLocally
  , provisioningFromMeta
  , provisioningFromClasses
  , Resource(..)
  , Provisioning(..)
  , ProjectDirs(..)
  ) where

import Common
import Control.Exception
import Control.Monad
import Data.Maybe
import Extra
import Network.URI
import qualified System.Directory as D
import System.FilePath
import System.Posix.Files
import Text.Pandoc.Definition
import Text.Pandoc.Shared

data Provisioning
  = Copy -- Copy to public and relative URL
  | SymLink -- Symbolic link to public and relative URL
  | Absolute -- Absolute local URL
  | Relative -- Relative local URL
  deriving (Eq, Show, Read)

provisioningFromMeta :: Meta -> Provisioning
provisioningFromMeta meta =
  case lookupMeta "provisioning" meta of
    Just (MetaString s) -> read s
    Just (MetaInlines i) -> read $ stringify i
    _ -> SymLink

provisioningClasses :: [(String, Provisioning)]
provisioningClasses =
  [ ("copy", Copy)
  , ("symlink", SymLink)
  , ("absolute", Absolute)
  , ("relative", Relative)
  ]

provisioningFromClasses :: Provisioning -> [String] -> Provisioning
provisioningFromClasses defaultP cls =
  fromMaybe defaultP $
  listToMaybe $ map snd $ filter (flip elem cls . fst) provisioningClasses

data Resource = Resource
  { sourceFile :: FilePath -- Absolute Path to source file
  , publicFile :: FilePath -- Absolute path to file in public folder
  , publicUrl :: FilePath -- Relative URL to served file from base
  } deriving (Eq, Show)

copyResource :: Resource -> IO FilePath
copyResource resource = do
  copyFileIfNewer (sourceFile resource) (publicFile resource)
  return (publicUrl resource)

linkResource :: Resource -> IO FilePath
linkResource resource = do
  whenM
    (D.doesFileExist (publicFile resource))
    (D.removeFile (publicFile resource))
  D.createDirectoryIfMissing True (takeDirectory (publicFile resource))
  createSymbolicLink (sourceFile resource) (publicFile resource)
  return (publicUrl resource)

absRefResource :: Resource -> IO FilePath
absRefResource resource =
  return $ show $ URI "file" Nothing (sourceFile resource) "" ""

relRefResource :: FilePath -> Resource -> IO FilePath
relRefResource base resource = do
  let relPath = makeRelativeTo base (sourceFile resource)
  return $ show $ URI "file" Nothing relPath "" ""

data ProjectDirs = ProjectDirs
  { project :: FilePath
  , public :: FilePath
  , cache :: FilePath
  , support :: FilePath
  , appData :: FilePath
  , log :: FilePath
  } deriving (Eq, Show)

-- Find the project directory.  
-- The project directory is the first upwards directory that contains a .git directory entry.
findProjectDirectory :: IO FilePath
findProjectDirectory = do
  cwd <- D.getCurrentDirectory
  searchGitRoot cwd
  where
    searchGitRoot :: FilePath -> IO FilePath
    searchGitRoot path =
      if isDrive path
        then D.makeAbsolute "."
        else do
          hasGit <- D.doesDirectoryExist (path </> ".git")
          if hasGit
            then D.makeAbsolute path
            else searchGitRoot $ takeDirectory path

-- Calculate important absolute project directory pathes
projectDirectories :: IO ProjectDirs
projectDirectories = do
  projectDir <- findProjectDirectory
  let publicDir = projectDir </> "public"
  let cacheDir = publicDir </> "cache"
  let supportDir = publicDir </> ("support" ++ "-" ++ deckerVersion)
  appDataDir <- D.getXdgDirectory D.XdgData ("decker" ++ "-" ++ deckerVersion)
  let logDir = projectDir </> "log"
  return
    (ProjectDirs projectDir publicDir cacheDir supportDir appDataDir logDir)

-- Resolves a file path to a concrete verified file system path, or
-- returns Nothing if no file can be found.
resolveLocally :: ProjectDirs -> FilePath -> FilePath -> IO (Maybe FilePath)
resolveLocally dirs base path = do
  absBase <- D.makeAbsolute base
  let absRoot = project dirs
  let candidates =
        if isAbsolute path
          then [absRoot </> makeRelative "/" path, path]
          else [absBase </> path, absRoot </> path]
  listToMaybe <$> filterM D.doesFileExist candidates

resourcePathes :: ProjectDirs -> FilePath -> URI -> Resource
resourcePathes dirs base uri =
  Resource
  { sourceFile = uriPath uri
  , publicFile = public dirs </> makeRelativeTo (project dirs) (uriPath uri)
  , publicUrl =
      show $
      URI
        ""
        Nothing
        (makeRelativeTo base (uriPath uri))
        (uriQuery uri)
        (uriFragment uri)
  }

isLocalURI :: String -> Bool
isLocalURI url = isNothing (parseURI url)

isRemoteURI :: String -> Bool
isRemoteURI = not . isLocalURI

-- Finds local file system files that sre needed at compile time. 
-- Throws if the resource cannot be found. Used mainly for include files.
findFile :: ProjectDirs -> FilePath -> FilePath -> IO FilePath
findFile dirs base path = do
  resolved <- resolveLocally dirs base path
  case resolved of
    Nothing ->
      throw $
      ResourceException $ "Cannot find local file system resource: " ++ path
    Just resource -> return resource

-- Finds local file system files that are needed at compile time. 
-- Returns the original path if the resource cannot be found.
maybeFindFile :: ProjectDirs -> FilePath -> FilePath -> IO FilePath
maybeFindFile dirs base path = do
  resolved <- resolveLocally dirs base path
  case resolved of
    Nothing -> return path
    Just resource -> return resource
      -- case find (\(k, b) -> k == path) deckerTemplateDir of
      --   Nothing ->
      --     throw $ ResourceException $ "Cannot find built-in resource: " ++ path
      --   Just entry -> return $ snd entry

-- Finds and reads a resource at compile time. If the resource can not be found in the
-- file system, the built-in resource map is searched. If that fails, an error is thrown.
-- The resource is searched for in a directory named `template`.
-- readResource ::
--      ProjectDirs -> FilePath -> FilePath -> IO String
-- readResource dirs base path = do
--   let searchPath = "template" </> path
--   resolved <- resolveLocally dirs base path
--   case resolved of
--     Just resource -> readFile resource
--     Nothing -> return $ getResourceString resources searchPath
-- | Copies the src to dst if src is newer or dst does not exist. Creates
-- missing directories while doing so.
copyFileIfNewer :: FilePath -> FilePath -> IO ()
copyFileIfNewer src dst =
  whenM (fileIsNewer src dst) $ do
    D.createDirectoryIfMissing True (takeDirectory dst)
    D.copyFile src dst

fileIsNewer a b = do
  aexists <- D.doesFileExist a
  bexists <- D.doesFileExist b
  if bexists
    then if aexists
           then do
             at <- D.getModificationTime a
             bt <- D.getModificationTime b
             return (at > bt)
           else return False
    else return aexists

-- | Express the second path argument as relative to the first. 
-- Both arguments are expected to be absolute pathes. 
makeRelativeTo :: FilePath -> FilePath -> FilePath
makeRelativeTo dir file =
  let (d, f) = removeCommonPrefix (dir, file)
  in normalise $ invertPath d </> f

invertPath :: FilePath -> FilePath
invertPath fp = joinPath $ map (const "..") $ filter ("." /=) $ splitPath fp

removeCommonPrefix :: (FilePath, FilePath) -> (FilePath, FilePath)
removeCommonPrefix =
  mapTuple joinPath . removeCommonPrefix_ . mapTuple splitDirectories
  where
    removeCommonPrefix_ :: ([FilePath], [FilePath]) -> ([FilePath], [FilePath])
    removeCommonPrefix_ (al@(a:as), bl@(b:bs))
      | a == b = removeCommonPrefix_ (as, bs)
      | otherwise = (al, bl)
    removeCommonPrefix_ pathes = pathes

isPrefix :: FilePath -> FilePath -> Bool
isPrefix a b = isPrefix_ (splitPath a) (splitPath b)
  where
    isPrefix_ :: Eq a => [a] -> [a] -> Bool
    isPrefix_ al@(a:as) bl@(b:bs)
      | a == b = isPrefix_ as bs
      | otherwise = False
    isPrefix_ [] _ = True
    isPrefix_ _ _ = False

mapTuple f (a, b) = (f a, f b)