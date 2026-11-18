//! Compact JSON with object keys sorted by raw UTF-8 bytes.
//!
//! Signed catalog and policy bodies use this encoding. Keys in those documents
//! are ASCII, so the order matches the usual canonical-JSON rules. The verifier
//! does not reinterpret a body: the signed bytes must already be this encoding.

use serde_json::{Map, Value};

/// Canonical encoding of `value`. No extra whitespace, no trailing newline.
pub fn canonical_json(value: &Value) -> String {
    let mut out = String::new();
    write_value(value, &mut out);
    out
}

fn write_value(value: &Value, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Number(number) => out.push_str(&number.to_string()),
        Value::String(text) => {
            let encoded = serde_json::to_string(text).expect("a string is finite json");
            out.push_str(&encoded);
        }
        Value::Array(items) => {
            out.push('[');
            for (index, item) in items.iter().enumerate() {
                if index > 0 {
                    out.push(',');
                }
                write_value(item, out);
            }
            out.push(']');
        }
        Value::Object(map) => write_object(map, out),
    }
}

fn write_object(map: &Map<String, Value>, out: &mut String) {
    let mut keys: Vec<&String> = map.keys().collect();
    keys.sort();
    out.push('{');
    for (index, key) in keys.iter().enumerate() {
        if index > 0 {
            out.push(',');
        }
        let encoded = serde_json::to_string(key).expect("a key is finite json");
        out.push_str(&encoded);
        out.push(':');
        write_value(&map[*key], out);
    }
    out.push('}');
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn keys_are_sorted_and_encoding_is_stable() {
        let value = json!({"b": 1, "a": {"d": true, "c": "x"}});
        assert_eq!(canonical_json(&value), r#"{"a":{"c":"x","d":true},"b":1}"#);
        assert_eq!(canonical_json(&value), canonical_json(&value));
    }
}
