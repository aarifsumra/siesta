//
//  LiveRequest.swift
//  Siesta
//
//  Created by Paul on 2018/3/7.
//  Copyright © 2018 Bust Out Solutions. All rights reserved.
//

extension Resource
    {
    public static func request(using delegate: RequestDelegate) -> Request
        {
        return LiveRequest(delegate: delegate)
        }
    }

public protocol RequestDelegate
    {
    func startUnderlyingOperation(completionHandler: RequestCompletionHandler)

    func cancelUnderlyingOperation()

    func repeated() -> RequestDelegate

    func computeProgress() -> Double

    var progressReportingInterval: Double { get }

    var requestDescription: String { get }
    }

extension RequestDelegate
    {
    func computeProgress() -> Double
        { return 0 }

    var progressReportingInterval: Double
        { return 0.05 }
    }

public protocol RequestCompletionHandler
    {
    func shouldIgnoreResponse(_ newResponse: Response) -> Bool

    func broadcastResponse(_ newInfo: ResponseInfo)
    }

private final class LiveRequest: Request, RequestCompletionHandler, CustomDebugStringConvertible
    {
    private let delegate: RequestDelegate
    private var responseCallbacks = CallbackGroup<ResponseInfo>()
    private var progressTracker = ProgressTracker()
    private(set) var isStarted = false, isCancelled = false

    init(delegate: RequestDelegate)
        {
        self.delegate = delegate
        }

    @discardableResult
    final func start() -> Request
        {
        DispatchQueue.mainThreadPrecondition()

        guard !isStarted else
            {
            log(.networkDetails, [delegate.requestDescription, "already started"])
            return self
            }

        guard !isCancelled else
            {
            log(.network, [delegate.requestDescription, "will not start because it was already cancelled"])
            return self
            }

        isStarted = true
        log(.network, [delegate.requestDescription])

        delegate.startUnderlyingOperation(completionHandler: self)

        progressTracker.start(
            progressProvider: delegate.computeProgress,
            reportingInterval: delegate.progressReportingInterval)

        return self
        }

    final func cancel()
        {
        DispatchQueue.mainThreadPrecondition()

        guard !isCompleted else
            {
            log(.network, ["cancel() called but request already completed:", delegate.requestDescription])
            return
            }

        log(.network, ["Cancelled", delegate.requestDescription])

        delegate.cancelUnderlyingOperation()

        // Prevent start() from have having any effect if it hasn't been called yet
        isCancelled = true

        broadcastResponse(.cancellation)
        }

    func onProgress(_ callback: @escaping (Double) -> Void) -> Request
        {
        progressTracker.callbacks.addCallback(callback)
        return self;
        }

    var progress: Double
        { return progressTracker.progress }

    final func onCompletion(_ callback: @escaping (ResponseInfo) -> Void) -> Request
        {
        responseCallbacks.addCallback(callback)
        return self
        }

    final var isCompleted: Bool
        {
        DispatchQueue.mainThreadPrecondition()

        return responseCallbacks.completedValue != nil
        }

    final func shouldIgnoreResponse(_ newResponse: Response) -> Bool
        {
        guard let existingResponse = responseCallbacks.completedValue?.response else
            { return false }

        // We already received a response; don't broadcast another one.

        if !existingResponse.isCancellation
            {
            log(.network,
                [
                "WARNING: Received response for request that was already completed:", delegate.requestDescription,
                "This may indicate a bug in the NetworkingProvider you are using, or in Siesta.",
                "Please file a bug report: https://github.com/bustoutsolutions/siesta/issues/new",
                "\n    Previously received:", existingResponse,
                "\n    New response:", newResponse
                ])
            }
        else if !newResponse.isCancellation
            {
            // Sometimes the network layer sends a cancellation error. That’s not of interest if we already knew
            // we were cancelled. If we received any other response after cancellation, log that we ignored it.

            log(.networkDetails,
                [
                "Received response, but request was already cancelled:", delegate.requestDescription,
                "\n    New response:", newResponse
                ])
            }

        return true
        }

    final func broadcastResponse(_ newInfo: ResponseInfo)
        {
        DispatchQueue.mainThreadPrecondition()

        if shouldIgnoreResponse(newInfo.response)
            { return }

        progressTracker.complete()

        responseCallbacks.notifyOfCompletion(newInfo)
        }

    func repeated() -> Request
        {
        return Resource.request(using: delegate.repeated())
        }

    // MARK: Debug

    final var debugDescription: String
        {
        return "Request:"
            + String(UInt(bitPattern: ObjectIdentifier(self)), radix: 16)
            + "("
            + delegate.requestDescription
            + ")"
        }
    }
