module Eventful.Store.Memory
  ( MemoryEventStore
  , MemoryEventStoreT
  , memoryEventStore
  , module Eventful.Store.Class
  ) where

import Control.Concurrent.STM
import Data.Dynamic
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Sequence (Seq, (><))
import qualified Data.Sequence as Seq

import Eventful.Store.Class
import Eventful.UUID

data EventMap
  = EventMap
  { _eventMapUuidMap :: Map UUID (Seq (StoredEvent Dynamic))
  , _eventMapSeqNum :: SequenceNumber
  -- TODO: Add projection cache here
  }
  deriving (Show)

-- | A 'MemoryEventStore' is a 'TVar EventMap', serializes to 'Dynamic', and
-- runs in 'STM'.
type MemoryEventStore = EventStore (TVar EventMap) Dynamic STM
type MemoryEventStoreT = EventStoreT (TVar EventMap) Dynamic STM

-- | Initializes the 'TVar' used in the event store and returns the store.
memoryEventStore :: IO MemoryEventStore
memoryEventStore = do
  tvar <- newTVarIO (EventMap Map.empty 0)
  return $ EventStore tvar memoryEventStoreDefinition

type MemoryEventStoreDefinition = EventStoreDefinition (TVar EventMap) Dynamic STM

memoryEventStoreDefinition :: MemoryEventStoreDefinition
memoryEventStoreDefinition =
  let
    getAllUuidsRaw tvar = fmap fst . Map.toList . _eventMapUuidMap <$> readTVar tvar
    getLatestVersionRaw tvar uuid = flip latestEventVersion uuid <$> readTVar tvar
    getEventsRaw tvar uuid = toList . flip lookupEventMapRaw uuid <$> readTVar tvar
    getEventsFromVersionRaw tvar uuid vers = toList . (\s -> lookupEventsFromVersion s uuid vers) <$> readTVar tvar
    storeEventsRaw tvar uuid events = do
      store <- readTVar tvar
      let (newMap, storedEvents) = storeEventMap store uuid events
      writeTVar tvar newMap
      return storedEvents
    getSequencedEventsRaw tvar seqNum = flip lookupEventMapSeq seqNum <$> readTVar tvar
  in EventStoreDefinition{..}

lookupEventMapRaw :: EventMap -> UUID -> Seq (StoredEvent Dynamic)
lookupEventMapRaw (EventMap uuidMap _) uuid =
  fromMaybe Seq.empty $ Map.lookup uuid uuidMap

lookupEventsFromVersion :: EventMap -> UUID -> EventVersion -> Seq (StoredEvent Dynamic)
lookupEventsFromVersion store uuid (EventVersion vers) = Seq.drop vers $ lookupEventMapRaw store uuid

latestEventVersion :: EventMap -> UUID -> EventVersion
latestEventVersion store uuid = EventVersion $ Seq.length (lookupEventMapRaw store uuid) - 1

lookupEventMapSeq :: EventMap -> SequenceNumber -> [StoredEvent Dynamic]
lookupEventMapSeq (EventMap uuidMap _) seqNum =
  sortOn storedEventSequenceNumber $ filter ((> seqNum) . storedEventSequenceNumber) $ concat $ toList <$> toList uuidMap

storeEventMap
  :: EventMap -> UUID -> [Dynamic] -> (EventMap, [StoredEvent Dynamic])
storeEventMap store@(EventMap uuidMap seqNum) uuid events =
  let versStart = latestEventVersion store uuid + 1
      storedEvents = zipWith3 (StoredEvent uuid) [versStart..] [seqNum + 1..] events
      newMap = Map.insertWith (flip (><)) uuid (Seq.fromList storedEvents) uuidMap
      newSeq = seqNum + (SequenceNumber $ length events)
  in (EventMap newMap newSeq, storedEvents)
