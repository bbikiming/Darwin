//! 핸드셰이크 토큰·cmd_id 생성.
//!
//! 계약(§G.1): 토큰은 16 영숫자, 셸-세이프(핸드셰이크 파일과 모든 데이터그램에
//! 박히므로 공백·셸 메타문자 금지). cmd_id 는 ≤31자·공백 금지(ACK 파일에 에코됨)
//! — Python 원본은 `uuid4().hex[:24]`, 여기서는 24 hex 문자로 동일 형태를 만든다.
//!
//! 보안 노트: Python 원본은 `secrets`(CSPRNG)를 쓴다. df-wire 는 의존 0 제약으로
//! std 해셔 엔트로피 + 시계 혼합의 xorshift64* 를 쓴다 — LAN 명령 게이트용 세션
//! 토큰으로는 충분하지만 암호학적 보증은 아니다. W1 ally-link 에서 OS 엔트로피
//! (`getrandom`) 승격을 검토한다 (docs/03_ARCHITECTURE.md §9).

use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::time::{SystemTime, UNIX_EPOCH};

/// §G.1 토큰 길이 — Python `df_udp.TOKEN_LENGTH` 와 동일.
pub const TOKEN_LENGTH: usize = 16;
/// cmd_id 길이 — Python `uuid4().hex[:24]` 와 동일 형태.
pub const CMD_ID_LENGTH: usize = 24;

// Python `string.ascii_letters + string.digits` 와 동일한 문자 집합.
const TOKEN_ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const HEX_ALPHABET: &[u8] = b"0123456789abcdef";

/// 시드 주입 가능한 경량 PRNG(xorshift64*) — 테스트 결정성을 위해 분리.
pub struct WireRng(u64);

impl WireRng {
    /// 결정적 시드 생성기 (테스트·재현용). xorshift 상태는 0이 될 수 없어 보정한다.
    pub fn from_seed(seed: u64) -> Self {
        WireRng(seed.max(1))
    }

    /// 비결정 시드 생성기 — std 해셔의 프로세스 랜덤 키 + 시계 혼합.
    pub fn from_entropy() -> Self {
        let clock = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| u64::from(d.subsec_nanos()) ^ d.as_secs().rotate_left(20))
            .unwrap_or(0x9E37_79B9_7F4A_7C15);
        let h1 = RandomState::new().build_hasher().finish();
        let h2 = RandomState::new().build_hasher().finish();
        Self::from_seed(clock ^ h1 ^ h2.rotate_left(32))
    }

    fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn pick(&mut self, alphabet: &[u8], length: usize) -> String {
        (0..length)
            .map(|_| {
                let idx = (self.next_u64() % alphabet.len() as u64) as usize;
                char::from(alphabet[idx])
            })
            .collect()
    }

    /// 16 영숫자 토큰 생성 (§G.1).
    pub fn token(&mut self) -> String {
        self.pick(TOKEN_ALPHABET, TOKEN_LENGTH)
    }

    /// 24 hex cmd_id 생성 (§C — uuid4().hex[:24] 동형).
    pub fn cmd_id(&mut self) -> String {
        self.pick(HEX_ALPHABET, CMD_ID_LENGTH)
    }
}

/// 새 핸드셰이크 토큰 — Python `df_udp.gen_token()` 등가.
pub fn gen_token() -> String {
    WireRng::from_entropy().token()
}

/// 새 cmd_id — Python `SshControlClient._new_cmd_id()` 등가.
pub fn gen_cmd_id() -> String {
    WireRng::from_entropy().cmd_id()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seeded_token_is_deterministic() {
        let a = WireRng::from_seed(42).token();
        let b = WireRng::from_seed(42).token();
        assert_eq!(a, b);
        assert_eq!(a.len(), TOKEN_LENGTH);
    }

    #[test]
    fn token_is_shell_safe_alphanumeric() {
        let token = gen_token();
        assert_eq!(token.len(), TOKEN_LENGTH);
        assert!(token.bytes().all(|b| b.is_ascii_alphanumeric()));
    }

    #[test]
    fn cmd_id_is_24_hex_no_spaces() {
        let id = gen_cmd_id();
        assert_eq!(id.len(), CMD_ID_LENGTH);
        assert!(id.bytes().all(|b| b.is_ascii_hexdigit()));
    }

    #[test]
    fn entropy_tokens_differ() {
        // 충돌 확률은 62^16 — 두 번 연속 동일하면 엔트로피 소스가 죽은 것이다.
        assert_ne!(gen_token(), gen_token());
    }
}
