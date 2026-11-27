// SPDX-License-Identifier: MPL-2.0
//! Minimal ISO calendar dates: enough to compare an expiry against today.

use std::time::{SystemTime, UNIX_EPOCH};

/// (year, month, day); tuples compare chronologically.
pub type Date = (i32, u32, u32);

pub fn parse(s: &str) -> Option<Date> {
    let mut it = s.trim().split('-');
    let (y, m, d) = (it.next()?, it.next()?, it.next()?);
    if it.next().is_some() || y.len() != 4 || m.len() != 2 || d.len() != 2 {
        return None;
    }
    let date = (y.parse().ok()?, m.parse().ok()?, d.parse().ok()?);
    valid(date).then_some(date)
}

fn leap(y: i32) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

fn valid((y, m, d): Date) -> bool {
    let days = match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap(y) => 29,
        2 => 28,
        _ => return false,
    };
    (1..=days).contains(&d)
}

/// Today in UTC (days since the epoch to a civil date).
pub fn today() -> Date {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    from_epoch_days((secs / 86_400) as i64)
}

fn from_epoch_days(z: i64) -> Date {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = (yoe + era * 400 + i64::from(m <= 2)) as i32;
    (y, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_and_orders() {
        assert_eq!(parse("2026-12-10"), Some((2026, 12, 10)));
        assert!(parse("2026-11-26") < parse("2027-01-01"));
    }

    #[test]
    fn rejects_garbage() {
        for bad in ["", "2026-13-01", "2026-02-30", "26-1-1", "2026/01/01", "2026-01-01-02"] {
            assert_eq!(parse(bad), None, "{bad}");
        }
        assert!(parse("2028-02-29").is_some());
    }

    #[test]
    fn epoch_conversion() {
        assert_eq!(from_epoch_days(0), (1970, 1, 1));
        assert_eq!(from_epoch_days(20_453), (2025, 12, 31));
    }
}
