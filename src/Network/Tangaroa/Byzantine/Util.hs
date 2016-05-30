{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

module Network.Tangaroa.Byzantine.Util
  ( seqIndex
  , lastLogInfo
  , getQuorumSize
  , debug
  , fork_
  , wait
  , runRWS_
  , enqueueEvent
  , dequeueEvent
  , messageReceiver
  , verifyRPCWithKey
  , verifyRPCWithClientKey
  , signRPCWithKey
  , updateTerm
  ) where

import Network.Tangaroa.Byzantine.Types
import Network.Tangaroa.Combinator

import Control.Lens
import Data.Binary
import Codec.Crypto.RSA
import Data.Sequence (Seq)
import Control.Monad.RWS
import Control.Concurrent.Lifted (fork, threadDelay)
import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Concurrent.Chan.Unagi (readChan, writeChan)
import qualified Data.ByteString as B
import qualified Data.Sequence as Seq
import qualified Data.Map as Map

seqIndex :: Seq a -> Int -> Maybe a
seqIndex s i =
  if i >= 0 && i < Seq.length s
    then Just (Seq.index s i)
    else Nothing

getQuorumSize :: Int -> Int
getQuorumSize n = minimum [n - f | f <- [0..n], n >= 3*f + 1]

-- get the last term and index of a log
lastLogInfo :: Seq (LogEntry nt et) -> (Term, LogIndex, B.ByteString)
lastLogInfo es =
  case Seq.viewr es of
    _ Seq.:> LogEntry{..} -> (_leTerm, Seq.length es - 1, _leHash)
    Seq.EmptyR            -> (startTerm, startIndex, B.empty)

debug :: String -> Raft nt et rt mt ()
debug s = do
  dbg <- view (rs.debugPrint)
  nid <- view (cfg.nodeId)
  dbg nid s

fork_ :: MonadBaseControl IO m => m () -> m ()
fork_ a = fork a >> return ()

wait :: Int -> Raft nt et rt mt ()
wait t = threadDelay t

runRWS_ :: Monad m => RWST r w s m a -> r -> s -> m ()
runRWS_ ma r s = runRWST ma r s >> return ()

enqueueEvent :: Event nt et rt -> Raft nt et rt mt ()
enqueueEvent event = do
  ein <- view eventIn
  lift $ writeChan ein event

dequeueEvent :: Raft nt et rt mt (Event nt et rt)
dequeueEvent = lift . readChan =<< view eventOut

-- | Thread to take incoming messages and write them to the event queue.
messageReceiver :: Raft nt et rt mt ()
messageReceiver = do
  gm <- view (rs.getMessage)
  deser <- view (rs.deserializeRPC)
  forever $
    gm >>= maybe
      (debug "failed to deserialize RPC")
      (enqueueEvent . ERPC)
      . deser

verifyWrappedRPC :: (Binary nt, Binary et, Binary rt) => PublicKey -> RPC nt et rt -> Bool
verifyWrappedRPC k rpc = case rpc of
  AE ae          -> verifyRPC k ae
  AER aer        -> verifyRPC k aer
  RV rv          -> verifyRPC k rv
  RVR rvr        -> verifyRPC k rvr
  CMD cmd        -> verifyRPC k cmd
  CMDR cmdr      -> verifyRPC k cmdr
  REVOLUTION rev -> verifyRPC k rev
  DBG _          -> True

senderId :: RPC nt et rt -> Maybe nt
senderId rpc = case rpc of
    AE ae          -> Just (_leaderId ae)
    AER aer        -> Just (_aerNodeId aer)
    RV rv          -> Just (_rvCandidateId rv)
    RVR rvr        -> Just (_rvrNodeId rvr)
    CMD cmd        -> Just (_cmdClientId cmd)
    CMDR cmdr      -> Just (_cmdrNodeId cmdr)
    REVOLUTION rev -> Just (_revClientId rev)
    DBG _          -> Nothing

verifyRPCWithKey :: (Binary nt, Binary et, Binary rt, Ord nt) => RPC nt et rt -> Raft nt et rt mt Bool
verifyRPCWithKey rpc =
  case rpc of
    AE _   -> doVerify rpc
    AER _  -> doVerify rpc
    RV _   -> doVerify rpc
    RVR _  -> doVerify rpc
    CMDR _ -> doVerify rpc
    _      -> return False
  where
    doVerify rpc' = do
      pks <- view (cfg.publicKeys)
      let mk = (\k -> Map.lookup k pks) =<< senderId rpc'
      maybe
        (debug "RPC has invalid signature" >> return False)
        (\k -> return (verifyWrappedRPC k rpc'))
        mk

verifyRPCWithClientKey :: (Binary nt, Binary et, Binary rt, Ord nt) => RPC nt et rt -> Raft nt et rt mt Bool
verifyRPCWithClientKey rpc =
  case rpc of
    CMD _        -> doVerify rpc
    REVOLUTION _ -> doVerify rpc
    _            -> return False
  where
    doVerify rpc' = do
      pks <- view (cfg.clientPublicKeys)
      let mk = (\k -> Map.lookup k pks) =<< senderId rpc'
      maybe
        (debug "RPC has invalid signature" >> return False)
        (\k -> return (verifyWrappedRPC k rpc'))
        mk

signRPCWithKey :: SigRPC rpc => rpc -> Raft nt et rt mt rpc
signRPCWithKey rpc = do
  pk <- view (cfg.privateKey)
  return (signRPC pk rpc)

updateTerm :: Term -> Raft nt et rt mt ()
updateTerm t = do
  _ <- rs.writeTermNumber ^$ t
  term .= t
