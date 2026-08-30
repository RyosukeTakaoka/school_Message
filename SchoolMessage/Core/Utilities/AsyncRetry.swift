import Foundation

/// 指数バックオフ付きのリトライ.
///
/// - 一時的な失敗(圏外・混雑・タイムアウト)だけを再試行する.
/// - 恒久的な失敗(容量超過・権限不足)は即座に投げ返す. 叩き続けても直らないうえ,
///   CloudKit 側のレート制限を悪化させるため.
enum AsyncRetry {

    static func perform<T: Sendable>(
        maxAttempts: Int = AppConstants.Timing.maxRetryAttempts,
        baseDelay: TimeInterval = AppConstants.Timing.retryBaseDelay,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await operation()
            } catch {
                attempt += 1
                let appError = AppError.wrap(error)
                guard appError.isRetryable, attempt < maxAttempts else {
                    throw appError
                }
                try Task.checkCancellation()
                let delay = appError.suggestedRetryDelay ?? backoffDelay(attempt: attempt, baseDelay: baseDelay)
                Log.backend.debug("retrying after \(delay, format: .fixed(precision: 1))s (attempt \(attempt, privacy: .public))")
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// 指数バックオフ + ジッタ.
    /// ジッタを入れるのは, 複数端末が同時に失敗したときに再試行が揃って
    /// もう一度サーバを叩く(thundering herd)のを避けるため.
    static func backoffDelay(attempt: Int, baseDelay: TimeInterval) -> TimeInterval {
        let exponential = baseDelay * pow(2, Double(max(0, attempt - 1)))
        let jitter = Double.random(in: 0...(baseDelay / 2))
        return min(exponential + jitter, 60)
    }
}
