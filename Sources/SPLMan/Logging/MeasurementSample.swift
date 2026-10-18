import Foundation

enum MeasurementSampleState: String, Codable, Sendable {
    case valid = "Valid"
    case invalid = "Invalid"
}

struct MeasurementSample: Sendable {
    let sessionID: UUID
    let timestamp: Date
    let completedSecondCount: UInt64
    let processedFrameCount: UInt64
    let state: MeasurementSampleState
    let stateReason: String?
    let laeq1Second: Double?
    let lceq1Second: Double?
    let lzeq1Second: Double?
    let lafMax1Second: Double?
    let lasMax1Second: Double?
    let lcPeak1Second: Double?
    let laeq30Minutes: Double?
    let lceq30Minutes: Double?
    let laeq1Minute: Double?
    let laeq10Minutes: Double?
    let laeq15Minutes: Double?
    let lceq1Minute: Double?
    let lceq10Minutes: Double?
    let aSlow: Double?
    let cSlow: Double?
    let cMinusA1Minute: Double?
    let cMinusA10Minutes: Double?
    let cMinusASlow: Double?

    init(
        sessionID: UUID,
        timestamp: Date,
        completedSecondCount: UInt64,
        processedFrameCount: UInt64,
        state: MeasurementSampleState,
        stateReason: String? = nil,
        laeq1Second: Double?,
        lceq1Second: Double?,
        lzeq1Second: Double? = nil,
        lafMax1Second: Double?,
        lasMax1Second: Double? = nil,
        lcPeak1Second: Double?,
        laeq30Minutes: Double? = nil,
        lceq30Minutes: Double? = nil,
        laeq1Minute: Double? = nil,
        laeq10Minutes: Double? = nil,
        laeq15Minutes: Double? = nil,
        lceq1Minute: Double? = nil,
        lceq10Minutes: Double? = nil,
        aSlow: Double? = nil,
        cSlow: Double? = nil,
        cMinusA1Minute: Double? = nil,
        cMinusA10Minutes: Double? = nil,
        cMinusASlow: Double? = nil
    ) {
        self.sessionID = sessionID
        self.timestamp = timestamp
        self.completedSecondCount = completedSecondCount
        self.processedFrameCount = processedFrameCount
        self.state = state
        self.stateReason = stateReason
        self.laeq1Second = laeq1Second
        self.lceq1Second = lceq1Second
        self.lzeq1Second = lzeq1Second
        self.lafMax1Second = lafMax1Second
        self.lasMax1Second = lasMax1Second
        self.lcPeak1Second = lcPeak1Second
        self.laeq30Minutes = laeq30Minutes
        self.lceq30Minutes = lceq30Minutes
        self.laeq1Minute = laeq1Minute
        self.laeq10Minutes = laeq10Minutes
        self.laeq15Minutes = laeq15Minutes
        self.lceq1Minute = lceq1Minute
        self.lceq10Minutes = lceq10Minutes
        self.aSlow = aSlow
        self.cSlow = cSlow
        self.cMinusA1Minute = cMinusA1Minute
        self.cMinusA10Minutes = cMinusA10Minutes
        self.cMinusASlow = cMinusASlow
    }
}

struct MeasurementGap: Sendable {
    let sessionID: UUID
    let startedAt: Date
    let endedAt: Date
    let lostSecondIntervals: UInt64
    let reason: String

    init(
        sessionID: UUID,
        startedAt: Date,
        endedAt: Date,
        lostSecondIntervals: UInt64,
        reason: String
    ) {
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lostSecondIntervals = lostSecondIntervals
        self.reason = reason
    }
}
