use serde_json::Value;

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture() -> Value {
        json!({
            "metadata": {
                "name": "p1",
                "namespace": "default",
                "managedFields": [{"manager": "kubelet"}]
            },
            "spec": {
                "containers": [
                    {
                        "name": "app",
                        "image": "app:latest",
                        "env": [
                            {"name": "FOO", "value": "secret"},
                            {"name": "BAR", "valueFrom": {"secretKeyRef": {"name": "s", "key": "k"}}}
                        ]
                    }
                ],
                "initContainers": [
                    {
                        "name": "init",
                        "image": "init:latest",
                        "env": [{"name": "TOKEN", "value": "leak"}]
                    }
                ]
            }
        })
    }

    #[test]
    fn redact_strips_managed_fields() {
        let mut v = fixture();
        redact_pod(&mut v, false);
        assert!(v["metadata"]["managedFields"].is_null() || v["metadata"].get("managedFields").is_none());
    }

    #[test]
    fn redact_scrubs_env_values_by_default() {
        let mut v = fixture();
        redact_pod(&mut v, false);
        let env = &v["spec"]["containers"][0]["env"];
        let foo = &env[0];
        assert_eq!(foo["name"], "FOO");
        assert!(foo.get("value").is_none(), "value should be scrubbed: {foo}");
        let bar = &env[1];
        assert_eq!(bar["name"], "BAR");
        assert!(bar.get("valueFrom").is_none(), "valueFrom should be dropped: {bar}");
    }

    #[test]
    fn redact_scrubs_init_container_env_too() {
        let mut v = fixture();
        redact_pod(&mut v, false);
        let env = &v["spec"]["initContainers"][0]["env"];
        assert_eq!(env[0]["name"], "TOKEN");
        assert!(env[0].get("value").is_none());
    }

    #[test]
    fn redact_reveal_env_preserves_values() {
        let mut v = fixture();
        redact_pod(&mut v, true);
        // managedFields still gone.
        assert!(v["metadata"].get("managedFields").is_none());
        // env values survived.
        assert_eq!(v["spec"]["containers"][0]["env"][0]["value"], "secret");
    }
}

/// Strip env values + managedFields in-place. Always wipes managedFields;
/// env value is hidden unless reveal_env is allowed AND requested.
pub fn redact_pod(v: &mut Value, reveal_env: bool) {
    if let Some(meta) = v.get_mut("metadata").and_then(Value::as_object_mut) {
        meta.remove("managedFields");
    }
    if reveal_env {
        return;
    }
    if let Some(spec) = v.get_mut("spec").and_then(Value::as_object_mut) {
        for key in ["containers", "initContainers", "ephemeralContainers"] {
            if let Some(Value::Array(arr)) = spec.get_mut(key) {
                for c in arr.iter_mut() {
                    let Some(co) = c.as_object_mut() else { continue };
                    if let Some(Value::Array(env)) = co.get_mut("env") {
                        for e in env.iter_mut() {
                            if let Some(eo) = e.as_object_mut() {
                                let name = eo.get("name").cloned();
                                eo.clear();
                                if let Some(n) = name {
                                    eo.insert("name".into(), n);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
