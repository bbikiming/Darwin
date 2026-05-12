//! 이미지 프레임.

/// 8-bit RGBA pixel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Pixel {
    /// red.
    pub r: u8,
    /// green.
    pub g: u8,
    /// blue.
    pub b: u8,
    /// alpha.
    pub a: u8,
}

impl Pixel {
    /// 새 픽셀.
    pub const fn rgb(r: u8, g: u8, b: u8) -> Self {
        Self { r, g, b, a: 255 }
    }

    /// HSV로 변환 — h 0..360°, s/v 0..1.
    pub fn to_hsv(self) -> (f32, f32, f32) {
        let r = self.r as f32 / 255.0;
        let g = self.g as f32 / 255.0;
        let b = self.b as f32 / 255.0;
        let max = r.max(g).max(b);
        let min = r.min(g).min(b);
        let delta = max - min;
        let h = if delta < 1e-6 {
            0.0
        } else if (max - r).abs() < 1e-6 {
            60.0 * (((g - b) / delta).rem_euclid(6.0))
        } else if (max - g).abs() < 1e-6 {
            60.0 * (((b - r) / delta) + 2.0)
        } else {
            60.0 * (((r - g) / delta) + 4.0)
        };
        let s = if max < 1e-6 { 0.0 } else { delta / max };
        let v = max;
        (h, s, v)
    }
}

/// 단순 라스터 이미지. 작은 디버그 프레임 위주.
#[derive(Debug, Clone)]
pub struct Frame {
    /// 너비 (픽셀).
    pub width: u32,
    /// 높이 (픽셀).
    pub height: u32,
    /// 픽셀 배열, row-major.
    pub pixels: Vec<Pixel>,
}

impl Frame {
    /// 단색으로 채워진 새 프레임.
    pub fn solid(width: u32, height: u32, color: Pixel) -> Self {
        Self {
            width,
            height,
            pixels: vec![color; (width * height) as usize],
        }
    }

    /// (x, y) 픽셀 get. 범위 외는 None.
    pub fn pixel(&self, x: u32, y: u32) -> Option<Pixel> {
        if x >= self.width || y >= self.height {
            return None;
        }
        Some(self.pixels[(y * self.width + x) as usize])
    }

    /// (x, y) 픽셀 set.
    pub fn set_pixel(&mut self, x: u32, y: u32, p: Pixel) {
        if x < self.width && y < self.height {
            self.pixels[(y * self.width + x) as usize] = p;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pixel_to_hsv_red() {
        let p = Pixel::rgb(255, 0, 0);
        let (h, s, v) = p.to_hsv();
        assert!((h - 0.0).abs() < 1e-3);
        assert!((s - 1.0).abs() < 1e-3);
        assert!((v - 1.0).abs() < 1e-3);
    }

    #[test]
    fn pixel_to_hsv_green() {
        let p = Pixel::rgb(0, 255, 0);
        let (h, _, _) = p.to_hsv();
        assert!((h - 120.0).abs() < 1e-3);
    }

    #[test]
    fn pixel_to_hsv_blue() {
        let p = Pixel::rgb(0, 0, 255);
        let (h, _, _) = p.to_hsv();
        assert!((h - 240.0).abs() < 1e-3);
    }

    #[test]
    fn frame_solid_then_modify() {
        let mut f = Frame::solid(4, 4, Pixel::rgb(0, 0, 0));
        f.set_pixel(1, 2, Pixel::rgb(255, 0, 0));
        assert_eq!(f.pixel(1, 2), Some(Pixel::rgb(255, 0, 0)));
        assert_eq!(f.pixel(0, 0), Some(Pixel::rgb(0, 0, 0)));
        assert_eq!(f.pixel(99, 99), None);
    }
}
