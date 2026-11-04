import Foundation

struct TransferFunctionDisplayState {
    static let curveRetentionDuration: TimeInterval = 1
    // Three seconds spans several normal analysis blocks, hiding transient worker delays
    // without leaving a stalled result on screen indefinitely.
    static let maximumAnalysisSilenceDuration: TimeInterval = 3

    private var retainedCurve: TransferFunctionCurve?
    private var retentionDeadline: TimeInterval?
    private var currentInvalidity: TransferFunctionValidity = .waitingForSignal
    private var lastValidAnalysisUptime: TimeInterval?
    private var lastInputActivityUptime: TimeInterval?
    private var acceptsInputActivity = false
    private var lastUpdateUptime: TimeInterval?

    mutating func update(
        with analysis: TransferFunctionAnalysis,
        at uptime: TimeInterval
    ) -> TransferFunctionAnalysis {
        guard prepareForUpdate(at: uptime) else { return analysis }

        if let curve = analysis.curve {
            retainedCurve = curve
            retentionDeadline = uptime + Self.curveRetentionDuration
            currentInvalidity = .waitingForSignal
            lastValidAnalysisUptime = uptime
            lastInputActivityUptime = nil
            acceptsInputActivity = true
            return analysis
        }

        currentInvalidity = analysis.validity
        acceptsInputActivity = false
        if let lastValidAnalysisUptime {
            retentionDeadline = lastValidAnalysisUptime + Self.curveRetentionDuration
        }
        guard let retainedCurve,
              let retentionDeadline,
              uptime < retentionDeadline else {
            clearRetainedCurve()
            return analysis
        }
        return TransferFunctionAnalysis(
            validity: analysis.validity,
            curve: retainedCurve
        )
    }

    mutating func noteInputActivity(capturedAtUptime: TimeInterval) {
        guard capturedAtUptime.isFinite,
              acceptsInputActivity,
              retainedCurve != nil,
              let lastValidAnalysisUptime,
              capturedAtUptime >= lastValidAnalysisUptime,
              capturedAtUptime <= lastValidAnalysisUptime
                + Self.maximumAnalysisSilenceDuration,
              lastInputActivityUptime.map({ capturedAtUptime > $0 }) != false else { return }

        lastInputActivityUptime = capturedAtUptime
        let analysisDeadline = lastValidAnalysisUptime
            + Self.maximumAnalysisSilenceDuration
        let activityDeadline = capturedAtUptime + Self.curveRetentionDuration
        retentionDeadline = min(
            analysisDeadline,
            max(retentionDeadline ?? activityDeadline, activityDeadline)
        )
    }

    mutating func expire(at uptime: TimeInterval) -> TransferFunctionAnalysis? {
        guard prepareForUpdate(at: uptime) else {
            return TransferFunctionAnalysis(validity: .waitingForSignal, curve: nil)
        }
        guard retainedCurve != nil,
              let retentionDeadline,
              uptime >= retentionDeadline else { return nil }
        clearRetainedCurve()
        return TransferFunctionAnalysis(validity: currentInvalidity, curve: nil)
    }

    mutating func reset() {
        clearRetainedCurve()
        currentInvalidity = .waitingForSignal
        lastUpdateUptime = nil
    }

    private mutating func prepareForUpdate(at uptime: TimeInterval) -> Bool {
        guard uptime.isFinite,
              lastUpdateUptime.map({ uptime >= $0 }) != false else {
            reset()
            return false
        }
        lastUpdateUptime = uptime
        return true
    }

    private mutating func clearRetainedCurve() {
        retainedCurve = nil
        retentionDeadline = nil
        lastValidAnalysisUptime = nil
        lastInputActivityUptime = nil
        acceptsInputActivity = false
    }
}
