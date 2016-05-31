  hunks,
  Hunk(..),
  truncatePatch
import Alignment
import Data.Bifunctor.Join
import Data.Functor.Both as Both
import Data.List (span, unzip)
import Data.String
import Data.Text (pack)
import Data.These
import Info
import Patch
import Prologue hiding (fst, snd)
import SplitDiff

-- | Render a timed out file as a truncated diff.
truncatePatch :: DiffArguments -> Both SourceBlob -> Text
truncatePatch _ blobs = pack $ header blobs ++ "#timed_out\nTruncating diff: timeout reached.\n"
patch :: Renderer
patch diff blobs = pack $ case getLast (foldMap (Last . Just) string) of
  Just c | c /= '\n' -> string ++ "\n\\ No newline at end of file\n"
  _ -> string
  where string = header blobs ++ mconcat (showHunk blobs <$> hunks diff blobs)
data Hunk a = Hunk { offset :: Both (Sum Int), changes :: [Change a], trailingContext :: [Join These a] }
data Change a = Change { context :: [Join These a], contents :: [Join These a] }
hunkLength :: Hunk a -> Both (Sum Int)
hunkLength hunk = mconcat $ (changeLength <$> changes hunk) <> (rowIncrement <$> trailingContext hunk)
changeLength :: Change a -> Both (Sum Int)
changeLength change = mconcat $ (rowIncrement <$> context change) <> (rowIncrement <$> contents change)
-- | The increment the given row implies for line numbering.
rowIncrement :: Join These a -> Both (Sum Int)
rowIncrement = Join . fromThese (Sum 0) (Sum 0) . runJoin . (Sum 1 <$)
showHunk :: Both SourceBlob -> Hunk (SplitDiff a Info) -> String
showHunk blobs hunk = maybeOffsetHeader ++
  concat (showChange sources <$> changes hunk) ++
  showLines (snd sources) ' ' (maybeSnd . runJoin <$> trailingContext hunk)
  where sources = source <$> blobs
        maybeOffsetHeader = if lengthA > 0 && lengthB > 0
                            then offsetHeader
                            else mempty
        offsetHeader = "@@ -" ++ offsetA ++ "," ++ show lengthA ++ " +" ++ offsetB ++ "," ++ show lengthB ++ " @@" ++ "\n"
        (lengthA, lengthB) = runJoin . fmap getSum $ hunkLength hunk
        (offsetA, offsetB) = runJoin . fmap (show . getSum) $ offset hunk
showChange :: Both (Source Char) -> Change (SplitDiff a Info) -> String
showChange sources change = showLines (snd sources) ' ' (maybeSnd . runJoin <$> context change) ++ deleted ++ inserted
  where (deleted, inserted) = runJoin $ pure showLines <*> sources <*> both '-' '+' <*> Join (unzip (fromThese Nothing Nothing . runJoin . fmap Just <$> contents change))
showLines :: Source Char -> Char -> [Maybe (SplitDiff leaf Info)] -> String
showLine :: Source Char -> Maybe (SplitDiff leaf Info) -> Maybe String
showLine source line | Just line <- line = Just . toString . (`slice` source) $ getRange line
                     | otherwise = Nothing
header :: Both SourceBlob -> String
header blobs = intercalate "\n" [filepathHeader, fileModeHeader, beforeFilepath, afterFilepath] ++ "\n"
  where filepathHeader = "diff --git a/" ++ pathA ++ " b/" ++ pathB
        fileModeHeader = case (modeA, modeB) of
          (Nothing, Just mode) -> intercalate "\n" [ "new file mode " ++ modeToDigits mode, blobOidHeader ]
          (Just mode, Nothing) -> intercalate "\n" [ "deleted file mode " ++ modeToDigits mode, blobOidHeader ]
          (Just mode, Just other) | mode == other -> "index " ++ oidA ++ ".." ++ oidB ++ " " ++ modeToDigits mode
          (Just mode1, Just mode2) -> intercalate "\n" [
            "old mode " ++ modeToDigits mode1,
            "new mode " ++ modeToDigits mode2,
            blobOidHeader
            ]
          (Nothing, Nothing) -> ""
        blobOidHeader = "index " ++ oidA ++ ".." ++ oidB
        modeHeader :: String -> Maybe SourceKind -> String -> String
        modeHeader ty maybeMode path = case maybeMode of
           Just _ -> ty ++ "/" ++ path
           Nothing -> "/dev/null"
        beforeFilepath = "--- " ++ modeHeader "a" modeA pathA
        afterFilepath = "+++ " ++ modeHeader "b" modeB pathB
        (pathA, pathB) = runJoin $ path <$> blobs
        (oidA, oidB) = runJoin $ oid <$> blobs
        (modeA, modeB) = runJoin $ blobKind <$> blobs

-- | A hunk representing no changes.
emptyHunk :: Hunk (SplitDiff a Info)
emptyHunk = Hunk { offset = mempty, changes = [], trailingContext = [] }
hunks :: Show a => Diff a Info -> Both SourceBlob -> [Hunk (SplitDiff a Info)]
hunks _ blobs | sources <- source <$> blobs
              , sourcesEqual <- runBothWith (==) sources
              , sourcesNull <- runBothWith (&&) (null <$> sources)
              , sourcesEqual || sourcesNull
  = [emptyHunk]
hunks diff blobs = hunksInRows (pure 1) $ alignDiff (source <$> blobs) diff

hunksInRows :: Both (Sum Int) -> [Join These (SplitDiff a Info)] -> [Hunk (SplitDiff a Info)]
nextHunk :: Both (Sum Int) -> [Join These (SplitDiff a Info)] -> Maybe (Hunk (SplitDiff a Info), [Join These (SplitDiff a Info)])
nextChange :: Both (Sum Int) -> [Join These (SplitDiff a Info)] -> Maybe (Both (Sum Int), Change (SplitDiff a Info), [Join These (SplitDiff a Info)])
  Just (change, afterChanges) -> Just (start <> mconcat (rowIncrement <$> skippedContext), change, afterChanges)
changeIncludingContext :: [Join These (SplitDiff a Info)] -> [Join These (SplitDiff a Info)] -> Maybe (Change (SplitDiff a Info), [Join These (SplitDiff a Info)])
rowHasChanges :: Join These (SplitDiff a Info) -> Bool
rowHasChanges row = or (hasChanges <$> row)