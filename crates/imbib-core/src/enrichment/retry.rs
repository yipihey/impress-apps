//! Retry policy — strategy only, no async.
//!
//! Mirrors `RetryPolicy` from Swift `EnrichmentRetry.swift` but exposes
//! `next_delay(attempt) -> Duration` so the caller (Swift / Python / CLI)
//! decides whether to actually sleep. The Swift `RetryExecutor` actor is
//! intentionally NOT ported — the orchestration loop stays in Swift for
//! Phase 1G; only the *decision* moves into Rust.
//!
//! Exponential backoff with jitter, matching Swift's
//! `baseDelay * 2^(attempt-2)` formula (clamped to `max_backoff`).

use std::time::Duration;

/// Configuration for retry timing decisions.
#[derive(Debug, Clone)]
pub struct RetryPolicy {
    /// Maximum number of attempts (1 = no retries). Swift default: 3.
    pub max_attempts: u32,
    /// Base delay between retries. Swift default: 1.0s.
    pub base_backoff: Duration,
    /// Upper bound on a single retry delay. Swift default: 60s.
    pub max_backoff: Duration,
    /// Jitter factor [0.0, 1.0]. Applied symmetrically (`±jitter * delay`).
    /// Swift default: 0.2.
    pub jitter_factor: f64,
}

impl RetryPolicy {
    /// User-triggered actions: 3 attempts, 0.5s → 10s. Matches Swift `RetryPolicy.userTriggered`.
    pub fn user_triggered() -> Self {
        Self {
            max_attempts: 3,
            base_backoff: Duration::from_millis(500),
            max_backoff: Duration::from_secs(10),
            jitter_factor: 0.2,
        }
    }

    /// Background sync: 5 attempts, 2s → 120s. Matches Swift `RetryPolicy.backgroundSync`.
    pub fn background_sync() -> Self {
        Self {
            max_attempts: 5,
            base_backoff: Duration::from_secs(2),
            max_backoff: Duration::from_secs(120),
            jitter_factor: 0.2,
        }
    }

    /// No retries. Matches Swift `RetryPolicy.noRetry`.
    pub fn no_retry() -> Self {
        Self {
            max_attempts: 1,
            base_backoff: Duration::ZERO,
            max_backoff: Duration::ZERO,
            jitter_factor: 0.0,
        }
    }

    /// Decide whether to retry and how long to wait, given the attempt
    /// number that just *failed*. `RetryDecision::Stop` means caller should
    /// surface the error to the user.
    ///
    /// `attempt` is 1-indexed (1 = first attempt). After the Nth attempt
    /// fails, `decide(N)` is called.
    pub fn decide(&self, attempt: u32) -> RetryDecision {
        if attempt >= self.max_attempts {
            return RetryDecision::Stop;
        }
        // The "next" attempt is `attempt + 1` (1-indexed). For the wait
        // *before* attempt N (N > 1), Swift uses `baseDelay * 2^(N-2)`.
        let next_attempt = attempt + 1;
        RetryDecision::Retry {
            next_attempt,
            delay: self.next_delay(next_attempt),
        }
    }

    /// Computed delay before attempt `n` (1-indexed). `n == 1` returns zero.
    ///
    /// Formula (Swift parity): `delay = clamp(baseDelay * 2^(n-2), 0, maxBackoff)`.
    /// Jitter is *not* applied here — we expose a deterministic delay so the
    /// caller can decide whether to add randomness (and which RNG). Use
    /// `next_delay_with_jitter` to opt in.
    pub fn next_delay(&self, n: u32) -> Duration {
        if n <= 1 {
            return Duration::ZERO;
        }
        // n=2 → 0, n=3 → 1, … Saturate and cap the exponent so the delay
        // stays finite, monotone, and bounded for every u32 attempt number
        // (2^1023 is the largest finite power of two in f64; anything past
        // it clamps to max_backoff anyway).
        let exponent = n.saturating_sub(2).min(1023) as i32;
        let factor = 2f64.powi(exponent);
        let base_secs = self.base_backoff.as_secs_f64();
        let scaled = base_secs * factor;
        let max_secs = self.max_backoff.as_secs_f64();
        let clamped = if scaled > max_secs { max_secs } else { scaled };
        if clamped.is_finite() && clamped >= 0.0 {
            Duration::from_secs_f64(clamped)
        } else {
            Duration::ZERO
        }
    }

    /// Same as `next_delay`, but applies symmetric jitter using the supplied
    /// RNG sample (in `[-1.0, 1.0]`). Splitting RNG out of the policy keeps
    /// the module pure / deterministic / testable.
    pub fn next_delay_with_jitter(&self, n: u32, jitter_sample: f64) -> Duration {
        let base = self.next_delay(n);
        if base.is_zero() || self.jitter_factor <= 0.0 {
            return base;
        }
        // Non-finite samples (NaN survives `clamp`) are treated as "no jitter"
        // so a broken RNG can never panic `Duration::from_secs_f64`.
        let sample = if jitter_sample.is_finite() {
            jitter_sample.clamp(-1.0, 1.0)
        } else {
            0.0
        };
        let base_secs = base.as_secs_f64();
        let jittered = base_secs + base_secs * self.jitter_factor * sample;
        if jittered.is_finite() && jittered > 0.0 {
            Duration::from_secs_f64(jittered)
        } else {
            Duration::ZERO
        }
    }
}

impl Default for RetryPolicy {
    /// Same defaults as Swift's `RetryPolicy.init()` with `maxAttempts: 3,
    /// baseDelay: 1.0, maxDelay: 60.0, jitterFactor: 0.2`.
    fn default() -> Self {
        Self {
            max_attempts: 3,
            base_backoff: Duration::from_secs(1),
            max_backoff: Duration::from_secs(60),
            jitter_factor: 0.2,
        }
    }
}

/// Outcome of [`RetryPolicy::decide`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RetryDecision {
    /// Caller should wait `delay`, then attempt `next_attempt` (1-indexed).
    Retry { next_attempt: u32, delay: Duration },
    /// Retry budget exhausted; caller should fail the operation.
    Stop,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_attempt_has_zero_delay() {
        let p = RetryPolicy::default();
        assert_eq!(p.next_delay(1), Duration::ZERO);
    }

    #[test]
    fn exponential_backoff_progression() {
        let p = RetryPolicy {
            max_attempts: 10,
            base_backoff: Duration::from_secs(1),
            max_backoff: Duration::from_secs(1000),
            jitter_factor: 0.0,
        };
        // n=2 → 1 * 2^0 = 1s
        assert_eq!(p.next_delay(2), Duration::from_secs(1));
        // n=3 → 1 * 2^1 = 2s
        assert_eq!(p.next_delay(3), Duration::from_secs(2));
        // n=4 → 1 * 2^2 = 4s
        assert_eq!(p.next_delay(4), Duration::from_secs(4));
        // n=5 → 1 * 2^3 = 8s
        assert_eq!(p.next_delay(5), Duration::from_secs(8));
    }

    #[test]
    fn delay_clamped_to_max_backoff() {
        let p = RetryPolicy {
            max_attempts: 20,
            base_backoff: Duration::from_secs(1),
            max_backoff: Duration::from_secs(10),
            jitter_factor: 0.0,
        };
        // 2^10 = 1024s, way past 10s cap.
        assert_eq!(p.next_delay(12), Duration::from_secs(10));
        assert_eq!(p.next_delay(20), Duration::from_secs(10));
    }

    #[test]
    fn decide_stops_after_max_attempts() {
        let p = RetryPolicy::default(); // max_attempts = 3
        assert_eq!(p.decide(3), RetryDecision::Stop);
        assert_eq!(p.decide(4), RetryDecision::Stop);
    }

    #[test]
    fn decide_retries_within_budget() {
        let p = RetryPolicy {
            max_attempts: 3,
            base_backoff: Duration::from_secs(1),
            max_backoff: Duration::from_secs(60),
            jitter_factor: 0.0,
        };
        let d1 = p.decide(1);
        match d1 {
            RetryDecision::Retry {
                next_attempt,
                delay,
            } => {
                assert_eq!(next_attempt, 2);
                assert_eq!(delay, Duration::from_secs(1));
            }
            _ => panic!("expected Retry, got {:?}", d1),
        }
        let d2 = p.decide(2);
        match d2 {
            RetryDecision::Retry {
                next_attempt,
                delay,
            } => {
                assert_eq!(next_attempt, 3);
                assert_eq!(delay, Duration::from_secs(2));
            }
            _ => panic!("expected Retry, got {:?}", d2),
        }
    }

    #[test]
    fn no_retry_policy_stops_immediately() {
        let p = RetryPolicy::no_retry();
        assert_eq!(p.decide(1), RetryDecision::Stop);
    }

    #[test]
    fn jitter_sample_zero_yields_base_delay() {
        let p = RetryPolicy::default();
        assert_eq!(p.next_delay_with_jitter(3, 0.0), p.next_delay(3));
    }

    #[test]
    fn jitter_sample_clamped() {
        let p = RetryPolicy {
            max_attempts: 5,
            base_backoff: Duration::from_secs(10),
            max_backoff: Duration::from_secs(60),
            jitter_factor: 0.2,
        };
        // base for n=2 = 10s; max jitter = ±20% = ±2s → result in [8s, 12s].
        let pos = p.next_delay_with_jitter(2, 1.0);
        let neg = p.next_delay_with_jitter(2, -1.0);
        // Out-of-range jitter samples should be clamped to ±1.
        let too_high = p.next_delay_with_jitter(2, 5.0);
        let too_low = p.next_delay_with_jitter(2, -5.0);
        assert_eq!(pos, too_high);
        assert_eq!(neg, too_low);
        assert_eq!(pos.as_secs_f64(), 12.0);
        assert_eq!(neg.as_secs_f64(), 8.0);
    }

    #[test]
    fn negative_jitter_floors_at_zero() {
        let p = RetryPolicy {
            max_attempts: 5,
            base_backoff: Duration::from_secs(1),
            max_backoff: Duration::from_secs(60),
            jitter_factor: 2.0, // pathological: 200% jitter
        };
        // base for n=2 = 1s; jitter sample = -1 → -1s, clamps to zero.
        let d = p.next_delay_with_jitter(2, -1.0);
        assert_eq!(d, Duration::ZERO);
    }

    #[test]
    fn presets_match_swift() {
        let ut = RetryPolicy::user_triggered();
        assert_eq!(ut.max_attempts, 3);
        assert_eq!(ut.base_backoff, Duration::from_millis(500));
        assert_eq!(ut.max_backoff, Duration::from_secs(10));

        let bg = RetryPolicy::background_sync();
        assert_eq!(bg.max_attempts, 5);
        assert_eq!(bg.base_backoff, Duration::from_secs(2));
        assert_eq!(bg.max_backoff, Duration::from_secs(120));

        let nr = RetryPolicy::no_retry();
        assert_eq!(nr.max_attempts, 1);
    }
}
