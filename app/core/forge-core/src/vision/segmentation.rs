//! HSV 기반 색 segmentation + 단순 blob detection.

use super::frame::Frame;

/// HSV 범위 — h는 wrap-around 지원 (예: 빨강 350..10).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct HsvRange {
    /// hue min (degrees, 0..360).
    pub h_min: f32,
    /// hue max.
    pub h_max: f32,
    /// saturation min 0..1.
    pub s_min: f32,
    /// value min 0..1.
    pub v_min: f32,
}

impl HsvRange {
    /// 주황 RoboCup 공의 통상 범위.
    pub const ROBOCUP_BALL: HsvRange = HsvRange {
        h_min: 0.0,
        h_max: 30.0,
        s_min: 0.5,
        v_min: 0.4,
    };

    /// 노란 RoboCup 골 (Humanoid League).
    pub const ROBOCUP_GOAL_YELLOW: HsvRange = HsvRange {
        h_min: 40.0,
        h_max: 70.0,
        s_min: 0.4,
        v_min: 0.4,
    };

    /// 픽셀이 범위 안에 있나? (h wrap 처리)
    pub fn contains(&self, h: f32, s: f32, v: f32) -> bool {
        if s < self.s_min || v < self.v_min {
            return false;
        }
        if self.h_min <= self.h_max {
            h >= self.h_min && h <= self.h_max
        } else {
            // wrap-around (예: 350..10)
            h >= self.h_min || h <= self.h_max
        }
    }
}

/// blob 검출 결과.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BlobResult {
    /// 매칭된 픽셀 수.
    pub pixel_count: u32,
    /// 무게중심 x.
    pub centroid_x: f32,
    /// 무게중심 y.
    pub centroid_y: f32,
}

impl BlobResult {
    /// 검출된 blob 없음.
    pub const NONE: BlobResult = BlobResult {
        pixel_count: 0,
        centroid_x: 0.0,
        centroid_y: 0.0,
    };

    /// 블롭 발견됨?
    pub fn found(&self) -> bool {
        self.pixel_count > 0
    }
}

/// 단순 blob 검출 — 범위에 매칭되는 모든 픽셀의 무게중심.
pub fn detect_blob(frame: &Frame, range: HsvRange) -> BlobResult {
    let mut count: u32 = 0;
    let mut sum_x: u64 = 0;
    let mut sum_y: u64 = 0;
    for y in 0..frame.height {
        for x in 0..frame.width {
            if let Some(p) = frame.pixel(x, y) {
                let (h, s, v) = p.to_hsv();
                if range.contains(h, s, v) {
                    count += 1;
                    sum_x += x as u64;
                    sum_y += y as u64;
                }
            }
        }
    }
    if count == 0 {
        return BlobResult::NONE;
    }
    BlobResult {
        pixel_count: count,
        centroid_x: sum_x as f32 / count as f32,
        centroid_y: sum_y as f32 / count as f32,
    }
}

#[cfg(test)]
mod tests {
    use super::super::frame::*;
    use super::*;

    #[test]
    fn empty_frame_returns_none() {
        let f = Frame::solid(10, 10, Pixel::rgb(0, 0, 0));
        let b = detect_blob(&f, HsvRange::ROBOCUP_BALL);
        assert_eq!(b, BlobResult::NONE);
        assert!(!b.found());
    }

    #[test]
    fn detects_orange_ball_centroid() {
        let mut f = Frame::solid(10, 10, Pixel::rgb(0, 0, 0));
        // 5x5 사각형의 주황 — (3..7, 4..8) → 중심 (5, 6)
        for y in 4..8 {
            for x in 3..7 {
                f.set_pixel(x, y, Pixel::rgb(255, 100, 0));
            }
        }
        let b = detect_blob(&f, HsvRange::ROBOCUP_BALL);
        assert!(b.found());
        assert_eq!(b.pixel_count, 16);
        assert!((b.centroid_x - 4.5).abs() < 1e-3);
        assert!((b.centroid_y - 5.5).abs() < 1e-3);
    }

    #[test]
    fn ignores_low_saturation_pixels() {
        let mut f = Frame::solid(5, 5, Pixel::rgb(0, 0, 0));
        // 회색 (saturation 낮음, 주황 hue 아님이지만 임계값으로 reject)
        f.set_pixel(2, 2, Pixel::rgb(150, 150, 150));
        let b = detect_blob(&f, HsvRange::ROBOCUP_BALL);
        assert_eq!(b, BlobResult::NONE);
    }

    #[test]
    fn h_wrap_around() {
        // 빨강 wrap 350..10
        let r = HsvRange {
            h_min: 350.0,
            h_max: 10.0,
            s_min: 0.5,
            v_min: 0.5,
        };
        assert!(r.contains(355.0, 1.0, 1.0));
        assert!(r.contains(5.0, 1.0, 1.0));
        assert!(!r.contains(180.0, 1.0, 1.0));
    }
}
