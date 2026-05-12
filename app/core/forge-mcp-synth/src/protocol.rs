//! JSON-RPC 2.0 + MCP 메서드 라우팅.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::engine::Engine;
use crate::tools::{call_tool, tool_definitions};

/// JSON-RPC 2.0 요청.
#[derive(Debug, Clone, Deserialize)]
pub struct JsonRpcRequest {
    /// 항상 `"2.0"`.
    pub jsonrpc: String,
    /// 요청 ID. notification 이면 None.
    #[serde(default)]
    pub id: Option<Value>,
    /// 메서드 이름.
    pub method: String,
    /// 메서드 파라미터.
    #[serde(default)]
    pub params: Option<Value>,
}

/// JSON-RPC 2.0 응답 (success).
#[derive(Debug, Clone, Serialize)]
pub struct JsonRpcResponse {
    /// 항상 `"2.0"`.
    pub jsonrpc: String,
    /// 매칭되는 요청 ID.
    pub id: Value,
    /// 결과 (또는 error 와 양자택일).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    /// 에러 (또는 result 와 양자택일).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcError>,
}

/// JSON-RPC 2.0 에러 객체.
#[derive(Debug, Clone, Serialize)]
pub struct JsonRpcError {
    /// 표준 에러 코드.
    pub code: i32,
    /// 사람이 읽는 메시지.
    pub message: String,
    /// 추가 데이터 (선택).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

impl JsonRpcError {
    /// `-32600` — Invalid Request.
    pub fn invalid_request(message: impl Into<String>) -> Self {
        Self {
            code: -32600,
            message: message.into(),
            data: None,
        }
    }

    /// `-32601` — Method not found.
    pub fn method_not_found(method: &str) -> Self {
        Self {
            code: -32601,
            message: format!("Method not found: {method}"),
            data: None,
        }
    }

    /// `-32602` — Invalid params.
    pub fn invalid_params(message: impl Into<String>) -> Self {
        Self {
            code: -32602,
            message: message.into(),
            data: None,
        }
    }

    /// `-32603` — Internal error.
    pub fn internal_error(message: impl Into<String>) -> Self {
        Self {
            code: -32603,
            message: message.into(),
            data: None,
        }
    }
}

/// 한 줄의 JSON-RPC 요청을 처리하고 응답 라인을 반환.
///
/// Notification (id 없음) 인 경우 `None` 반환.
/// 파싱 실패 시 stderr 로 로그하고 None.
pub fn handle_line(line: &str, engine: &Engine) -> Option<String> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    let req: JsonRpcRequest = match serde_json::from_str(trimmed) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("parse error: {e}");
            return None;
        }
    };
    let _id = req.id.as_ref()?; // notification (id 없음) 이면 silently consume.
    let resp = handle_request(&req, engine);
    Some(serde_json::to_string(&resp).expect("serialize response"))
}

/// JSON-RPC 요청을 라우팅하고 응답 객체를 반환.
pub fn handle_request(req: &JsonRpcRequest, engine: &Engine) -> JsonRpcResponse {
    let id = req.id.clone().unwrap_or(Value::Null);
    let result_or_err: Result<Value, JsonRpcError> = match req.method.as_str() {
        "initialize" => Ok(initialize_result()),
        "tools/list" => Ok(tools_list_result()),
        "tools/call" => handle_tools_call(req.params.as_ref(), engine),
        "ping" => Ok(json!({})),
        other => Err(JsonRpcError::method_not_found(other)),
    };
    match result_or_err {
        Ok(v) => JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            id,
            result: Some(v),
            error: None,
        },
        Err(e) => JsonRpcResponse {
            jsonrpc: "2.0".to_string(),
            id,
            result: None,
            error: Some(e),
        },
    }
}

fn initialize_result() -> Value {
    json!({
        "protocolVersion": crate::MCP_PROTOCOL_VERSION,
        "capabilities": {
            "tools": {
                "listChanged": false
            }
        },
        "serverInfo": {
            "name": crate::SERVER_NAME,
            "version": crate::SERVER_VERSION
        }
    })
}

fn tools_list_result() -> Value {
    let tools = tool_definitions();
    json!({ "tools": tools })
}

fn handle_tools_call(params: Option<&Value>, engine: &Engine) -> Result<Value, JsonRpcError> {
    let params =
        params.ok_or_else(|| JsonRpcError::invalid_params("tools/call requires params"))?;
    let name = params
        .get("name")
        .and_then(|v| v.as_str())
        .ok_or_else(|| JsonRpcError::invalid_params("tools/call: missing 'name'"))?;
    let args = params
        .get("arguments")
        .cloned()
        .unwrap_or(Value::Object(Default::default()));
    match call_tool(name, &args, engine) {
        Ok(text) => Ok(json!({
            "content": [{ "type": "text", "text": text }],
            "isError": false
        })),
        Err(e) => Ok(json!({
            "content": [{ "type": "text", "text": e.to_string() }],
            "isError": true
        })),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::Engine;

    fn test_engine() -> Engine {
        Engine::new_in_memory()
    }

    #[test]
    fn initialize_returns_capabilities() {
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(json!(1)),
            method: "initialize".to_string(),
            params: None,
        };
        let resp = handle_request(&req, &test_engine());
        assert!(resp.error.is_none());
        let r = resp.result.unwrap();
        assert_eq!(r["protocolVersion"], crate::MCP_PROTOCOL_VERSION);
        assert!(r["capabilities"]["tools"].is_object());
        assert_eq!(r["serverInfo"]["name"], crate::SERVER_NAME);
    }

    #[test]
    fn tools_list_returns_at_least_eleven_tools() {
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(json!(2)),
            method: "tools/list".to_string(),
            params: None,
        };
        let resp = handle_request(&req, &test_engine());
        let tools = resp.result.unwrap()["tools"].as_array().unwrap().clone();
        assert!(
            tools.len() >= 11,
            "expected >= 11 tools, got {}",
            tools.len()
        );
        let names: Vec<String> = tools
            .iter()
            .map(|t| t["name"].as_str().unwrap().to_string())
            .collect();
        for required in [
            "library_search",
            "library_get",
            "synth_sequence",
            "synth_layer",
            "synth_morph",
            "synth_mutate",
            "synth_mirror",
            "synth_procedural",
            "validate",
            "commit",
            "preview",
        ] {
            assert!(
                names.contains(&required.to_string()),
                "missing tool: {required}"
            );
        }
    }

    #[test]
    fn unknown_method_returns_method_not_found() {
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(json!(3)),
            method: "wat".to_string(),
            params: None,
        };
        let resp = handle_request(&req, &test_engine());
        assert!(resp.result.is_none());
        let err = resp.error.unwrap();
        assert_eq!(err.code, -32601);
    }

    #[test]
    fn notification_returns_none() {
        let line = r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#;
        let out = handle_line(line, &test_engine());
        assert!(out.is_none());
    }

    #[test]
    fn malformed_json_logs_and_returns_none() {
        let line = "not even json";
        let out = handle_line(line, &test_engine());
        assert!(out.is_none());
    }

    #[test]
    fn empty_line_returns_none() {
        let out = handle_line("   ", &test_engine());
        assert!(out.is_none());
    }

    #[test]
    fn ping_returns_empty_result() {
        let req = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: Some(json!(99)),
            method: "ping".to_string(),
            params: None,
        };
        let resp = handle_request(&req, &test_engine());
        assert!(resp.error.is_none());
        assert!(resp.result.unwrap().is_object());
    }
}
