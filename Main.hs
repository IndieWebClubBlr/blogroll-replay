{-# LANGUAGE GHC2021 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Control.Applicative ((<|>))
import Control.Exception (IOException, displayException, try)
import Control.Monad (forM, join, mplus, when)
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
import Data.Time (NominalDiffTime, UTCTime(..), diffUTCTime, getCurrentTime, getCurrentTimeZone, utcToLocalTime)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM, rfc822DateFormat)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.UUID.V4 (nextRandom)
import Data.Yaml qualified as Yaml
import GHC.Generics (Generic)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Simple qualified as HTTP
import Network.HTTP.Types qualified as HTTP
import Options.Applicative qualified as Opt
import System.Directory (createDirectoryIfMissing, renameFile)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.Random (randomRIO)
import Text.Atom.Feed qualified as Atom
import Text.Feed.Export qualified as Feed
import Text.Feed.Import qualified as Feed
import Text.Feed.Query qualified as Feed
import Text.Feed.Types qualified as Feed
import Prelude hiding (writeFile)

-- TODO
-- 4. validate feed conversion logic
-- 6. Add support for JSON feeds

data LogLevel = ERR | WRN | INF | DBG deriving (Show)

data FeedTask = FeedTask
  { sourceFeedUrl :: String,
    outputFilename :: String,
    cacheSourceFeed :: Bool,
    repeatedEntryCount :: Int,
    minimumEntryAgeDays :: Int
  }
  deriving (Show, Eq, Generic, Aeson.FromJSON)

data Options = Options
  { configPath :: FilePath,
    outputDir :: FilePath,
    cacheDir :: FilePath
  }

main :: IO ()
main = do
  options@Options {..} <-
    Opt.execParser $
      Opt.info
        optionsParser
        ( Opt.fullDesc
            <> Opt.progDesc "feed-repeat repeats entries of given feeds into new feeds"
            <> Opt.header "feed-repeat"
        )
  try (createDirectoryIfMissing True outputDir) >>= \case
    Left (e :: IOException) -> do
      logMsg ERR $ "Failed to create output directory: " <> displayException e
      exitFailure
    Right _ ->
      try (createDirectoryIfMissing True cacheDir) >>= \case
        Left (e :: IOException) -> do
          logMsg ERR $ "Failed to create cache directory: " <> displayException e
          exitFailure
        Right _ -> run options

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
    <*> Opt.strOption
      ( Opt.long "cache-dir"
          <> Opt.metavar "DIR"
          <> Opt.value "."
          <> Opt.help "Directory where cached Atom files will be stored"
      )
      Opt.<**> Opt.helper

run :: Options -> IO ()
run Options {..} =
  Yaml.decodeFileEither configPath >>= \case
    Left err -> do
      logMsg ERR $ "Error reading config: " <> show err
      exitFailure
    Right tasks | null tasks -> logMsg ERR "No tasks found in file" >> exitFailure
    Right tasks -> do
      validationResults <- forM tasks $ \c@FeedTask {..} -> do
        res <- try $ HTTP.parseRequest sourceFeedUrl :: IO (Either HTTP.HttpException HTTP.Request)
        return (c, isRight res)
      let validTasks = map fst $ filter snd validationResults
      let invalidTasks = map fst $ filter (not . snd) validationResults
      if not (null invalidTasks)
        then do
          logMsg ERR "Invalid source feed URLs in tasks:"
          mapM_ (\FeedTask {..} -> logMsg ERR $ "  " <> sourceFeedUrl) invalidTasks
          exitFailure
        else mapM_ (\c -> runTask c outputDir cacheDir) validTasks

minRunGapSeconds :: NominalDiffTime
minRunGapSeconds = 86400 -- one day

runTask :: FeedTask -> FilePath -> FilePath -> IO ()
runTask FeedTask {..} outputDir cacheDir = do
  logMsg DBG $ "Processing: " <> sourceFeedUrl
  now <- getCurrentTime
  let outputPath = outputDir </> outputFilename <> ".atom"
  outputFeedResult <- parseAtomFile outputPath
  let outputFeedUpdated = case outputFeedResult of
        Left _ -> UTCTime (fromGregorian 2000 1 1) 0
        Right outputFeed -> fromMaybe now $ parseDate $ Atom.feedUpdated outputFeed
  if diffUTCTime now outputFeedUpdated < minRunGapSeconds
    then logMsg INF $ "Skipping run for URL: " <> sourceFeedUrl
    else
      fetchCacheFeed cacheSourceFeed sourceFeedUrl cacheDir >>= \case
        Left err -> logMsg ERR $ "Error fetching feed: " <> err
        Right sourceFeed -> do
          logMsg DBG $ "Fetched feed with " <> show (length $ Atom.feedEntries sourceFeed) <> " entries"
          mergedFeed <- case outputFeedResult of
            Left err -> logMsg DBG ("Failed to read output feed: " <> err) >> return sourceFeed
            Right outputFeed -> return $ mergeFeeds sourceFeed outputFeed

          let allEntries = Atom.feedEntries mergedFeed
          logMsg DBG $ "Merged feed has " <> show (length allEntries) <> " entries"

          let timestamp = T.pack $ iso8601Show now
              minAgeSeconds = fromIntegral minimumEntryAgeDays * 86400
          selectedEntries <-
            selectEntries repeatedEntryCount minAgeSeconds allEntries
              >>= traverse
                ( \e -> do
                    uuid <- nextRandom
                    return e {Atom.entryId = T.pack $ "urn:uuid:" <> show uuid, Atom.entryUpdated = timestamp}
                )
          logMsg DBG $ "Selected " <> show (length selectedEntries) <> " entries for repetition"

          let outputFeedEntries = case outputFeedResult of
                Left _ -> []
                Right outputFeed -> Atom.feedEntries outputFeed
          let combinedEntries = selectedEntries <> outputFeedEntries
          logMsg DBG $
            "Combined entries: "
              <> (show (length selectedEntries) <> " new + ")
              <> (show (length outputFeedEntries) <> " existing = ")
              <> show (length combinedEntries)

          let resultFeed' = case outputFeedResult of
                Left _ -> sourceFeed
                Right outputFeed -> outputFeed
              resultFeed =
                resultFeed'
                  { Atom.feedUpdated = T.pack $ iso8601Show now,
                    Atom.feedEntries = combinedEntries
                  }
          case Feed.textFeed (Feed.AtomFeed resultFeed) of
            Nothing -> logMsg ERR $ "Failed to render feed for: " <> sourceFeedUrl
            Just txt -> do
              try (writeFile outputPath txt) >>= \case
                Left (e :: IOException) -> logMsg ERR $ "Failed to write output file: " <> displayException e
                Right _ -> logMsg INF $ "Processed " <> sourceFeedUrl <> " successfully"

fetchCacheFeed :: Bool -> String -> FilePath -> IO (Either String Atom.Feed)
fetchCacheFeed cache url cacheDir = do
  let fileName = show (hash url) <> ".atom"
      filePath = cacheDir </> fileName
  fetchFeed url >>= \case
    Left err | cache -> do
      logMsg WRN $ "Unable to fetch fresh feed for URL: " <> url <> ", using cached: " <> err
      parseAtomFile filePath
    Left err -> return $ Left err
    Right freshFeed -> do
      mergedFeed <-
        if cache
          then
            parseAtomFile filePath >>= \case
              Left _ -> return freshFeed
              Right savedFeed -> return $ mergeFeeds freshFeed savedFeed
          else return freshFeed

      when cache $
        case Feed.textFeed (Feed.AtomFeed mergedFeed) of
          Nothing -> logMsg WRN $ "Failed to export feed for URL: " <> url
          Just txt -> do
            try (writeFile filePath txt) >>= \case
              Left (e :: IOException) -> logMsg WRN $ "Failed to write cache file: " <> displayException e
              Right _ -> logMsg INF $ "Cached " <> filePath <> " for URL: " <> url

      return $ Right mergedFeed

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

selectEntries :: Int -> Integer -> [Atom.Entry] -> IO [Atom.Entry]
selectEntries n minAgeSeconds entries = do
  now <- getCurrentTime
  let oldEntries = filter (isOldEnough now) entries
  let weights = map (computeWeight now) oldEntries
  select n oldEntries weights []
  where
    halfLifeDays :: Double
    halfLifeDays = 7

    isOldEnough :: UTCTime -> Atom.Entry -> Bool
    isOldEnough currentTime entry =
      case parseDate $ Atom.entryUpdated entry of
        Nothing -> True
        Just entryTime -> diffUTCTime currentTime entryTime >= fromInteger minAgeSeconds

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

parseAtomFile :: FilePath -> IO (Either String Atom.Feed)
parseAtomFile filePath = do
  content <- try $ readFile filePath
  case content of
    Left (e :: IOException) ->
      return . Left $ "Error reading " <> filePath <> ": " <> displayException e
    Right body -> case Feed.parseFeedString body of
      Nothing -> return . Left $ "Failed to parse Atom file " <> filePath
      Just feed -> case feed of
        Feed.AtomFeed af -> do
          logMsg DBG $
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

writeFile :: FilePath -> TL.Text -> IO ()
writeFile fp content = do
  let tmpFP = fp <> ".tmp"
  Utf8.writeFile tmpFP $ TL.toStrict content
  renameFile tmpFP fp

parseDate :: T.Text -> Maybe UTCTime
parseDate ds = do
  let rfc3339DateFormat1 = "%Y-%m-%dT%H:%M:%S%Z"
      rfc3339DateFormat2 = "%Y-%m-%dT%H:%M:%S%Q%Z"
      formats = [rfc3339DateFormat1, rfc3339DateFormat2, rfc822DateFormat]
  foldl1 mplus (map (\fmt -> parseTimeM True defaultTimeLocale fmt $ T.unpack ds) formats)
