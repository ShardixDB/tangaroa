module Network.Tangaroa.Role
  ( becomeFollower
  , becomeLeader
  , becomeCandidate
  , checkElection
  , setVotedFor
  ) where

import Network.Tangaroa.Timer
import Network.Tangaroa.Types
import Network.Tangaroa.Combinator
import Network.Tangaroa.Util
import Network.Tangaroa.Sender

import Control.Lens hiding (Index)
import Control.Monad
import qualified Data.Map as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set

-- count the yes votes and become leader if you have reached a quorum
checkElection :: Ord nt => Raft nt et rt mt ()
checkElection = do
  nyes <- Set.size <$> use cYesVotes
  qsize <- view quorumSize
  debug $ "yes votes: " ++ show nyes ++ " quorum size: " ++ show qsize
  when (nyes >= qsize) $ becomeLeader

setVotedFor :: Maybe nt -> Raft nt et rt mt ()
setVotedFor mvote = do
  _ <- rs.writeVotedFor ^$ mvote
  votedFor .= mvote

becomeFollower :: Raft nt et rt mt ()
becomeFollower = do
  debug "becoming follower"
  role .= Follower
  resetElectionTimer

becomeCandidate :: Ord nt => Raft nt et rt mt ()
becomeCandidate = do
  debug "becoming candidate"
  role .= Candidate
  term += 1
  rs.writeTermNumber ^=<<. term
  nid <- view (cfg.nodeId)
  setVotedFor $ Just nid
  cYesVotes .= Set.singleton nid -- vote for yourself
  (cPotentialVotes .=) =<< view (cfg.otherNodes)
  resetElectionTimer
  -- this is necessary for a single-node cluster, as we have already won the
  -- election in that case. otherwise we will wait for more votes to check again
  checkElection -- can possibly transition to leader
  r <- use role
  when (r == Candidate) $ fork_ sendAllRequestVotes

becomeLeader :: Ord nt => Raft nt et rt mt ()
becomeLeader = do
  debug "becoming leader"
  role .= Leader
  (currentLeader .=) . Just =<< view (cfg.nodeId)
  ni <- Seq.length <$> use logEntries
  (lNextIndex  .=) =<< Map.fromSet (const ni)         <$> view (cfg.otherNodes)
  (lMatchIndex .=) =<< Map.fromSet (const startIndex) <$> view (cfg.otherNodes)
  fork_ sendAllAppendEntries
  resetHeartbeatTimer
