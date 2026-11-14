// SPDX-License-Identifier: MPL-2.0
pub fn clamp_add(a: u8, b: u8) -> u8 {
    a.saturating_add(b)
}

pub fn describe(n: i32) -> &'static str {
    if n < 0 {
        "negative"
    } else if n == 0 {
        "zero"
    } else {
        "positive"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn example_describe_zero() {
        assert_eq!(describe(0), "zero");
    }

    #[test]
    fn prop_clamp_add_never_wraps() {
        for a in 0..=255u8 {
            assert!(clamp_add(a, 255) >= a);
        }
    }
}
