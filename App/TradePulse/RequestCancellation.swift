/// Whether `error` ends a request whose task was cancelled. A task that is cancelled while it waits for the server
/// ends with a `CancellationError` or, when the system cancels the transfer, with a URL error; neither is a failure to
/// show. It looks at the task it is called from, which is the one that made the request.
func endsACancelledRequest(_ error: any Error) -> Bool {
    error is CancellationError || Task.isCancelled
}
