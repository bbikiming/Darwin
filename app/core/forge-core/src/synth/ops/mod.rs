//! 합성 연산자 trait + 6가지 구현 모듈.
//!
//! 모든 연산자는 **순수 함수** 인터페이스를 따른다 — 입력 페이지를 변경하지 않고
//! 새 페이지를 반환한다 (immutability). PRD §5.2 참조.

pub mod layer;
pub mod mirror;
pub mod morph;
pub mod mutate;
pub mod procedural;
pub mod sequence;

use super::Result;
use crate::motion::MotionPage;

/// 합성 연산자 공통 trait.
pub trait SynthOp {
    /// 연산자 설정 파라미터 타입.
    type Params;

    /// 합성 실행. 입력 페이지는 변경되지 않는다.
    ///
    /// 결과가 한 페이지에 담기지 못하는 경우(>7 step) 여러 페이지로 분할되며,
    /// 각 페이지의 `next` 필드가 chain을 형성한다.
    fn synthesize(&self, inputs: &[&MotionPage], params: &Self::Params) -> Result<Vec<MotionPage>>;
}
