{-# LANGUAGE CPP                 #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}

module Ouroboros.Network.PeerSelection.PeerSelectionActions
  ( withPeerSelectionActions
    -- * Re-exports
  , PeerSelectionTargets (..)
  , PeerAdvertise (..)
  ) where


import Control.Applicative (Alternative)
import Control.Concurrent.Class.MonadMVar (MonadMVar (..), takeMVar)
import Control.Concurrent.Class.MonadSTM.Strict
import Control.Monad.Class.MonadAsync
import Control.Monad.Class.MonadThrow
import Control.Monad.Class.MonadTime.SI
import Control.Monad.Class.MonadTimer.SI
import Control.Tracer (Tracer)

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set (Set)
import Data.Void (Void)

import Network.DNS qualified as DNS
import Network.Socket qualified as Socket

import Data.Bifunctor (first)
import Ouroboros.Network.PeerSelection.Bootstrap (UseBootstrapPeers (..),
           requiresBootstrapPeers)
import Ouroboros.Network.PeerSelection.Governor.Types
import Ouroboros.Network.PeerSelection.LedgerPeers hiding (getLedgerPeers)
import Ouroboros.Network.PeerSelection.PeerAdvertise (PeerAdvertise (..))
import Ouroboros.Network.PeerSelection.PeerSharing (PeerSharing)
import Ouroboros.Network.PeerSelection.PeerTrustable (PeerTrustable)
import Ouroboros.Network.PeerSelection.PublicRootPeers (PublicRootPeers)
import Ouroboros.Network.PeerSelection.PublicRootPeers qualified as PublicRootPeers
import Ouroboros.Network.PeerSelection.RootPeersDNS.DNSActions (DNSActions)
import Ouroboros.Network.PeerSelection.RootPeersDNS.DNSSemaphore
import Ouroboros.Network.PeerSelection.RootPeersDNS.LocalRootPeers
import Ouroboros.Network.PeerSelection.RootPeersDNS.PublicRootPeers
import Ouroboros.Network.PeerSelection.State.LocalRootPeers
import Ouroboros.Network.PeerSharing (PeerSharingController (..))
import Ouroboros.Network.Protocol.PeerSharing.Type (PeerSharingAmount (..))
import System.Random (StdGen)


withPeerSelectionActions
  :: forall peeraddr peerconn resolver exception m a.
     ( Alternative (STM m)
     , MonadAsync m
     , MonadDelay m
     , MonadThrow m
     , MonadMVar  m
     , Ord peeraddr
     , Exception exception
     )
  => Tracer m (TraceLocalRootPeers peeraddr exception)
  -> Tracer m TracePublicRootPeers
  -> Tracer m TraceLedgerPeers
  -> (IP -> Socket.PortNumber -> peeraddr)
  -> DNSActions resolver exception m
  -> STM m PeerSelectionTargets
  -> STM m LedgerStateJudgement
  -> STM m [( HotValency
            , WarmValency
            , Map RelayAccessPoint (PeerAdvertise, PeerTrustable))]
  -- ^ local root peers
  -> STM m (Map RelayAccessPoint PeerAdvertise)
  -- ^ public root peers
  -> STM m UseBootstrapPeers
  -- ^ bootstrap peers
  -> PeerSharing
  -- ^ peer sharing configured value
  -> (peerconn -> PeerSharing)
  -- ^ Extract peer sharing information from peerconn
  -> STM m (Map peeraddr (PeerSharingController peeraddr m))
  -- ^ peer sharing registry
  -> STM m (peeraddr, PeerSharing)
  -- ^ Read New Inbound Connections
  -> PeerStateActions peeraddr peerconn m
  -> StdGen
  -- ^ Random generator for picking ledger peers
  -> LedgerPeersConsensusInterface m
  -- ^ Get Ledger Peers comes from here
  -> STM m UseLedgerPeers
  -- ^ Get Use Ledger After value
  -> (   (Async m Void, Async m Void)
      -> PeerSelectionActions peeraddr peerconn m
      -> m a)
  -- ^ continuation, receives a handle to the local roots peer provider thread
  -- (only if local root peers were non-empty).
  -> m a
withPeerSelectionActions
  localRootTracer
  publicRootTracer
  ledgerPeersTracer
  toPeerAddr
  dnsActions
  readPeerSelectionTargets
  readLedgerStateJudgement
  readLocalRootPeers
  readPublicRootPeers
  readUseBootstrapPeers
  peerSharing
  peerConnToPeerSharing
  readPeerSharingController
  readNewInboundConnections
  peerStateActions
  ledgerPeersRng
  ledgerPeersConsensusInterface
  getUseLedgerPeers
  k = do
    localRootsVar <- newTVarIO mempty
    dnsSemaphore <- newLedgerAndPublicRootDNSSemaphore

    withLedgerPeers ledgerPeersRng dnsSemaphore toPeerAddr ledgerPeersTracer getUseLedgerPeers
                    ledgerPeersConsensusInterface dnsActions
      (\getLedgerPeers lpThread -> do
          let peerSelectionActions = PeerSelectionActions {
                  readPeerSelectionTargets,
                  readLocalRootPeers = readTVar localRootsVar,
                  readNewInboundConnection = readNewInboundConnections,
                  peerSharing,
                  peerConnToPeerSharing,
                  requestPublicRootPeers =
                    \lpk n -> requestPublicRootPeers lpk n getLedgerPeers dnsSemaphore,
                  requestPeerShare,
                  peerStateActions,
                  readLedgerStateJudgement,
                  readUseBootstrapPeers
                }
          withAsync
            (localRootPeersProvider
              localRootTracer
              toPeerAddr
              -- NOTE: we don't set `resolvConcurrent` because
              -- of https://github.com/kazu-yamamoto/dns/issues/174
              DNS.defaultResolvConf
              dnsActions
              readLocalRootPeers
              localRootsVar)
            (\lrppThread -> k (lpThread, lrppThread) peerSelectionActions)
      )
  where
    -- We start by reading the current ledger state judgement, if it is
    -- YoungEnough we only care about fetching for ledger peers, otherwise we
    -- aim to fetch bootstrap peers.
    requestPublicRootPeers
      :: LedgerPeersKind
      -> Int
      -> (NumberOfPeers -> LedgerPeersKind -> m (Maybe (Set peeraddr, DiffTime)))
      -> DNSSemaphore m
      -> m (PublicRootPeers peeraddr, DiffTime)
    requestPublicRootPeers ledgerPeersKind n getLedgerPeers dnsSemaphore = do
      -- Check if the node is in a sensitive state
      isSensitive <- atomically $ requiresBootstrapPeers <$> readUseBootstrapPeers
                                                         <*> readLedgerStateJudgement
      if isSensitive
         then do
          -- If the ledger state is in sensitive state we should get trustable peers.
          (bootstrapPeers, dt) <- requestConfiguredBootstrapPeers dnsSemaphore n
          pure (PublicRootPeers.fromBootstrapPeers bootstrapPeers, dt)
         else do
          -- If the ledger state is not in a sensitive state we should get ledger
          -- peers, the Nothing case should not happen but there can be a race
          -- condition. If that's the case we try again soon enough.
          mbLedgerPeers <- getLedgerPeers (NumberOfPeers $ fromIntegral n) ledgerPeersKind
          case mbLedgerPeers of
            -- no peers from the ledger
            Nothing -> do
              (publicRootPeers, dt) <- requestConfiguredPublicRootPeers dnsSemaphore n
              pure (PublicRootPeers.fromPublicRootPeers publicRootPeers, dt)
            Just (ledgerPeers, dt) ->
              case ledgerPeersKind of
                AllLedgerPeers ->
                  pure (PublicRootPeers.fromLedgerPeers ledgerPeers, dt)
                BigLedgerPeers ->
                  pure (PublicRootPeers.fromBigLedgerPeers ledgerPeers, dt)

    -- For each call we re-initialise the dns library which forces reading
    -- `/etc/resolv.conf`:
    -- https://github.com/intersectmbo/cardano-node/issues/731
    requestConfiguredPublicRootPeers :: DNSSemaphore m -> Int -> m (Map peeraddr PeerAdvertise, DiffTime)
    requestConfiguredPublicRootPeers dnsSemaphore n =
      -- NOTE: we don't set `resolvConcurrent` because of
      -- https://github.com/kazu-yamamoto/dns/issues/174
      publicRootPeersProvider publicRootTracer
                              toPeerAddr
                              dnsSemaphore
                              -- NOTE: we don't set `resolveConcurrent` because
                              -- of https://github.com/kazu-yamamoto/dns/issues/174
                              DNS.defaultResolvConf
                              readPublicRootPeers
                              dnsActions
                              ($ n)

    requestConfiguredBootstrapPeers :: DNSSemaphore m -> Int -> m (Set peeraddr, DiffTime)
    requestConfiguredBootstrapPeers dnsSemaphore n = do
      let readBootstrapPeersMap =
            fmap (\case
                    DontUseBootstrapPeers     -> Map.empty
                    UseBootstrapPeers domains ->
                      Map.fromList ((,DoNotAdvertisePeer) <$> domains)
                 )
                 readUseBootstrapPeers

      publicRootPeersProvider publicRootTracer
                              toPeerAddr
                              dnsSemaphore
                              DNS.defaultResolvConf
                              readBootstrapPeersMap
                              dnsActions
                              (fmap (first Map.keysSet) . ($ n))

    requestPeerShare :: PeerSharingAmount -> peeraddr -> m (PeerSharingResult peeraddr)
    requestPeerShare amount peer = do
      resultQueue <- newEmptyMVar
      controller <- atomically readPeerSharingController
      case Map.lookup peer controller of
        -- Peer Registering happens asynchronously with respect to
        -- requestPeerShare. This means that there's a possible race where the
        -- Peer Selection Governor can decide to peer share request to a peer
        -- for the peer is registered. When this happens this map lookup is
        -- going to fail, so instead of erroring we report this to the governor
        -- so it can deal with this particular case accordingly.
        Nothing -> return PeerSharingNotRegisteredYet
        Just (PeerSharingController requestQueue) -> do
          atomically $ putTMVar requestQueue (amount, resultQueue)
          result <- takeMVar resultQueue
          return (PeerSharingResult result)
