//! `.mtn` (RoboPlus Action) 텍스트 파일 파서.
//!
//! 우리 자체 텍스트 포맷 (RoboPlus 호환 변형). 형식:
//!
//! ```text
//! type=1
//! version=2
//! enable[31]=1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1
//!
//! page_begin
//! id=1
//! name=Stand Up
//! compliance=5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5 5
//! play_param=0 0 32 0 0
//!     # next_page exit_page speed repeat accel
//! step=2048 2048 2048 ... [31 ints] pause_time play_time
//! step=...
//! page_end
//!
//! page_begin
//! ...
//! page_end
//! ```
//!
//! > TODO (mtn-format.md): 실 RoboPlus `.mtn`의 정확한 라벨은 약간 다를 수
//! > 있음. 우리는 위 변형을 정식으로 채택하고 임포트 시 정규화한다.
//! > 진짜 RoboPlus 파일이 들어오면 사용자 fixture에 추가 후 보강.

use thiserror::Error;

use super::page::{Motion, MotionPage, MotionStep, NUM_JOINTS_IN_STEP};

/// 파싱 에러.
#[derive(Debug, Error, PartialEq, Eq)]
pub enum ParseError {
    /// 페이지가 page_begin/page_end 짝이 안 맞음.
    #[error("unmatched page_begin/page_end")]
    UnmatchedPage,
    /// step의 숫자 개수가 기대와 다름.
    #[error("step expected {expected} ints, got {got}")]
    StepArity {
        /// 기대 개수.
        expected: usize,
        /// 실제 개수.
        got: usize,
    },
    /// compliance 배열 길이가 31이 아님.
    #[error("compliance expected 31 ints, got {got}")]
    ComplianceArity {
        /// 실제 개수.
        got: usize,
    },
    /// play_param 5개 필드 미충족.
    #[error("play_param expected 5 ints, got {got}")]
    PlayParamArity {
        /// 실제 개수.
        got: usize,
    },
    /// 정수 파싱 실패.
    #[error("integer parse error: {0}")]
    IntParse(String),
    /// 잘못된 라인.
    #[error("unrecognized line at {line}: {content}")]
    BadLine {
        /// 라인 번호 (1-indexed).
        line: usize,
        /// 라인 내용.
        content: String,
    },
}

/// `.mtn` 텍스트 → `Motion`.
pub fn parse_mtn(input: &str) -> Result<Motion, ParseError> {
    let mut motion = Motion::default();
    let mut current_page: Option<MotionPage> = None;
    let mut in_page = false;

    for (lineno, raw) in input.lines().enumerate() {
        let lineno = lineno + 1;
        let line = raw.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }

        match key_of(line) {
            Some(("type", _)) => continue,
            Some(("version", _)) => continue,
            Some(("enable", _)) => continue,

            Some(("page_begin", _)) => {
                if in_page {
                    return Err(ParseError::UnmatchedPage);
                }
                in_page = true;
                current_page = Some(MotionPage {
                    id: 0,
                    name: String::new(),
                    compliance: [5u8; NUM_JOINTS_IN_STEP],
                    next_page: 0,
                    exit_page: 0,
                    repeat: 1,
                    speed: 32,
                    accel: 0,
                    steps: Vec::new(),
                });
            }
            Some(("page_end", _)) => {
                if !in_page {
                    return Err(ParseError::UnmatchedPage);
                }
                in_page = false;
                if let Some(p) = current_page.take() {
                    motion.pages.push(p);
                }
            }

            Some(("id", v)) => set_in_page(&mut current_page, |p| {
                p.id = parse_int(v)?;
                Ok(())
            })?,
            Some(("name", v)) => set_in_page(&mut current_page, |p| {
                p.name = v.to_string();
                Ok(())
            })?,
            Some(("compliance", v)) => set_in_page(&mut current_page, |p| {
                let parts: Vec<&str> = v.split_whitespace().collect();
                if parts.len() != NUM_JOINTS_IN_STEP {
                    return Err(ParseError::ComplianceArity { got: parts.len() });
                }
                for (i, s) in parts.iter().enumerate() {
                    p.compliance[i] = parse_int(s)?;
                }
                Ok(())
            })?,
            Some(("play_param", v)) => set_in_page(&mut current_page, |p| {
                let parts: Vec<&str> = v.split_whitespace().collect();
                if parts.len() != 5 {
                    return Err(ParseError::PlayParamArity { got: parts.len() });
                }
                p.next_page = parse_int(parts[0])?;
                p.exit_page = parse_int(parts[1])?;
                p.speed = parse_int(parts[2])?;
                p.repeat = parse_int(parts[3])?;
                p.accel = parse_int(parts[4])?;
                Ok(())
            })?,
            Some(("step", v)) => set_in_page(&mut current_page, |p| {
                let parts: Vec<&str> = v.split_whitespace().collect();
                let expected = NUM_JOINTS_IN_STEP + 2;
                if parts.len() != expected {
                    return Err(ParseError::StepArity {
                        expected,
                        got: parts.len(),
                    });
                }
                let mut positions = [0u16; NUM_JOINTS_IN_STEP];
                for (i, s) in parts[..NUM_JOINTS_IN_STEP].iter().enumerate() {
                    positions[i] = parse_int(s)?;
                }
                let pause_time: u8 = parse_int(parts[NUM_JOINTS_IN_STEP])?;
                let play_time: u8 = parse_int(parts[NUM_JOINTS_IN_STEP + 1])?;
                p.steps.push(MotionStep {
                    positions,
                    pause_time,
                    play_time,
                });
                Ok(())
            })?,

            _ => {
                return Err(ParseError::BadLine {
                    line: lineno,
                    content: raw.to_string(),
                });
            }
        }
    }
    if in_page {
        return Err(ParseError::UnmatchedPage);
    }
    Ok(motion)
}

fn key_of(line: &str) -> Option<(&str, &str)> {
    if let Some(eq) = line.find('=') {
        let (k, rest) = line.split_at(eq);
        Some((k.trim(), rest[1..].trim()))
    } else {
        // 키워드만 있는 라인 (page_begin / page_end)
        Some((line, ""))
    }
}

fn set_in_page<F>(page: &mut Option<MotionPage>, mut f: F) -> Result<(), ParseError>
where
    F: FnMut(&mut MotionPage) -> Result<(), ParseError>,
{
    if let Some(p) = page.as_mut() {
        f(p)
    } else {
        Err(ParseError::UnmatchedPage)
    }
}

fn parse_int<T: std::str::FromStr>(s: &str) -> Result<T, ParseError>
where
    T::Err: std::fmt::Display,
{
    s.parse::<T>()
        .map_err(|e| ParseError::IntParse(format!("{} ({})", e, s)))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = include_str!("../../tests/fixtures/sample-2page.mtn");

    #[test]
    fn parses_two_page_sample() {
        let m = parse_mtn(SAMPLE).unwrap();
        assert_eq!(m.pages.len(), 2);
        assert_eq!(m.pages[0].id, 1);
        assert_eq!(m.pages[0].name, "Stand Up");
        assert_eq!(m.pages[0].steps.len(), 2);
        assert_eq!(m.pages[1].name, "Wave");
    }

    #[test]
    fn detects_unmatched_page_begin() {
        let bad = "page_begin\nid=1\n"; // page_end 없음
        assert!(matches!(parse_mtn(bad), Err(ParseError::UnmatchedPage)));
    }

    #[test]
    fn detects_step_arity_mismatch() {
        let bad = "page_begin\nid=1\nstep=1 2 3\npage_end\n";
        let err = parse_mtn(bad).unwrap_err();
        assert!(matches!(err, ParseError::StepArity { .. }));
    }
}
