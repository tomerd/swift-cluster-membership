//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import ClusterMembership
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin
#else
import Glibc
#endif
import enum Dispatch.DispatchTimeInterval
import Logging

/// # SWIM (Scalable Weakly-consistent Infection-style Process Group Membership Protocol).
///
/// SWIM serves as a low-level distributed failure detector mechanism.
/// It also maintains its own membership in order to monitor and select nodes to ping with periodic health checks,
/// however this membership is not directly the same as the high-level membership exposed by the `Cluster`.
///
/// SWIM is first and foremost used to determine if nodes are reachable or not (in SWIM terms if they are `.dead`),
/// it can also serve as a primitive p2p discovery mechanism, since the peers spread gossip about each other, and via
/// this mechanism new members are able to notice members which they were previously not aware of.
///
/// Cluster members may be discovered though SWIM gossip, yet will be asked to participate in the high-level
/// cluster membership as driven by the `ClusterShell`.
///
/// ### Properties
///
/// #### Time Bounded Completeness
/// The time interval between the occurrence of a failure and its detection at member is no more than two times the
/// group size (in number of protocol periods).
///
/// ### See Also
/// - SeeAlso: `SWIM.Instance` for a detailed discussion on the implementation.
/// - SeeAlso: `SWIMNIO.Shell` for an example interpretation and driving the interactions.
public enum SWIM {}

public protocol SWIMProtocol {
    /// Must be invoked periodically, in intervals of `self.swim.dynamicLHMProtocolInterval`.
    ///
    /// Periodically
    ///
    /// - Returns:
    mutating func onPeriodicPingTick() -> [SWIM.Instance.PeriodicPingTickDirective]

    /// Must be invoked whenever a `Ping` message is received.
    ///
    /// A specific shell implementation must the returned directives by acting on them.
    /// The order of interpreting the events should be as returned by the onPing invocation.
    ///
    // TODO: more docs
    ///
    /// - Parameter payload:
    /// - Returns:
    mutating func onPing(pingOrigin: SWIMAddressablePeer, payload: SWIM.GossipPayload, sequenceNumber: SWIM.SequenceNumber) -> [SWIM.Instance.PingDirective]

    /// Must be invoked when a `pingRequest` is received.
    ///
    // TODO: more docs
    ///
    /// - Parameters:
    ///   - target:
    ///   - replyTo:
    ///   - payload:
    /// - Returns:
    mutating func onPingRequest(target: SWIMPeer, replyTo: SWIMPingOriginPeer, payload: SWIM.GossipPayload) -> [SWIM.Instance.PingRequestDirective]

    /// Must be invoked when a ping response, timeout, or error for a specific ping is received.
    ///
    // TODO: more docs
    ///
    /// - Parameters:
    ///   - response:
    ///   - pingRequestOrigin:
    /// - Returns:
    mutating func onPingResponse(response: SWIM.PingResponse, pingRequestOrigin: SWIMPingOriginPeer?) -> [SWIM.Instance.PingResponseDirective]

    /// Must be invoked whenever a successful response to a `pingRequest` happens or all of `pingRequest`'s fail.
    ///
    // TODO: more docs
    ///
    /// - Parameters:
    ///   - response:
    ///   - member:
    /// - Returns:
    mutating func onPingRequestResponse(_ response: SWIM.PingResponse, pingedMember member: SWIMAddressablePeer) -> [SWIM.Instance.PingRequestResponseDirective]

    /// Must be invoked whenever a response to a `pingRequest` (an ack, nack or lack response i.e. a timeout) happens.
    ///
    /// This function is adjusting Local Health and MUST be invoked on _every_ received response to a pingRequest,
    /// in order for the local health adjusted timeouts to be calculated correctly.
    ///
    // TODO: more docs
    ///
    /// - Parameters:
    ///   - response:
    ///   - member:
    mutating func onEveryPingRequestResponse(_ response: SWIM.PingResponse, pingedMember member: SWIMAddressablePeer)

    /// Optional, only relevant when using `settings.unreachable` status mode (which is disabled by default).
    ///
    /// When `.unreachable` members are allowed, this function MUST be invoked to promote a node into `.dead` state.
    ///
    /// In other words, once a `MemberStatusChangedEvent` for an unreachable member has been emitted,
    /// a higher level system may take additional action and then determine when to actually confirm it dead.
    /// Systems can implement additional split-brain prevention mechanisms on those layers for example.
    ///
    /// Once a node is determined dead by such higher level system, it may invoked `swim.confirmDead(peer: theDefinitelyDeadPeer`,
    /// to mark the node as dead, with all of its consequences.
    ///
    /// - Parameter peer: the peer which should be confirmed dead.
    /// - Returns: a directive explaining what action was taken, and should be taken in response to this action.
    mutating func confirmDead(peer: SWIMAddressablePeer) -> SWIM.Instance.ConfirmDeadDirective
}

extension SWIM {
    /// # SWIM (Scalable Weakly-consistent Infection-style Process Group Membership Protocol)
    ///
    /// > As you swim lazily through the milieu,
    /// > The secrets of the world will infect you.
    ///
    /// Implementation of the SWIM protocol in abstract terms, not dependent on any specific runtime.
    ///
    /// ### Extensions
    /// - Random, stable order members to ping selection: Unlike the completely random selection in the original paper.
    ///
    /// ### Related Papers
    /// - SeeAlso: [SWIM: Scalable Weakly-consistent Infection-style Process Group Membership Protocol](https://www.cs.cornell.edu/projects/Quicksilver/public_pdfs/SWIM.pdf)
    /// - SeeAlso: [Lifeguard: Local Health Awareness for More Accurate Failure Detection](https://arxiv.org/abs/1707.00788)
    public final class Instance: SWIMProtocol { // FIXME: make it a struct?
        public let settings: SWIM.Settings

        // We store the owning SWIMShell peer in order avoid adding it to the `membersToPing` list
        private let myself: SWIMPeer

        private var node: ClusterMembership.Node {
            self.myself.node
        }

        /// Cluster `Member` representing this instance.
        public var myselfMember: SWIM.Member {
            self.member(for: self.node)!
        }

        /// Main members storage, map to values to obtain current members.
        internal var members: [ClusterMembership.Node: SWIM.Member]

        /// List of members maintained in random yet stable order, see `addMember` for details.
        internal var membersToPing: [SWIM.Member]
        /// Constantly mutated by `nextMemberToPing` in an effort to keep the order in which we ping nodes evenly distributed.
        private var _membersToPingIndex: Int = 0
        private var membersToPingIndex: Int {
            self._membersToPingIndex
        }

        private var _sequenceNumber: SWIM.SequenceNumber = 0
        /// Sequence numbers are used to identify messages and pair them up into request/replies.
        /// - SeeAlso: `SWIM.SequenceNumber`
        // TODO: make internal?
        // TODO: sequence numbers per-target node? https://github.com/apple/swift-cluster-membership/issues/39
        public func nextSequenceNumber() -> SWIM.SequenceNumber {
            self._sequenceNumber += 1
            return self._sequenceNumber
        }

        /// Lifeguard IV.A. Local Health Multiplier (LHM)
        /// > These different sources of feedback are combined in a Local Health Multiplier (LHM).
        /// > LHM is a saturating counter, with a max value S and min value zero, meaning it will not
        /// > increase above S or decrease below zero.
        ///
        /// Local health multiplier is designed to relax the probeInterval and pingTimeout.
        /// The multiplier will be increased in a following cases:
        /// - When local node needs to refute a suspicion about itself
        /// - When ping-req is missing nack
        /// - When probe is failed
        ///  Each of the above may indicate that local instance is not processing incoming messages in timely order.
        /// The multiplier will be decreased when:
        /// - Ping succeeded with an ack.
        /// Events which cause the specified changes to the LHM counter are defined as `SWIM.LHModifierEvent`
        public var localHealthMultiplier = 0

        public var dynamicLHMProtocolInterval: DispatchTimeInterval {
            .nanoseconds(Int(self.settings.probeInterval.nanoseconds * Int64(1 + self.localHealthMultiplier)))
        }

        public var dynamicLHMPingTimeout: DispatchTimeInterval {
            .nanoseconds(Int(self.settings.pingTimeout.nanoseconds * Int64(1 + self.localHealthMultiplier)))
        }

        /// The incarnation number is used to get a sense of ordering of events, so if an `.alive` or `.suspect`
        /// state with a lower incarnation than the one currently known by a node is received, it can be dropped
        /// as outdated and we don't accidentally override state with older events. The incarnation can only
        /// be incremented by the respective node itself and will happen if that node receives a `.suspect` for
        /// itself, to which it will respond with an `.alive` with the incremented incarnation.
        public var incarnation: SWIM.Incarnation {
            self._incarnation
        }

        private var _incarnation: SWIM.Incarnation = 0

        /// Creates a new SWIM algorithm instance.
        public init(settings: SWIM.Settings, myself: SWIMPeer) {
            self.settings = settings
            self.myself = myself
            self.members = [:]
            self.membersToPing = []
            _ = self.addMember(myself, status: .alive(incarnation: 0))
        }

        func makeSuspicion(incarnation: SWIM.Incarnation) -> SWIM.Status {
            .suspect(incarnation: incarnation, suspectedBy: [self.node])
        }

        func mergeSuspicions(suspectedBy: Set<ClusterMembership.Node>, previouslySuspectedBy: Set<ClusterMembership.Node>) -> Set<ClusterMembership.Node> {
            var newSuspectedBy = previouslySuspectedBy
            for suspectedBy in suspectedBy.sorted() where newSuspectedBy.count < self.settings.lifeguard.maxIndependentSuspicions {
                newSuspectedBy.update(with: suspectedBy)
            }
            return newSuspectedBy
        }

        /// Adjust the Local Health-aware Multiplier based on the event causing it.
        ///
        /// - Parameter event: event which causes the LHM adjustment.
        public func adjustLHMultiplier(_ event: LHModifierEvent) {
            self.localHealthMultiplier =
                min(
                    max(0, self.localHealthMultiplier + event.lhmAdjustment),
                    self.settings.lifeguard.maxLocalHealthMultiplier
                )
        }

        // The protocol period represents the number of times we have pinged a random member
        // of the cluster. At the end of every ping cycle, the number will be incremented.
        // Suspicion timeouts are based on the protocol period, i.e. if a probe did not
        // reply within any of the `suspicionTimeoutPeriodsMax` rounds, it would be marked as `.suspect`.
        private var _protocolPeriod: Int = 0

        /// In order to speed up the spreading of "fresh" rumors, we order gossips in their "number of times gossiped",
        /// and thus are able to easily pick the least spread rumor and pick it for the next gossip round.
        ///
        /// This is tremendously important in order to spread information about e.g. newly added members to others,
        /// before members which are aware of them could have a chance to all terminate, leaving the rest of the cluster
        /// unaware about those new members. For disseminating suspicions this is less urgent, however also serves as an
        /// useful optimization.
        ///
        /// - SeeAlso: SWIM 4.1. Infection-Style Dissemination Component
        private var _messagesToGossip: Heap<SWIM.Gossip> = Heap(
            comparator: {
                $0.numberOfTimesGossiped < $1.numberOfTimesGossiped
            }
        )

        // FIXME: disallow adding peers with no UID?
        public func addMember(_ peer: SWIMAddressablePeer, status: SWIM.Status) -> AddMemberDirective {
            let maybeExistingMember = self.member(for: peer)

            if let existingMember = maybeExistingMember, existingMember.status.supersedes(status) {
                // we already have a newer state for this member
                return .newerMemberAlreadyPresent(existingMember)
            }

            // just in case we had a peer added manually, and thus we did not know its uuid, let us remove it
            _ = self.members.removeValue(forKey: self.node.withoutUID)

            let member = SWIM.Member(peer: peer, status: status, protocolPeriod: self.protocolPeriod)
            self.members[member.node] = member

            if maybeExistingMember == nil, self.notMyself(member) {
                // We know this is a new member.
                //
                // Newly added members are inserted at a random spot in the list of members
                // to ping, to have a better distribution of messages to this node from all
                // other nodes. If for example all nodes would add it to the end of the list,
                // it would take a longer time until it would be pinged for the first time
                // and also likely receive multiple pings within a very short time frame.
                let insertIndex = Int.random(in: self.membersToPing.startIndex ... self.membersToPing.endIndex)
                self.membersToPing.insert(member, at: insertIndex)
                if insertIndex <= self.membersToPingIndex {
                    // If we inserted the new member before the current `membersToPingIndex`,
                    // we need to advance the index to avoid pinging the same member multiple
                    // times in a row. This is especially critical when inserting a larger
                    // number of members, e.g. when the cluster is just being formed, or
                    // on a rolling restart.
                    self.advanceMembersToPingIndex()
                }
            }

            // upon each membership change we reset the gossip counters
            // such that nodes have a chance to be notified about others,
            // even if a node joined an otherwise quiescent cluster.
            self.resetGossipPayloads(member: member)

            return .added(member)
        }

        public enum AddMemberDirective {
            /// Informs an implementation that a new member was added and now has the following state.
            /// An implementation should react to this
            case added(SWIM.Member)
            case newerMemberAlreadyPresent(SWIM.Member)
        }

        /// Implements the round-robin yet shuffled member to probe selection as proposed in the SWIM paper.
        ///
        /// This mechanism should reduce the time until state is spread across the whole cluster,
        /// by guaranteeing that each node will be gossiped to within N cycles (where N is the cluster size).
        ///
        /// - Note:
        ///   SWIM 4.3: [...] The failure detection protocol at member works by maintaining a list (intuitively, an array) of the known
        ///   elements of the current membership list, and select-ing ping targets not randomly from this list,
        ///   but in a round-robin fashion. Instead, a newly joining member is inserted in the membership list at
        ///   a position that is chosen uniformly at random. On completing a traversal of the entire list,
        ///   rearranges the membership list to a random reordering.
        public func nextMemberToPing() -> SWIMAddressablePeer? {
            if self.membersToPing.isEmpty {
                return nil
            }

            defer {
                self.advanceMembersToPingIndex()
            }
            return self.membersToPing[self.membersToPingIndex].peer
        }

        /// Selects `settings.indirectProbeCount` members to send a `ping-req` to.
        func membersToPingRequest(target: SWIMAddressablePeer) -> ArraySlice<SWIM.Member> {
            func notTarget(_ peer: SWIMAddressablePeer) -> Bool {
                peer.node != target.node
            }

            func isReachable(_ status: SWIM.Status) -> Bool {
                status.isAlive || status.isSuspect
            }

            let candidates = self.members
                .values
                .filter {
                    notTarget($0.peer) && notMyself($0.peer) && isReachable($0.status)
                }
                .shuffled()

            return candidates.prefix(self.settings.indirectProbeCount)
        }

        /// Mark a specific peer/member with the new status.
        func mark(_ peer: SWIMAddressablePeer, as status: SWIM.Status) -> MarkedDirective {
            let previousStatusOption = self.status(of: peer)

            var status = status
            var protocolPeriod = self.protocolPeriod
            var suspicionStartedAt: Int64?

            if case .suspect(let incomingIncarnation, let incomingSuspectedBy) = status,
                case .suspect(let previousIncarnation, let previousSuspectedBy)? = previousStatusOption,
                let member = self.member(for: peer),
                incomingIncarnation == previousIncarnation {
                let suspicions = self.mergeSuspicions(suspectedBy: incomingSuspectedBy, previouslySuspectedBy: previousSuspectedBy)
                status = .suspect(incarnation: incomingIncarnation, suspectedBy: suspicions)
                // we should keep old protocol period when member is already a suspect
                protocolPeriod = member.protocolPeriod
                suspicionStartedAt = member.suspicionStartedAt
            } else if case .suspect = status {
                suspicionStartedAt = self.nowNanos()
            } else if case .unreachable = status,
                case .disabled = self.settings.extensionUnreachability {
                // This node is not configured to respect unreachability and thus will immediately promote this status to dead
                // TODO: log warning here
                status = .dead
            }

            if let previousStatus = previousStatusOption, previousStatus.supersedes(status) {
                // we already have a newer status for this member
                return .ignoredDueToOlderStatus(currentStatus: previousStatus)
            }

            let member = SWIM.Member(peer: peer, status: status, protocolPeriod: protocolPeriod, suspicionStartedAt: suspicionStartedAt)
            self.members[peer.node] = member

            if status.isDead {
                self.removeFromMembersToPing(member)
            }

            self.resetGossipPayloads(member: member)

            return .applied(previousStatus: previousStatusOption, member: member)
        }

        enum MarkedDirective: Equatable {
            /// The status that was meant to be set is "old" and was ignored.
            /// We already have newer information about this peer (`currentStatus`).
            case ignoredDueToOlderStatus(currentStatus: SWIM.Status)
            case applied(previousStatus: SWIM.Status?, member: SWIM.Member)
        }

        private func resetGossipPayloads(member: SWIM.Member) {
            // seems we gained a new member, and we need to reset gossip counts in order to ensure it also receive information about all nodes
            // TODO: this would be a good place to trigger a full state sync, to speed up convergence; see https://github.com/apple/swift-cluster-membership/issues/37
            self.allMembers.forEach { self.addToGossip(member: $0) }
        }

        internal func incrementProtocolPeriod() {
            self._protocolPeriod += 1
        }

        func advanceMembersToPingIndex() {
            self._membersToPingIndex = (self._membersToPingIndex + 1) % self.membersToPing.count
        }

        func removeFromMembersToPing(_ member: SWIM.Member) {
            if let index = self.membersToPing.firstIndex(where: { $0.peer.node == member.peer.node }) {
                self.membersToPing.remove(at: index)
                if index < self.membersToPingIndex {
                    self._membersToPingIndex -= 1
                }

                if self.membersToPingIndex >= self.membersToPing.count {
                    self._membersToPingIndex = self.membersToPing.startIndex
                }
            }
        }

        public var protocolPeriod: Int {
            self._protocolPeriod
        }

        /// Debug only. Actual suspicion timeout depends on number of suspicions and calculated in `suspicionTimeout`
        /// This will only show current estimate of how many intervals should pass before suspicion is reached. May change when more data is coming
        var timeoutSuspectsBeforePeriodMax: Int64 {
            self.settings.lifeguard.suspicionTimeoutMax.nanoseconds / self.dynamicLHMProtocolInterval.nanoseconds + 1
        }

        /// Debug only. Actual suspicion timeout depends on number of suspicions and calculated in `suspicionTimeout`
        /// This will only show current estimate of how many intervals should pass before suspicion is reached. May change when more data is coming
        var timeoutSuspectsBeforePeriodMin: Int64 {
            self.settings.lifeguard.suspicionTimeoutMin.nanoseconds / self.dynamicLHMProtocolInterval.nanoseconds + 1
        }

        /// The suspicion timeout is calculated as defined in Lifeguard Section IV.B https://arxiv.org/abs/1707.00788
        /// According to it, suspicion timeout is logarithmically decaying from `suspicionTimeoutPeriodsMax` to `suspicionTimeoutPeriodsMin`
        /// depending on a number of suspicion confirmations.
        ///
        /// Suspicion timeout adjusted according to number of known independent suspicions of given member.
        ///
        /// See: Lifeguard IV-B: Local Health Aware Suspicion
        ///
        /// The timeout for a given suspicion is calculated as follows:
        ///
        /// ```
        ///                                             log(C + 1) 􏰁
        /// SuspicionTimeout =􏰀 max(Min, Max − (Max−Min) ----------)
        ///                                             log(K + 1)
        /// ```
        ///
        /// where:
        /// - `Min` and `Max` are the minimum and maximum Suspicion timeout.
        ///   See Section `V-C` for discussion of their configuration.
        /// - `K` is the number of independent suspicions required to be received before setting the suspicion timeout to `Min`.
        ///   We default `K` to `3`.
        /// - `C` is the number of independent suspicions about that member received since the local suspicion was raised.
        public func suspicionTimeout(suspectedByCount: Int) -> DispatchTimeInterval {
            let minTimeout = self.settings.lifeguard.suspicionTimeoutMin.nanoseconds
            let maxTimeout = self.settings.lifeguard.suspicionTimeoutMax.nanoseconds

            return .nanoseconds(
                Int(
                    max(
                        minTimeout,
                        maxTimeout - Int64(round(Double(maxTimeout - minTimeout) * (log2(Double(suspectedByCount + 1)) / log2(Double(self.settings.lifeguard.maxIndependentSuspicions + 1)))))
                    )
                )
            )
        }

        /// Checks if a deadline is expired (relating to current time).
        public func isExpired(deadline: Int64) -> Bool {
            deadline < self.nowNanos()
        }

        private func nowNanos() -> Int64 {
            self.settings.timeSourceNanos()
        }

        /// Create a gossip payload (i.e. a set of `SWIM.Gossip` messages) that should be gossiped with failure detector
        /// messages, or using some other medium.
        ///
        /// - Parameter target: Allows passing the target peer this gossip will be sent to.
        ///     If gossiping to a specific peer, and given peer is suspect, we will always prioritize
        ///     letting it know that it is being suspected, such that it can refute the suspicion as soon as possible,
        ///     if if still is alive.
        /// - Returns: The gossip payload to be gossiped.
        public func makeGossipPayload(to target: SWIMAddressablePeer?) -> SWIM.GossipPayload {
            var membersToGossipAbout: [SWIM.Member] = []
            // Lifeguard IV. Buddy System
            // Always send to a suspect its suspicion.
            // The reason for that to ensure the suspect will be notified it is being suspected,
            // even if the suspicion has already been disseminated "enough times".
            let targetIsSuspect: Bool
            if let target = target,
                let member = self.member(for: target),
                member.isSuspect {
                // the member is suspect, and we must inform it about this, thus including in gossip payload:
                membersToGossipAbout.append(member)
                targetIsSuspect = true
            } else {
                targetIsSuspect = false
            }

            guard self._messagesToGossip.count > 0 else {
                if membersToGossipAbout.isEmpty {
                    // if we have no pending gossips to share, at least inform the member about our state.
                    return .membership([self.myselfMember])
                } else {
                    return .membership(membersToGossipAbout)
                }
            }

            // In order to avoid duplicates within a single gossip payload, we first collect all messages we need to
            // gossip out and only then re-insert them into `messagesToGossip`. Otherwise, we may end up selecting the
            // same message multiple times, if e.g. the total number of messages is smaller than the maximum gossip
            // size, or for newer messages that have a lower `numberOfTimesGossiped` counter than the other messages.
            var gossipRoundMessages: [SWIM.Gossip] = []
            gossipRoundMessages.reserveCapacity(min(self.settings.gossip.maxNumberOfMessagesPerGossip, self._messagesToGossip.count))
            while gossipRoundMessages.count < self.settings.gossip.maxNumberOfMessagesPerGossip,
                let gossip = self._messagesToGossip.removeRoot() {
                gossipRoundMessages.append(gossip)
            }

            membersToGossipAbout.reserveCapacity(gossipRoundMessages.count)

            for var gossip in gossipRoundMessages {
                if targetIsSuspect, target?.node == gossip.member.node {
                    // We do NOT add gossip to payload if it's a gossip about target and target is suspect,
                    // this case was handled earlier and doing it here will lead to duplicate messages
                    ()
                } else {
                    membersToGossipAbout.append(gossip.member)
                }

                gossip.numberOfTimesGossiped += 1
                if self.settings.gossip.needsToBeGossipedMoreTimes(gossip, members: self.allMembers.count) {
                    self._messagesToGossip.append(gossip)
                }
            }

            return .membership(membersToGossipAbout)
        }

        /// Adds `Member` to gossip messages.
        internal func addToGossip(member: SWIM.Member) {
            // we need to remove old state before we add the new gossip, so we don't gossip out stale state
            self._messagesToGossip.remove(where: { $0.member.peer.node == member.peer.node })
            self._messagesToGossip.append(.init(member: member, numberOfTimesGossiped: 0))
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Member helper functions

extension SWIM.Instance {
    func notMyself(_ member: SWIM.Member) -> Bool {
        self.whenMyself(member) == nil
    }

    func notMyself(_ peer: SWIMAddressablePeer) -> Bool {
        !self.isMyself(peer)
    }

    func isMyself(_ member: SWIM.Member) -> Bool {
        self.whenMyself(member) != nil
    }

    func whenMyself(_ member: SWIM.Member) -> SWIM.Member? {
        if self.isMyself(member.peer) {
            return member
        } else {
            return nil
        }
    }

    func isMyself(_ peer: SWIMAddressablePeer) -> Bool {
        // we are exactly that node:
        self.node == peer.node ||
            // ...or, the incoming node has no UID; there was no handshake made,
            // and thus the other side does not know which specific node it is going to talk to; as such, "we" are that node
            // as such, "we" are that node; we should never add such peer to our members, but we will reply to that node with "us" and thus
            // inform it about our specific UID, and from then onwards it will know about specifically this node (by replacing its UID-less version with our UID-ful version).
            self.node.withoutUID == peer.node
    }

    // TODO: ensure we actually store "us" in members; do we need this special handling if then at all?
    public func status(of peer: SWIMAddressablePeer) -> SWIM.Status? {
        if self.notMyself(peer) {
            return self.members[peer.node]?.status
        } else {
            // we consider ourselves always as alive (enables refuting others suspecting us)
            return .alive(incarnation: self.incarnation)
        }
    }

    /// Checks if the passed in peer is already a known member of the swim cluster.
    ///
    /// Note: `.dead` members are eventually removed from the swim instance and as such peers are not remembered forever!
    ///
    /// - Parameters:
    ///   - peer: Peer to check if it currently is a member
    ///   - ignoreUID: Whether or not to ignore the peers UID, e.g. this is useful when issuing a "join 127.0.0.1:7337"
    ///                command, while being unaware of the nodes specific UID. When it joins, it joins with the specific UID after all.
    /// - Returns: true if the peer is currently a member of the swim cluster (regardless of status it is in)
    public func isMember(_ peer: SWIMAddressablePeer, ignoreUID: Bool = false) -> Bool {
        // the peer could be either:
        self.isMyself(peer) || // 1) "us" (i.e. the peer which hosts this SWIM instance, or
            self.members[peer.node] != nil || // 2) a "known member"
            (ignoreUID && peer.node.uid == nil && self.members.contains {
                // 3) a known member, however the querying peer did not know the real UID of the peer yet
                $0.key.withoutUID == peer.node
            })
    }

    /// Returns specific `SWIM.Member` instance for the passed in peer.
    ///
    /// - Parameter peer: peer whose member should be looked up (by its node identity, including the UID)
    /// - Returns: the peer's member instance, if it currently is a member of this cluster
    public func member(for peer: SWIMAddressablePeer) -> SWIM.Member? {
        self.member(for: peer.node)
    }

    /// Returns specific `SWIM.Member` instance for the passed in node.
    ///
    /// - Parameter node: node whose member should be looked up (matching also by node UID)
    /// - Returns: the peer's member instance, if it currently is a member of this cluster
    public func member(for node: ClusterMembership.Node) -> SWIM.Member? {
        self.members[node]
    }

    /// Count of only non-dead members.
    ///
    /// - SeeAlso: `SWIM.Status`
    public var notDeadMemberCount: Int {
        self.members.lazy.filter {
            !$0.value.isDead
        }.count
    }

    /// Count of all "other" members known to this instance (meaning members other than `myself`).
    public var otherMemberCount: Int {
        self.allMemberCount - 1
    }

    /// Count of all "other" (meaning
    public var allMemberCount: Int {
        max(0, self.members.count)
    }

    /// Lists all `SWIM.Status.suspect` members.
    ///
    /// The `myself` member will never be suspect, as we always assume ourselves to be alive,
    /// even if all other cluster members think otherwise - this is what allows us to refute
    /// suspicions about our unreachability after all.
    ///
    /// - SeeAlso: `SWIM.Status.suspect`
    public var suspects: SWIM.Members {
        self.members
            .lazy
            .map {
                $0.value
            }
            .filter {
                $0.isSuspect
            }
    }

    /// Lists all members known to this SWIM instance currently, potentially including even `.dead` nodes.
    public var allMembers: SWIM.MembersValues {
        self.members.values
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: Handling SWIM protocol interactions

extension SWIM.Instance {
    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: On Periodic Ping Tick Handler

    public func onPeriodicPingTick() -> [PeriodicPingTickDirective] {
        defer {
            self.incrementProtocolPeriod()
        }

        var directives: [PeriodicPingTickDirective] = []

        guard let toPing = self.nextMemberToPing() else {
            return []
        }

        directives.append(contentsOf: self.checkSuspicionTimeouts())
        directives.append(.sendPing(target: toPing as! SWIMPeer, timeout: self.dynamicLHMPingTimeout, sequenceNumber: self.nextSequenceNumber()))
        return directives
    }

    public enum PeriodicPingTickDirective {
        case membershipChanged(SWIM.MemberStatusChangedEvent)
        case sendPing(target: SWIMPeer, timeout: DispatchTimeInterval, sequenceNumber: SWIM.SequenceNumber)
    }

    private func checkSuspicionTimeouts() -> [PeriodicPingTickDirective] {
        var directives: [PeriodicPingTickDirective] = []

        for suspect in self.suspects {
            if case .suspect(_, let suspectedBy) = suspect.status {
                let suspicionTimeout = self.suspicionTimeout(suspectedByCount: suspectedBy.count)
//                self.log.trace(
//                    "Checking suspicion timeout for: \(suspect)...",
//                    metadata: [
//                        "swim/suspect": "\(suspect)",
//                        "swim/suspectedBy": "\(suspectedBy.count)",
//                        "swim/suspicionTimeout": "\(suspicionTimeout)",
//                    ]
//                )

                // proceed with suspicion escalation to .unreachable if the timeout period has been exceeded
                // We don't use Deadline because tests can override TimeSource
                guard let startTime = suspect.suspicionStartedAt,
                    self.isExpired(deadline: startTime + suspicionTimeout.nanoseconds) else {
                    continue // skip, this suspect is not timed-out yet
                }

                guard let incarnation = suspect.status.incarnation else {
                    // suspect had no incarnation number? that means it is .dead already and should be recycled soon
                    continue
                }

                let newStatus: SWIM.Status
                if self.settings.extensionUnreachability == .enabled {
                    newStatus = .unreachable(incarnation: incarnation)
                } else {
                    newStatus = .dead
                }

                switch self.mark(suspect.peer, as: newStatus) {
                case .applied(let previousStatus, let member):
//                    self.log.trace(
//                        "Marked \(latest.node) as \(latest.status), announcing reachability change",
//                        metadata: [
//                            "swim/member": "\(latest)",
//                            "swim/previousStatus": "\(previousStatus, orElse: "nil")",
//                        ]
//                    )
                    directives.append(.membershipChanged(SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: member)))
                case .ignoredDueToOlderStatus:
                    continue
                }
            }
        }

        // metrics.recordSWIM.Members(self.swim.allMembers) // FIXME metrics
        return directives
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: On Ping Handler

    public func onPing(pingOrigin: SWIMAddressablePeer, payload: SWIM.GossipPayload, sequenceNumber: SWIM.SequenceNumber) -> [PingDirective] {
        var directives: [PingDirective]

        // 1) Process gossip
        directives = self.onGossipPayload(payload).map { g in
            .gossipProcessed(g)
        }

        // 2) Prepare reply
        let gossipPayload: SWIM.GossipPayload = self.makeGossipPayload(to: pingOrigin)
        let reply = PingDirective.sendAck(
            myself: self.myself,
            incarnation: self._incarnation,
            payload: gossipPayload,
            sequenceNumber: sequenceNumber
        )
        directives.append(reply)

        return directives
    }

    public enum PingDirective {
        case gossipProcessed(GossipProcessedDirective)
        case sendAck(myself: SWIMAddressablePeer, incarnation: SWIM.Incarnation, payload: SWIM.GossipPayload, sequenceNumber: SWIM.SequenceNumber)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: On Ping Response Handlers

    public func onPingResponse(response: SWIM.PingResponse, pingRequestOrigin: SWIMPingOriginPeer?) -> [PingResponseDirective] {
        switch response {
        case .ack(let target, let incarnation, let payload, let sequenceNumber):
            return self.onPingAckResponse(target: target, incarnation: incarnation, payload: payload, pingRequestOrigin: pingRequestOrigin, sequenceNumber: sequenceNumber)
        case .nack(let target, let sequenceNumber):
            return self.onPingNackResponse(target: target, pingRequestOrigin: pingRequestOrigin, sequenceNumber: sequenceNumber)
        case .timeout(let target, _, let timeout, let sequenceNumber):
            return self.onPingResponseTimeout(target: target, timeout: timeout, pingRequestOrigin: pingRequestOrigin, sequenceNumber: sequenceNumber)
        }
    }

    func onPingAckResponse(
        target pingedNode: SWIMAddressablePeer,
        incarnation: SWIM.Incarnation,
        payload: SWIM.GossipPayload,
        pingRequestOrigin: SWIMPingOriginPeer?,
        sequenceNumber: SWIM.SequenceNumber
    ) -> [PingResponseDirective] {
        var directives: [PingResponseDirective] = []
        // We're proxying an ack payload from ping target back to ping source.
        // If ping target was a suspect, there'll be a refutation in a payload
        // and we probably want to process it asap. And since the data is already here,
        // processing this payload will just make gossip convergence faster.
        let gossipDirectives = self.onGossipPayload(payload)
        directives.append(contentsOf: gossipDirectives.map {
            PingResponseDirective.gossipProcessed($0)
        })

        // self.log.debug("Received ack from [\(pingedNode)] with incarnation [\(incarnation)] and payload [\(payload)]", metadata: self.metadata)
        // The shell is already informed tha the member moved -> alive by the gossipProcessed directive
        _ = self.mark(pingedNode, as: .alive(incarnation: incarnation))

        if let pingRequestOrigin = pingRequestOrigin {
            // pingRequestOrigin.ack(acknowledging: sequenceNumber, target: pingedNode, incarnation: incarnation, payload: payload)
            directives.append(
                .sendAck(
                    peer: pingRequestOrigin,
                    acknowledging: sequenceNumber,
                    target: pingedNode,
                    incarnation: incarnation,
                    payload: payload
                )
            )
        } else {
            self.adjustLHMultiplier(.successfulProbe)
        }

        return directives
    }

    func onPingNackResponse(
        target pingedNode: SWIMAddressablePeer,
        pingRequestOrigin: SWIMPingOriginPeer?,
        sequenceNumber: SWIM.SequenceNumber
    ) -> [PingResponseDirective] {
        let directives: [PingResponseDirective] = []
        () // TODO: nothing???
        return directives
    }

    func onPingResponseTimeout(
        target: SWIMAddressablePeer,
        timeout: DispatchTimeInterval,
        pingRequestOrigin: SWIMPingOriginPeer?,
        sequenceNumber pingResponseSequenceNumber: SWIM.SequenceNumber
    ) -> [PingResponseDirective] {
        // assert(target != myself, "target pinged node MUST NOT equal myself, why would we ping our own node.") // FIXME: can we add this again?
        // self.log.debug("Did not receive ack from \(pingedNode) within configured timeout. Sending ping requests to other members.")

        var directives: [PingResponseDirective] = []
        if let pingRequestOrigin = pingRequestOrigin {
            // Meaning we were doing a ping on behalf of the pingReq origin, and we need to report back to it.
            directives.append(
                .sendNack(
                    peer: pingRequestOrigin,
                    acknowledging: pingResponseSequenceNumber,
                    target: target
                )
            )
        } else {
            // We sent a direct `.ping` and it timed out; we now suspect the target node and must issue additional ping requests.
            guard let pingedMember = self.member(for: target) else {
                return directives // seems we are not aware of this node, ignore it
            }
            guard let pingedMemberLastKnownIncarnation = pingedMember.status.incarnation else {
                return directives // so it is already dead, not need to suspect it
            }

            // The member should become suspect, it missed out ping/ack cycle:
            // we do not inform the shell about -> suspect moves; only unreachable or dead moves are of interest to it.
            _ = self.mark(pingedMember.peer, as: self.makeSuspicion(incarnation: pingedMemberLastKnownIncarnation))

            // adjust the LHM accordingly, we failed a probe (ping/ack) cycle
            self.adjustLHMultiplier(.failedProbe)

            // if we have other peers, we should ping request through them,
            // if not then there's no-one to ping request through and we just continue.
            if let pingRequestDirective = self.preparePingRequests(target: pingedMember.peer as! SWIMPeer) { // as-! safe, because we always store a peer
                directives.append(.sendPingRequests(pingRequestDirective))
            }
        }

        return directives
    }

    /// Prepare ping request directives such that the shell can easily fire those messages
    func preparePingRequests(target: SWIMPeer) -> SendPingRequestDirective? {
        guard let lastKnownStatus = self.status(of: target) else {
            // context.log.info("Skipping ping requests after failed ping to [\(toPing)] because node has been removed from member list") // FIXME allow logging
            return nil
        }

        // select random members to send ping requests to
        let membersToPingRequest = self.membersToPingRequest(target: target)

        guard !membersToPingRequest.isEmpty else {
            // no nodes available to ping, so we have to assume the node suspect right away
            guard let lastKnownIncarnation = lastKnownStatus.incarnation else {
                // log.debug("Not marking .suspect, as [\(target)] is already dead.") // "You are already dead!" // TODO logging
                return nil
            }

            switch self.mark(target, as: self.makeSuspicion(incarnation: lastKnownIncarnation)) {
            case .applied:
                // log.debug("No members to ping-req through, marked [\(target)] immediately as [\(currentStatus)].") // TODO: logging
                return nil
            case .ignoredDueToOlderStatus:
                // log.debug("No members to ping-req through to [\(target)], was already [\(currentStatus)].") // TODO: logging
                return nil
            }
        }

        let details = membersToPingRequest.map { member in
            SendPingRequestDirective.PingRequestDetail(
                memberToPingRequestThrough: member,
                payload: self.makeGossipPayload(to: target),
                sequenceNumber: self.nextSequenceNumber()
            )
        }

        return SendPingRequestDirective(target: target, requestDetails: details)
    }

    public enum PingResponseDirective {
        case gossipProcessed(GossipProcessedDirective)

        /// Send an `ack` message to `peer`
        case sendAck(peer: SWIMPingOriginPeer, acknowledging: SWIM.SequenceNumber, target: SWIMAddressablePeer, incarnation: UInt64, payload: SWIM.GossipPayload)

        /// Send a `nack` to `peer`
        case sendNack(peer: SWIMPingOriginPeer, acknowledging: SWIM.SequenceNumber, target: SWIMAddressablePeer)

        /// Send a `pingRequest` as described by the `SendPingRequestDirective`.
        ///
        /// The target node did not reply with an successful `.ack` and as such was now marked as `.suspect`.
        /// By sending ping requests to other members of the cluster we attempt to revert this suspicion,
        /// perhaps some other node is able to receive an `.ack` from it after all?
        case sendPingRequests(SendPingRequestDirective)
    }

    public struct SendPingRequestDirective {
        public let target: SWIMPeer
        public let requestDetails: [PingRequestDetail]

        public struct PingRequestDetail {
            public let memberToPingRequestThrough: SWIM.Member
            public let payload: SWIM.GossipPayload
            public let sequenceNumber: SWIM.SequenceNumber
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: On Ping Request

    public func onPingRequest(target: SWIMPeer, replyTo: SWIMPingOriginPeer, payload: SWIM.GossipPayload) -> [PingRequestDirective] {
        var directives: [PingRequestDirective] = []

        // 1) Process gossip
        switch payload {
        case .membership(let members):
            directives = members.map { member in
                let directive = self.onGossipPayload(about: member)
                return .gossipProcessed(directive)
            }
        case .none:
            () // ok, no gossip payload
        }

        // 2) Process the ping request itself
        guard self.notMyself(target) else {
            // print("Received ping request about myself, ignoring; target: \(target), replyTo: \(replyTo)") // TODO: log
            directives.append(.ignore)
            return directives
        }

        if !self.isMember(target) {
            // The case when member is a suspect is already handled in `processGossipPayload`,
            // since payload will always contain suspicion about target member; no need to inform the shell again about this
            _ = self.addMember(target, status: .alive(incarnation: 0))
        }
        let pingSequenceNumber = self.nextSequenceNumber()
        // Indirect ping timeout should always be shorter than pingRequest timeout.
        // Setting it to a fraction of initial ping timeout as suggested in the original paper.
        // SeeAlso: [Lifeguard IV.A. Local Health Multiplier (LHM)](https://arxiv.org/pdf/1707.00788.pdf)
        let timeoutNanos = Int(Double(self.settings.pingTimeout.nanoseconds) * self.settings.lifeguard.indirectPingTimeoutMultiplier)
        directives.append(.sendPing(target: target, pingRequestOrigin: replyTo, timeout: .nanoseconds(timeoutNanos), sequenceNumber: pingSequenceNumber))

        return directives
    }

    public enum PingRequestDirective {
        case gossipProcessed(GossipProcessedDirective)
        case ignore
        case sendPing(target: SWIMPeer, pingRequestOrigin: SWIMPingOriginPeer, timeout: DispatchTimeInterval, sequenceNumber: SWIM.SequenceNumber)
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: On Ping Request Response

    /// This should be called on first successful (non-nack) pingRequestResponse
    public func onPingRequestResponse(_ response: SWIM.PingResponse, pingedMember member: SWIMAddressablePeer) -> [PingRequestResponseDirective] {
        guard let previousStatus = self.status(of: member) else {
            // we do not process replies from an unknown member; it likely means we have removed it already for some reason.
            return [.unknownMember]
        }
        var directives: [PingRequestResponseDirective] = []

        switch response {
        case .ack(let target, let incarnation, let payload, _):
            assert(
                target.node == member.node,
                "The ack.from member [\(target)] MUST be equal to the pinged member \(member.node)]; The Ack message is being forwarded back to us from the pinged member."
            )

            let gossipDirectives = self.onGossipPayload(payload)
            directives += gossipDirectives.map {
                PingRequestResponseDirective.gossipProcessed($0)
            }

            switch self.mark(member, as: .alive(incarnation: incarnation)) {
            case .applied:
                directives.append(.alive(previousStatus: previousStatus))
                return directives
            case .ignoredDueToOlderStatus(let currentStatus):
                directives.append(.ignoredDueToOlderStatus(currentStatus: currentStatus))
                return directives
            }
        case .nack:
            // TODO: this should never happen. How do we express it?
            directives.append(.nackReceived)
            return directives

        case .timeout:
            switch previousStatus {
            case .alive(let incarnation),
                 .suspect(let incarnation, _):
                switch self.mark(member, as: self.makeSuspicion(incarnation: incarnation)) {
                case .applied:
                    directives.append(.newlySuspect(previousStatus: previousStatus, suspect: self.member(for: member.node)!))
                    return directives
                case .ignoredDueToOlderStatus(let status):
                    directives.append(.ignoredDueToOlderStatus(currentStatus: status))
                    return directives
                }
            case .unreachable:
                directives.append(.alreadyUnreachable)
                return directives
            case .dead:
                directives.append(.alreadyDead)
                return directives
            }
        }
    }

    public func onEveryPingRequestResponse(_ result: SWIM.PingResponse, pingedMember member: SWIMAddressablePeer) {
        switch result {
        case .timeout:
            // Failed pingRequestResponse indicates a missed nack, we should adjust LHMultiplier
            self.adjustLHMultiplier(.probeWithMissedNack)
        default:
            () // Successful pingRequestResponse should be handled only once (and thus in `onPingRequestResponse` only)
        }
    }

    public enum PingRequestResponseDirective {
        case gossipProcessed(GossipProcessedDirective)

        case alive(previousStatus: SWIM.Status) // TODO: offer a membership change option rather?
        case nackReceived
        /// Indicates that the `target` of the ping response is not known to this peer anymore,
        /// it could be that we already marked it as dead and removed it.
        ///
        /// No additional action, except optionally some debug logging should be performed.
        case unknownMember
        case newlySuspect(previousStatus: SWIM.Status, suspect: SWIM.Member)
        case alreadySuspect
        case alreadyUnreachable
        case alreadyDead
        /// The incoming gossip is older than already known information about the target peer (by incarnation), and was (safely) ignored.
        /// The current status of the peer is as returned in `currentStatus`.
        case ignoredDueToOlderStatus(currentStatus: SWIM.Status)
    }

    internal func onGossipPayload(_ payload: SWIM.GossipPayload) -> [GossipProcessedDirective] {
        switch payload {
        case .none:
            return []
        case .membership(let members):
            return members.map { member in
                self.onGossipPayload(about: member)
            }
        }
    }

    internal func onGossipPayload(about member: SWIM.Member) -> GossipProcessedDirective {
        if self.isMyself(member) {
            return self.onMyselfGossipPayload(myself: member)
        } else {
            return self.onOtherMemberGossipPayload(member: member)
        }
    }

    /// ### Unreachability status handling
    /// Performs all special handling of `.unreachable` such that if it is disabled members are automatically promoted to `.dead`.
    /// See `settings.unreachability` for more details.
    private func onMyselfGossipPayload(myself incoming: SWIM.Member) -> SWIM.Instance.GossipProcessedDirective {
        assert(
            self.myself.node == incoming.peer.node,
            """
            Attempted to process gossip as-if about myself, but was not the same peer, was: \(incoming.peer.node.detailedDescription). \
            Myself: \(self.myself)
            SWIM.Instance: \(self)
            """
        )

        // Note, we don't yield changes for myself node observations, thus the self node will never be reported as unreachable,
        // after all, we can always reach ourselves. We may reconsider this if we wanted to allow SWIM to inform us about
        // the fact that many other nodes think we're unreachable, and thus we could perform self-downing based upon this information // TODO: explore self-downing driven from SWIM

        switch incoming.status {
        case .alive:
            // as long as other nodes see us as alive, we're happy
            return .applied(change: nil)
        case .suspect(let suspectedInIncarnation, _):
            // someone suspected us, so we need to increment our incarnation number to spread our alive status with
            // the incremented incarnation
            if suspectedInIncarnation == self.incarnation {
                self.adjustLHMultiplier(.refutingSuspectMessageAboutSelf)
                self._incarnation += 1
                // refute the suspicion, we clearly are still alive
                self.addToGossip(member: SWIM.Member(peer: self.myself, status: .alive(incarnation: self._incarnation), protocolPeriod: self.protocolPeriod))
                return .applied(change: nil)
            } else if suspectedInIncarnation > self.incarnation {
                return .applied(
                    change: nil,
                    level: .warning,
                    message: """
                    Received gossip about self with incarnation number [\(suspectedInIncarnation)] > current incarnation [\(self._incarnation)], \
                    which should never happen and while harmless is highly suspicious, please raise an issue with logs. This MAY be an issue in the library.
                    """
                )
            } else {
                // incoming incarnation was < than current one, i.e. the incoming information is "old" thus we discard it
                return .ignored
            }

        case .unreachable(let unreachableInIncarnation):
            switch self.settings.extensionUnreachability {
            case .enabled:
                // someone suspected us,
                // so we need to increment our incarnation number to spread our alive status with the incremented incarnation
                if unreachableInIncarnation == self.incarnation {
                    self._incarnation += 1
                    return .ignored
                } else if unreachableInIncarnation > self.incarnation {
                    return .applied(
                        change: nil,
                        level: .warning,
                        message: """
                        Received gossip about self with incarnation number [\(unreachableInIncarnation)] > current incarnation [\(self._incarnation)], \
                        which should never happen and while harmless is highly suspicious, please raise an issue with logs. This MAY be an issue in the library.
                        """
                    )
                } else {
                    return .ignored(level: .debug, message: "Incoming .unreachable about myself, however current incarnation [\(self.incarnation)] is greater than incoming \(incoming.status)")
                }

            case .disabled:
                // we don't use unreachable states, and in any case, would not apply it to myself
                // as we always consider "us" to be reachable after all
                return .ignored
            }

        case .dead:
            guard var myselfMember = self.member(for: self.myself) else {
                return .applied(change: nil)
            }

            myselfMember.status = .dead
            switch self.mark(self.myself, as: .dead) {
            case .applied(.some(let previousStatus), _):
                return .applied(change: .init(previousStatus: previousStatus, member: myselfMember))
            default:
                return .ignored(level: .warning, message: "Self already marked .dead")
            }
        }
    }

    /// ### Unreachability status handling
    /// Performs all special handling of `.unreachable` such that if it is disabled members are automatically promoted to `.dead`.
    /// See `settings.unreachability` for more details.
    private func onOtherMemberGossipPayload(member: SWIM.Member) -> SWIM.Instance.GossipProcessedDirective {
        assert(self.node != member.node, "Attempted to process gossip as-if not-myself, but WAS same peer, was: \(member). Myself: \(self.myself, orElse: "nil")")

        guard self.isMember(member.peer) else {
            // it's a new node it seems
            if member.node.uid != nil {
                // only accept new nodes with their UID set.
                //
                // the Shell may need to set up a connection if we just made a move from previousStatus: nil,
                // so we definitely need to emit this change
                switch self.addMember(member.peer, status: member.status) {
                case .added(let member):
                    return .applied(change: SWIM.MemberStatusChangedEvent(previousStatus: nil, member: member))
                case .newerMemberAlreadyPresent(let member):
                    return .applied(change: SWIM.MemberStatusChangedEvent(previousStatus: nil, member: member))
                }
            } else {
                return .ignored
            }
        }

        switch self.mark(member.peer, as: member.status) {
        case .applied(let previousStatus, let member):
            // FIXME: if we allow the instance to log this is not longer an if/else
            if member.status.isSuspect, previousStatus?.isAlive ?? false {
                return .applied(
                    change: .init(previousStatus: previousStatus, member: member),
                    level: .debug,
                    message: "Member [\(member.peer.node, orElse: "<unknown-node>")] marked as suspect, via incoming gossip"
                )
            } else {
                return .applied(change: .init(previousStatus: previousStatus, member: member))
            }

        case .ignoredDueToOlderStatus(let currentStatus):
            return .ignored(
                level: .trace,
                message: "Gossip about member \(reflecting: member.node), incoming: [\(member.status)] does not supersede current: [\(currentStatus)]"
            )
        }
    }

    public enum GossipProcessedDirective {
        /// The gossip was applied to the local membership view and an event may want to be emitted for it.
        ///
        /// It is up to the shell implementation which events are published, but generally it is recommended to
        /// only publish changes which are `SWIM.MemberStatusChangedEvent.isReachabilityChange` as those can and should
        /// usually be acted on by high level implementations.
        ///
        /// Changes between alive and suspect are an internal implementation detail of SWIM,
        /// and usually do not need to be emitted as events to users.
        ///
        /// ### Note for connection based implementations
        /// You may need to establish a new connection if the changes' `previousStatus` is `nil`, as it means we have
        /// not seen this member before and in order to send messages to it, one may want to eagerly establish a connection to it.
        case applied(change: SWIM.MemberStatusChangedEvent?, level: Logger.Level?, message: Logger.Message?)
        /// Ignoring a gossip update is perfectly fine: it may be "too old" or other reasons
        case ignored(level: Logger.Level?, message: Logger.Message?) // TODO: allow the instance to log

        static func applied(change: SWIM.MemberStatusChangedEvent?) -> SWIM.Instance.GossipProcessedDirective {
            .applied(change: change, level: nil, message: nil)
        }

        static var ignored: SWIM.Instance.GossipProcessedDirective {
            .ignored(level: nil, message: nil)
        }
    }

    // ==== ------------------------------------------------------------------------------------------------------------
    // MARK: Confirm Dead

    public func confirmDead(peer: SWIMAddressablePeer) -> ConfirmDeadDirective {
        guard let member = self.member(for: peer) else {
            return .ignored
        }

        guard !member.isDead else {
            // the member seems to be already dead, no need to mark it dead again
            return .ignored
        }

        switch self.mark(peer, as: .dead) {
        case .applied(let previousStatus, let member):
            return .applied(change: SWIM.MemberStatusChangedEvent(previousStatus: previousStatus, member: member))

        case .ignoredDueToOlderStatus:
            return .ignored // it was already dead for example
        }
    }

    public enum ConfirmDeadDirective {
        /// The change was applied and caused a membership change.
        ///
        /// The change should be emitted as an event by an interpreting shell.
        case applied(change: SWIM.MemberStatusChangedEvent)

        /// The confirmation had not effect, either the peer was not known, or is already dead.
        case ignored
    }
}

extension SWIM.Instance: CustomDebugStringConvertible {
    public var debugDescription: String {
        // multi-line on purpose
        """
        SWIM.Instance(
            settings: \(settings),
            
            myself: \(String(reflecting: myself)),
                                
            _incarnation: \(_incarnation),
            _protocolPeriod: \(_protocolPeriod), 

            members: [
                \(members.map { "\($0.key)" }.joined(separator: "\n        "))
            ] 
            membersToPing: [ 
                \(membersToPing.map { "\($0)" }.joined(separator: "\n        "))
            ]
             
            _messagesToGossip: \(_messagesToGossip)
        )
        """
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Lifeguard Local Health Modifier event

extension SWIM.Instance {
    /// Events which cause the modification of the Local health aware Multiplier to be adjusted.
    ///
    /// - SeeAlso: Lifeguard IV.A. Local Health Aware Probe, which describes the rationale behind the events.
    public enum LHModifierEvent: Equatable {
        case successfulProbe
        case failedProbe
        case refutingSuspectMessageAboutSelf
        case probeWithMissedNack

        /// - Returns: by how much the LHM should be adjusted in response to this event.
        ///   The adjusted value MUST be clamped between `0 <= value <= maxLocalHealthMultiplier`
        var lhmAdjustment: Int {
            switch self {
            case .successfulProbe:
                return -1 // decrease the LHM
            case .failedProbe,
                 .refutingSuspectMessageAboutSelf,
                 .probeWithMissedNack:
                return 1 // increase the LHM
            }
        }
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Logging Metadata

extension SWIM.Instance {
    public func metadata(_ additional: Logger.Metadata) -> Logger.Metadata {
        var metadata = self.metadata
        metadata.merge(additional, uniquingKeysWith: { _, r in r })
        return metadata
    }

    /// While the SWIM.Instance is not meant to be logging by itself, it does offer metadata for loggers to use.
    public var metadata: Logger.Metadata {
        [
            "swim/protocolPeriod": "\(self.protocolPeriod)",
            "swim/timeoutSuspectsBeforePeriodMax": "\(self.timeoutSuspectsBeforePeriodMax)",
            "swim/timeoutSuspectsBeforePeriodMin": "\(self.timeoutSuspectsBeforePeriodMin)",
            "swim/incarnation": "\(self.incarnation)",
            "swim/members/all": Logger.Metadata.Value.array(self.allMembers.map { "\($0)" }),
            "swim/members/count": "\(self.notDeadMemberCount)",
            "swim/suspects/count": "\(self.suspects.count)",
        ]
    }
}
