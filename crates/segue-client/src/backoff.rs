//! Auto-reconnect ladder behind an armed AI lock.
//!
//! Intervals are 2, 5, 10, 20, then 30 seconds. The 30 second figure caps one
//! wait, not the sequence, so a failure that never clears would retry for the
//! life of the process. [`ReconnectBackoff::BUDGET_MS`] stops the ladder after
//! 30 minutes of scheduled wait. An explicit user connect resets it.

/// Scheduled reconnect delays. The machine stays protected while this runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReconnectBackoff {
    step: usize,
    scheduled_ms: u64,
}

impl Default for ReconnectBackoff {
    fn default() -> Self {
        Self::new()
    }
}

impl ReconnectBackoff {
    pub const DELAYS_MS: [u64; 5] = [2_000, 5_000, 10_000, 20_000, 30_000];
    /// 30 minutes of scheduled delay, not 30 minutes of wall time.
    pub const BUDGET_MS: u64 = 30 * 60 * 1_000;

    pub fn new() -> Self {
        Self {
            step: 0,
            scheduled_ms: 0,
        }
    }

    /// The next rung, or `None` once [`Self::BUDGET_MS`] is already spent.
    /// The rung that crosses the budget is still handed out.
    pub fn next_delay_ms(&mut self) -> Option<u64> {
        if self.exhausted() {
            return None;
        }
        let delay = Self::DELAYS_MS[self.step.min(Self::DELAYS_MS.len() - 1)];
        self.step += 1;
        self.scheduled_ms = self.scheduled_ms.saturating_add(delay);
        Some(delay)
    }

    pub fn exhausted(&self) -> bool {
        self.scheduled_ms >= Self::BUDGET_MS
    }

    pub fn mark_exhausted(&mut self) {
        if self.scheduled_ms < Self::BUDGET_MS {
            self.scheduled_ms = Self::BUDGET_MS;
        }
    }

    pub fn reset(&mut self) {
        self.step = 0;
        self.scheduled_ms = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ladder_starts_at_two_seconds_and_caps_the_interval() {
        let mut backoff = ReconnectBackoff::new();
        let mut delays = Vec::new();
        for _ in 0..8 {
            delays.push(backoff.next_delay_ms().unwrap());
        }
        assert_eq!(
            delays,
            vec![2_000, 5_000, 10_000, 20_000, 30_000, 30_000, 30_000, 30_000]
        );
    }

    #[test]
    fn ladder_stops_after_the_budget_and_reset_starts_over() {
        let mut backoff = ReconnectBackoff::new();
        let mut scheduled = 0_u64;
        let mut rungs = 0_u32;
        while let Some(delay) = backoff.next_delay_ms() {
            scheduled += delay;
            rungs += 1;
            assert!(rungs < 1_000, "the ladder must not run forever");
        }
        assert!(backoff.exhausted());
        assert!(scheduled >= ReconnectBackoff::BUDGET_MS);
        assert!(rungs > (ReconnectBackoff::DELAYS_MS.len() as u32) * 2);
        assert_eq!(backoff.next_delay_ms(), None);
        backoff.reset();
        assert!(!backoff.exhausted());
        assert_eq!(backoff.next_delay_ms(), Some(2_000));
    }
}
