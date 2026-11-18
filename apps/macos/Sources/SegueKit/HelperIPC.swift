import SegueHelperProtocol

/// Wire types live in `SegueHelperProtocol` so the menu and the root helper
/// share one contract. These aliases are the SegueKit surface callers already
/// import. `HelperClient` is what opens the helper socket.

public typealias HelperProtocolVersion = SegueHelperProtocol.HelperProtocolVersion
public typealias HelperProtocolError = SegueHelperProtocol.HelperProtocolError
public typealias HelperErrorCode = SegueHelperProtocol.HelperErrorCode
public typealias AILayerState = SegueHelperProtocol.AILayerState
public typealias HelperMessageKind = SegueHelperProtocol.HelperMessageKind
public typealias ArmIntentName = SegueHelperProtocol.ArmIntentName
public typealias DisarmReason = SegueHelperProtocol.DisarmReason
public typealias EgressEndpoint = SegueHelperProtocol.EgressEndpoint
public typealias ArmEvidence = SegueHelperProtocol.ArmEvidence
public typealias ArmIntent = SegueHelperProtocol.ArmIntent
public typealias DisarmIntent = SegueHelperProtocol.DisarmIntent
public typealias StatusEvidence = SegueHelperProtocol.StatusEvidence
public typealias HelperProcessReport = SegueHelperProtocol.HelperProcessReport
public typealias KernelReport = SegueHelperProtocol.KernelReport
public typealias HelperErrorBody = SegueHelperProtocol.HelperErrorBody
public typealias HelperStatus = SegueHelperProtocol.HelperStatus
public typealias HelperEnvelope = SegueHelperProtocol.HelperEnvelope
