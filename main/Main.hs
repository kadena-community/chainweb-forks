{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module: Main
-- Copyright: Copyright © 2019, Lars Kuhtz <lakuhtz@gmail.com>
-- License: MIT
-- Maintainer: Lars Kuhtz <lakuhtz@gmail.com>
-- Stability: experimental
--
module Main
( main
) where

import Configuration.Utils

import Control.Lens hiding ((.=))
import Control.Monad
import Control.Monad.Catch
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Retry

import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy.Char8 as BL8
import qualified Data.CaseInsensitive as CI
import Data.Functor.Of
import qualified Data.HashMap.Strict as HM
import qualified Data.HashSet as HS
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.IO as T
import Data.These

import GHC.Generics hiding (from)

import Network.HTTP.Client

import Servant.Client

import qualified Streaming.Prelude as S

import qualified System.Logger as Y
import System.LogLevel

-- internal modules

import Chainweb.BlockHeader
import Chainweb.Cut.CutHashes
import Chainweb.CutDB.RestAPI.Client
import Chainweb.HostAddress
import Chainweb.Logger
import Chainweb.TreeDB
import Chainweb.TreeDB.RemoteDB
import Chainweb.Utils
import Chainweb.Version

import Data.LogMessage

-- -------------------------------------------------------------------------- --
--

data Format = FormatJson | FormatText | FormatShort
    deriving (Show, Eq, Ord, Bounded, Enum)

instance ToJSON Format where
    toJSON = toJSON . toText

instance FromJSON Format where
    parseJSON = parseJsonFromText "Format"

instance HasTextRepresentation Format where
    toText FormatJson = "json"
    toText FormatText = "text"
    toText FormatShort = "short"

    fromText x = case CI.mk x of
        "json" -> pure FormatJson
        "text" -> pure FormatText
        "short" -> pure FormatShort
        e -> throwM $ TextFormatException $ "unknown format: " <> sshow e

data Config = Config
    { _configLogHandle :: !Y.LoggerHandleConfig
    , _configLogLevel :: !Y.LogLevel
    , _configChainwebVersion :: !ChainwebVersion
    , _configNodes :: ![HostAddress]
    , _configFormat :: !Format
    }
    deriving (Show, Eq, Ord, Generic)

makeLenses ''Config

defaultNodes :: [HostAddress]
defaultNodes = []

defaultConfig :: Config
defaultConfig = Config
    { _configLogHandle = Y.StdOut
    , _configLogLevel = Y.Info
    , _configChainwebVersion = Mainnet01
    , _configNodes = defaultNodes
    , _configFormat = FormatShort
    }

instance ToJSON Config where
    toJSON o = object
        [ "logHandle" .= _configLogHandle o
        , "logLevel" .= _configLogLevel o
        , "chainwebVersion" .= _configChainwebVersion o
        , "nodes" .= _configNodes o
        , "format" .= _configFormat o
        ]

instance FromJSON (Config -> Config) where
    parseJSON = withObject "Config" $ \o -> id
        <$< configLogHandle ..: "logHandle" % o
        <*< configLogLevel ..: "logLevel" % o
        <*< configChainwebVersion ..: "ChainwebVersion" % o
        <*< configNodes . from leftMonoidalUpdate %.: "nodes" % o
         <*< configFormat ..: "format" % o

pConfig :: MParser Config
pConfig = id
    <$< configLogHandle .:: Y.pLoggerHandleConfig
    <*< configLogLevel .:: Y.pLogLevel
    <*< configChainwebVersion .:: option textReader
        % long "chainweb-version"
        <> help "chainweb version identifier"
    <*< configNodes %:: pLeftMonoidalUpdate . fmap pure % textOption
        % long "node"
        <> short 'n'
        <> help "node that is synced"
    <*< configFormat .:: textOption
        % long "format"
        <> short 'f'
        <> help "output format"

env :: Manager -> HostAddress -> ClientEnv
env mgr h = mkClientEnv mgr (hostAddressBaseUrl h)

hostAddressBaseUrl :: HostAddress -> BaseUrl
hostAddressBaseUrl h = BaseUrl
    { baseUrlScheme = Https
    , baseUrlHost = show (_hostAddressHost h)
    , baseUrlPort = fromIntegral (_hostAddressPort h)
    , baseUrlPath = ""
    }

-- -------------------------------------------------------------------------- --
-- Remote BlockHeaderDb

devNetDb :: Config -> Manager -> LogFunction -> ChainId -> HostAddress -> RemoteDb
devNetDb c mgr l chain node = mkDb (_configChainwebVersion c) chain mgr l node

-- TreeDB

mkDb
    :: HasChainwebVersion v
    => HasChainId cid
    => v
    -> cid
    -> Manager
    -> LogFunction
    -> HostAddress
    -> RemoteDb
mkDb v c mgr logg h = RemoteDb
    (env mgr h)
    (ALogFunction logg)
    (_chainwebVersion v)
    (_chainId c)

-- -------------------------------------------------------------------------- --
-- Payloads

devNetCut :: Logger l => Config -> l -> Manager -> HostAddress -> IO CutHashes
devNetCut config logger mgr node
    = retry $ runClientM (cutGetClient ver) (env mgr node) >>= \case
        Left e -> error (show e)
        Right a -> return a
  where
    ver = _configChainwebVersion config

    logg :: LogFunction
    logg = logFunction logger

    retry a = recoverAll policy $ \s -> do
        unless (rsIterNumber s == 0) $ logg @T.Text Warn $ "retry: " <> sshow (rsIterNumber s)
        a
    policy = exponentialBackoff 600000 <> limitRetries 6

-- -------------------------------------------------------------------------- --
--

remoteBranchDiff
    :: forall db a
    . TreeDb db
    => db
    -> db
    -> DbEntry db
    -> DbEntry db
    -> (S.Stream (Of (These (DbEntry db) (DbEntry db))) IO (DbEntry db) -> IO a)
    -> IO a
remoteBranchDiff dbl dbr lh rh a =
    branch dbl lh $ \lstream ->
        branch dbr rh $ \rstream -> do
            (l, ls) <- step lstream
            (r, rs) <- step rstream
            a $ go l r (void ls) (void rs)
  where
    go
        :: DbEntry db
        -> DbEntry db
        -> S.Stream (Of (DbEntry db)) IO ()
        -> S.Stream (Of (DbEntry db)) IO ()
        -> S.Stream (Of (These (DbEntry db) (DbEntry db))) IO (DbEntry db)
    go l r ls rs
        | key l == key r = return l
        | rank l > rank r = do
            S.yield (This l)
            (l', ls') <- lift $ step ls
            go l' r ls' rs
        | rank r > rank l = do
            S.yield (That r)
            (r', rs') <- lift $ step rs
            go l r' ls rs'
        | otherwise = do
            S.yield (These l r)
            (l', ls') <- lift $ step ls
            (r', rs') <- lift $ step rs
            go l' r' rs' ls'

    step s = S.next s >>= \case
        Left _ -> error "databases are from different chainweb versions"
        Right x -> return x

    branch db x = branchEntries db Nothing Nothing Nothing Nothing mempty (HS.singleton (UpperBound $ key x))

-- -------------------------------------------------------------------------- --
-- main

cid :: ChainId
cid = unsafeChainId 0

run :: Logger l => Config -> l -> IO ()
run config logger = do
    mgr <- unsafeManager 10000000

    logg @T.Text Info $ "left node: " <> toText leftNode
    logg @T.Text Info $ "right node: " <> toText rightNode

    let ldb = devNetDb config mgr logg cid leftNode
    let rdb = devNetDb config mgr logg cid rightNode

    l <- getChainHeader mgr ldb leftNode
    r <- getChainHeader mgr rdb rightNode

    (logFunction logger) @T.Text Info $ "start searching for fork"
    result <- remoteBranchDiff ldb rdb l r $ \s -> s
        & S.chain (logg @T.Text Debug . sshow)
        & S.mapM_
            (\x -> when (theseAny _blockHeight x `mod` 1000 == 0) $
                logg @T.Text Info ("BlockHeight: " <> sshow (theseAny _blockHeight x))
            )

    printResult (_configFormat config) leftNode rightNode l r result
  where
    logg :: LogFunction
    logg = logFunction logger

    (leftNode, rightNode) = case _configNodes config of
        (l:r:_) -> (l,r)
        _ -> error "no nodes given"

    theseAny f (This a) = f a
    theseAny f (That a) = f a
    theseAny f (These a _) = f a

    getChainHeader mgr db node = do
        logg' @T.Text Info "query cut"
        c <- _cutHashes <$> devNetCut config logger' mgr node
        case HM.lookup cid c of
            Nothing -> error "chain id not found in cut"
            Just (_, x) -> do
                logg' @T.Text Info $ "query header for chain" <> toText cid
                lookupM db x
      where
        logg' :: LogFunction
        logg' = logFunction logger'
        logger' = addLabel ("node", toText node) logger

printResult
    :: Format
    -> HostAddress
    -> HostAddress
    -> BlockHeader
    -> BlockHeader
    -> BlockHeader
    -> IO ()
printResult FormatShort leftNode rightNode left right fork = do
    T.putStrLn $ toText leftNode <> ": " <> sshow (_blockHeight left)
    T.putStrLn $ toText rightNode <> ": " <> sshow (_blockHeight right)
    T.putStrLn $ "Fork: " <> sshow (_blockHeight fork)

printResult FormatJson leftNode rightNode left right fork = BL8.putStrLn $ encode $ object
    [ toText leftNode .= ObjectEncoded left
    , toText rightNode .= ObjectEncoded right
    , "fork" .= ObjectEncoded fork
    ]

printResult FormatText leftNode rightNode left right fork = do
    T.putStrLn $ toText leftNode <> ": " <> prettyText left
    T.putStrLn $ toText rightNode <> ": " <> prettyText right
    T.putStrLn $ "Fork: " <> prettyText fork
  where
    prettyText = T.decodeUtf8 . BL8.toStrict . encodePretty . ObjectEncoded

-- -------------------------------------------------------------------------- --
--

mainWithConfig :: Config -> IO ()
mainWithConfig config = withLog $ \logger -> do
    let logger' = logger
            & addLabel ("version", toText $ _configChainwebVersion config)
    liftIO $ run config logger'
  where
    logconfig = Y.defaultLogConfig
        & Y.logConfigLogger . Y.loggerConfigThreshold .~ (_configLogLevel config)
        & Y.logConfigBackend . Y.handleBackendConfigHandle .~ _configLogHandle config
    withLog inner = Y.withHandleBackend_ logText (logconfig ^. Y.logConfigBackend)
        $ \backend -> Y.withLogger (logconfig ^. Y.logConfigLogger) backend inner

main :: IO ()
main = runWithConfiguration pinfo mainWithConfig
  where
    pinfo = programInfo "Chainweb Database" pConfig defaultConfig


