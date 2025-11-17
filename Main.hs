{-# LANGUAGE GHC2021 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Control.Applicative ((<|>))
import Control.Exception (IOException, displayException, try)
import Control.Monad (forM, join)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BS
import Data.Either (isRight)
import Data.Hashable (hash)
import Data.List (findIndex, nubBy, sortBy)
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..), comparing)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO.Utf8 qualified as Utf8
import Data.Text.Lazy qualified as TL
import Data.Time (UTCTime, diffUTCTime, getCurrentTime, getCurrentTimeZone, utcToLocalTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.UUID.V4 (nextRandom)
import Data.Yaml qualified as Yaml
import GHC.Generics (Generic)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Simple qualified as HTTP
import Network.HTTP.Types qualified as HTTP
import Options.Applicative qualified as Opt
import System.Directory (createDirectoryIfMissing)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.Random (randomRIO)
import Text.Atom.Feed qualified as Atom
import Text.Feed.Export qualified as Feed
import Text.Feed.Import qualified as Feed
import Text.Feed.Query qualified as Feed
import Text.Feed.Types qualified as Feed

-- TODO
-- 1. Write files through temporaries
-- 2. Remove recent output and source entries from selected entries
-- 3. Add minimum run gap
-- 4. validate feed conversion logic
-- 5. test with RSS feed
-- 6. Add support for JSON feeds
-- 7. Add cache directory

data LogLevel = Info | Error | Debug deriving (Show)

data Config = Config
  { sourceFeedUrl :: String,
    outputFilename :: String,
    cacheSourceFeed :: Bool,
    repeatedEntryCount :: Int
  }
  deriving (Show, Eq, Generic, Aeson.FromJSON)

data Options = Options
  { configPath :: FilePath,
    outputDir :: FilePath
  }

main :: IO ()
main = do
  Options {configPath, outputDir} <-
    Opt.execParser $
      Opt.info
        optionsParser
        ( Opt.fullDesc
            <> Opt.progDesc "feed-repeat repeats entries of given feeds into new feeds"
            <> Opt.header "feed-repeat"
        )
  try (createDirectoryIfMissing True outputDir) >>= \case
    Left (e :: IOException) -> do
      logMsg Error $ "Failed to create output directory: " <> displayException e
      exitFailure
    Right _ ->
      Yaml.decodeFileEither configPath >>= \case
        Left err -> do
          logMsg Error $ "Error reading config: " <> show err
          exitFailure
        Right configs | null configs -> logMsg Error "No configs found in file" >> exitFailure
        Right configs -> do
          validationResults <- forM configs $ \c@Config {..} -> do
            res <- try $ HTTP.parseRequest sourceFeedUrl :: IO (Either HTTP.HttpException HTTP.Request)
            return (c, isRight res)
          let validConfigs = map fst $ filter snd validationResults
          let invalidConfigs = map fst $ filter (not . snd) validationResults
          if not (null invalidConfigs)
            then do
              logMsg Error "Invalid URLs in config:"
              mapM_ (\Config {..} -> logMsg Error $ "  " <> sourceFeedUrl) invalidConfigs
              exitFailure
            else mapM_ (flip processConfig outputDir) validConfigs

optionsParser :: Opt.Parser Options
optionsParser =
  Options
    <$> Opt.strOption
      ( Opt.long "config"
          <> Opt.metavar "FILE"
          <> Opt.help "Path to YAML config file containing feed sources"
      )
    <*> Opt.strOption
      ( Opt.long "output-dir"
          <> Opt.metavar "DIR"
          <> Opt.help "Directory where output Atom files will be written"
      )
      Opt.<**> Opt.helper

processConfig :: Config -> FilePath -> IO ()
processConfig Config {..} outputDir = do
  logMsg Debug $ "Processing config for " <> sourceFeedUrl
  saveFeed cacheSourceFeed sourceFeedUrl >>= \case
    Left err -> logMsg Error $ "Error fetching feed: " <> err
    Right sourceFeed -> do
      logMsg Debug $ "Fetched feed with " <> show (length $ Atom.feedEntries sourceFeed) <> " entries"
      let outputPath = outputFilename <> ".atom"
      outputFeedResult <- parseAtomFile outputDir outputPath
      mergedFeed <- case outputFeedResult of
        Left err -> logMsg Debug ("Failed to read output feed: " <> err) >> return sourceFeed
        Right outputFeed -> return $ mergeFeeds sourceFeed outputFeed

      let allEntries = Atom.feedEntries mergedFeed
      logMsg Debug $ "Merged feed has " <> show (length allEntries) <> " entries"

      now <- getCurrentTime
      let timestamp = T.pack $ iso8601Show now
      selectedEntries <-
        selectEntries repeatedEntryCount allEntries
          >>= traverse
            ( \e -> do
                uuid <- nextRandom
                return e {Atom.entryId = T.pack $ "urn:uuid:" <> show uuid, Atom.entryUpdated = timestamp}
            )
      logMsg Debug $ "Selected " <> show (length selectedEntries) <> " entries for repetition"

      outputFeedEntries <- case outputFeedResult of
        Left _ -> return []
        Right outputFeed -> return $ Atom.feedEntries outputFeed
      let combinedEntries = selectedEntries <> outputFeedEntries
      logMsg Debug $
        "Combined entries: "
          <> (show (length selectedEntries) <> " new + ")
          <> (show (length outputFeedEntries) <> " existing = ")
          <> show (length combinedEntries)

      resultFeed <- case outputFeedResult of
        Left _ -> return sourceFeed {Atom.feedEntries = combinedEntries}
        Right outputFeed -> return outputFeed {Atom.feedEntries = combinedEntries}
      case Feed.textFeed (Feed.AtomFeed resultFeed) of
        Nothing -> logMsg Error "Failed to export feed"
        Just txt -> do
          try (Utf8.writeFile (outputDir </> outputPath) $ TL.toStrict txt) >>= \case
            Left (e :: IOException) -> logMsg Error $ "Failed to write output file: " <> displayException e
            Right _ -> logMsg Info $ "Processed " <> sourceFeedUrl <> " successfully"

saveFeed :: Bool -> String -> IO (Either String Atom.Feed)
saveFeed cache url =
  fetchFeed url >>= \case
    Left err -> return $ Left err
    Right feed -> do
      let fileName = show (hash url) <> ".atom"
      mergedFeed <-
        if cache
          then
            parseAtomFile "." fileName >>= \case
              Left _ -> return feed
              Right savedFeed -> return $ mergeFeeds savedFeed feed
          else return feed

      case Feed.textFeed (Feed.AtomFeed mergedFeed) of
        Nothing -> return $ Left $ "Failed to export feed for URL: " <> url
        Just txt ->
          try (Utf8.writeFile fileName $ TL.toStrict txt) >>= \case
            Left (e :: IOException) -> return $ Left $ "Failed to write cache file: " <> displayException e
            Right _ -> return $ Right mergedFeed

fetchFeed :: String -> IO (Either String Atom.Feed)
fetchFeed url =
  try (HTTP.parseRequest url) >>= \case
    Left (e :: HTTP.HttpException) -> return $ Left $ "Invalid URL: " <> displayException e
    Right request -> do
      let request' =
            request
              { HTTP.responseTimeout = HTTP.responseTimeoutMicro requestTimeoutMicros,
                HTTP.requestHeaders = HTTP.requestHeaders request <> [(HTTP.hUserAgent, "feed-repeat")]
              }
      try (HTTP.httpLBS request') >>= \case
        Left (e :: HTTP.HttpException) -> return $ Left $ "HTTP error: " <> displayException e
        Right response -> do
          let body = TL.fromStrict $ TE.decodeUtf8Lenient $ BS.toStrict $ HTTP.getResponseBody response
          case Feed.parseFeedSource body of
            Nothing -> return $ Left $ "Failed to parse feed: " <> url
            Just feed -> Right <$> feedToAtom feed
  where
    requestTimeoutMicros = 30_000_000 -- 30 sec

feedToAtom :: Feed.Feed -> IO Atom.Feed
feedToAtom feed = do
  let title = Feed.getFeedTitle feed
      link = Feed.getFeedHome feed
      pubDate = Feed.getFeedPubDate feed
      updateDate = Feed.getFeedLastUpdate feed
      feedId = fromMaybe "" link
      feedTitle = Atom.TextString title
      feedUpdated = fromMaybe "" (updateDate <|> pubDate)
      baseFeed = Atom.nullFeed feedId feedTitle feedUpdated
  entries <- mapM itemToAtomEntry (Feed.getFeedItems feed)
  return baseFeed {Atom.feedEntries = entries, Atom.feedLinks = [Atom.nullLink feedId]}
  where
    itemToAtomEntry :: Feed.Item -> IO Atom.Entry
    itemToAtomEntry item = case item of
      Feed.AtomItem atomEntry -> return atomEntry
      _ -> do
        let title = Feed.getItemTitle item
            link = Feed.getItemLink item
            pubDate = join (Feed.getItemPublishDate item :: Maybe (Maybe UTCTime))
            desc = Feed.getItemDescription item
            entryId = fromMaybe "" link
            entryTitle = Atom.TextString $ fromMaybe "" title
            entryUpdated = T.pack $ maybe "" iso8601Show pubDate
        let entry =
              (Atom.nullEntry entryId entryTitle entryUpdated)
                { Atom.entryLinks = [Atom.nullLink $ fromMaybe "" link],
                  Atom.entryContent = Atom.HTMLContent <$> desc
                }
        if T.null (Atom.entryId entry)
          then do
            uuid <- nextRandom
            return entry {Atom.entryId = T.pack $ "urn:uuid:" <> show uuid}
          else return entry

mergeFeeds :: Atom.Feed -> Atom.Feed -> Atom.Feed
mergeFeeds feed1 feed2 =
  let allEntries = Atom.feedEntries feed1 <> Atom.feedEntries feed2
      sortedEntries = sortBy (comparing (Down . Atom.entryUpdated)) allEntries
      uniqueEntries =
        nubBy
          (\a b -> Feed.getItemLink (Feed.AtomItem a) == Feed.getItemLink (Feed.AtomItem b))
          sortedEntries
   in feed1 {Atom.feedEntries = uniqueEntries}

selectEntries :: Int -> [Atom.Entry] -> IO [Atom.Entry]
selectEntries n entries = do
  now <- getCurrentTime
  let weights = map (computeWeight now) entries
  select n entries weights []
  where
    halfLifeDays :: Double
    halfLifeDays = 7

    computeWeight :: UTCTime -> Atom.Entry -> Double
    computeWeight now entry = case Feed.getItemPublishDate (Feed.AtomItem entry) of
      Nothing -> 1
      Just Nothing -> 1
      Just (Just updated) ->
        let age = diffUTCTime now updated
         in if age > 0 then exp (realToFrac age / (86400 * halfLifeDays)) else 1

    select :: Int -> [Atom.Entry] -> [Double] -> [Atom.Entry] -> IO [Atom.Entry]
    select 0 _ _ acc = return acc
    select k es ws acc = do
      let total = sum ws
      r <- randomRIO (0, total)
      let cumulative = scanl (+) 0 ws
      let idx = min (length es - 1) $ fromMaybe 0 $ findIndex (> r) cumulative
      let selected = es !! idx
      let (newEsP, newEsS) = splitAt idx es
      let (newWsP, newWsS) = splitAt idx ws
      select (k - 1) (newEsP <> drop 1 newEsS) (newWsP <> drop 1 newWsS) (selected : acc)

parseAtomFile :: FilePath -> String -> IO (Either String Atom.Feed)
parseAtomFile dir name = do
  let filePath = dir </> name
  content <- try $ readFile filePath
  case content of
    Left (e :: IOException) ->
      return . Left $ "Error reading " <> filePath <> ": " <> displayException e
    Right body -> case Feed.parseFeedString body of
      Nothing -> return . Left $ "Failed to parse Atom file " <> filePath
      Just feed -> case feed of
        Feed.AtomFeed af -> do
          logMsg Debug $
            ("Parsed Atom file " <> filePath <> " with ")
              <> (show (length $ Feed.getFeedItems feed) <> " entries")
          return $ Right af
        _ -> return $ Left $ "File is not in Atom format: " <> filePath

logMsg :: LogLevel -> String -> IO ()
logMsg level msg = do
  now <- getCurrentTime
  tz <- getCurrentTimeZone
  let localTime = utcToLocalTime tz now
  let timestamp = formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" localTime
  putStrLn $ timestamp <> " [" <> show level <> "] " <> msg
