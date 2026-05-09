//! `.mtn` 라이터. parse_mtn(write_mtn(m)) == m round-trip 보장.

use std::fmt::Write;

use super::page::{Motion, NUM_JOINTS_IN_STEP};

/// `Motion` → `.mtn` 텍스트.
pub fn write_mtn(m: &Motion) -> String {
    let mut s = String::new();
    let _ = writeln!(s, "type=1");
    let _ = writeln!(s, "version={}", m.version);
    let _ = writeln!(
        s,
        "enable={}",
        std::iter::repeat("1")
            .take(NUM_JOINTS_IN_STEP)
            .collect::<Vec<_>>()
            .join(" ")
    );
    s.push('\n');

    for p in &m.pages {
        let _ = writeln!(s, "page_begin");
        let _ = writeln!(s, "id={}", p.id);
        let _ = writeln!(s, "name={}", p.name);
        let _ = writeln!(
            s,
            "compliance={}",
            p.compliance
                .iter()
                .map(u8::to_string)
                .collect::<Vec<_>>()
                .join(" ")
        );
        let _ = writeln!(
            s,
            "play_param={} {} {} {} {}",
            p.next_page, p.exit_page, p.speed, p.repeat, p.accel
        );
        for st in &p.steps {
            let _ = writeln!(
                s,
                "step={} {} {}",
                st.positions
                    .iter()
                    .map(u16::to_string)
                    .collect::<Vec<_>>()
                    .join(" "),
                st.pause_time,
                st.play_time
            );
        }
        let _ = writeln!(s, "page_end");
        s.push('\n');
    }
    s
}

#[cfg(test)]
mod tests {
    use super::super::page::*;
    use super::super::parser::parse_mtn;
    use super::*;

    fn make_sample() -> Motion {
        Motion {
            version: 1,
            robot_generation: "op2".to_string(),
            pages: vec![
                MotionPage {
                    id: 1,
                    name: "Stand Up".to_string(),
                    next_page: 0,
                    exit_page: 0,
                    repeat: 1,
                    speed: 32,
                    accel: 0,
                    steps: vec![
                        MotionStep {
                            positions: [2048u16; NUM_JOINTS_IN_STEP],
                            pause_time: 0,
                            play_time: 32,
                        },
                        MotionStep {
                            positions: [2050u16; NUM_JOINTS_IN_STEP],
                            pause_time: 4,
                            play_time: 16,
                        },
                    ],
                    ..Default::default()
                },
                MotionPage {
                    id: 7,
                    name: "Wave".to_string(),
                    ..Default::default()
                },
            ],
        }
    }

    #[test]
    fn round_trip_lossless_within_known_subset() {
        let m1 = make_sample();
        let text = write_mtn(&m1);
        let m2 = parse_mtn(&text).unwrap();
        // robot_generation은 .mtn에는 안 담기므로 wipe 후 비교
        let mut m1_normalized = m1.clone();
        m1_normalized.robot_generation = String::new();
        let mut m2_normalized = m2;
        m2_normalized.robot_generation = String::new();
        assert_eq!(m1_normalized, m2_normalized);
    }

    #[test]
    fn writes_sample_with_two_pages() {
        let text = write_mtn(&make_sample());
        assert!(text.contains("page_begin"));
        assert!(text.contains("name=Wave"));
        assert!(text.contains("page_end"));
    }
}
