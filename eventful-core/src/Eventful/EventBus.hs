module Eventful.EventBus
  ( synchronousEventBusWrapper
  , storeAndPublishEvents
  ) where

import Eventful.Store.Class
import Eventful.UUID

-- | This function wraps an event store by sending events to event handlers
-- after running 'storeEvents'. This is useful to quickly wire up event
-- handlers in your application (like read models or process managers), and it
-- is also useful for integration testing along with an in-memory event store.
synchronousEventBusWrapper
  :: (Monad m)
  => EventStore serialized m
  -> [EventStore serialized m -> UUID -> serialized -> m ()]
  -> EventStore serialized m
synchronousEventBusWrapper store handlers =
  let
    -- NB: We need to use recursive let bindings so we can put wrappedStore
    -- inside the event handlers
    handlers' = map ($ wrappedStore) handlers
    wrappedStore =
      EventStore
      { getEvents = getEvents store
      , storeEvents = storeAndPublishEvents store handlers'
      }
  in wrappedStore

-- | Stores events in the store and them publishes them to the event handlers.
-- This is used in the 'synchronousEventBusWrapper'.
storeAndPublishEvents
  :: (Monad m)
  => EventStore serialized m
  -> [UUID -> serialized -> m ()]
  -> ExpectedVersion
  -> UUID
  -> [serialized]
  -> m (Maybe EventWriteError)
storeAndPublishEvents store handlers expectedVersion uuid events = do
  result <- storeEvents store expectedVersion uuid events
  case result of
    Just err -> return $ Just err
    Nothing -> do
      -- NB: If a handler stores events, then its events will be published
      -- before the events of the next handler. That is, we will be storing
      -- events generated by handlers in depth-first order.
      mapM_ (\handler -> mapM_ (handler uuid) events) handlers
      return Nothing
