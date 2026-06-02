use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Entity {
    pub name: String,
    #[serde(rename = "entityType")]
    pub entity_type: String,
    #[serde(default)]
    pub observations: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct Relation {
    pub from: String,
    pub to: String,
    #[serde(rename = "relationType")]
    pub relation_type: String,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Graph {
    pub entities: Vec<Entity>,
    pub relations: Vec<Relation>,
}

impl Graph {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn from_ndjson(s: &str) -> Self {
        let mut g = Graph::new();
        for (lineno, raw) in s.lines().enumerate() {
            let line = raw.trim();
            if line.is_empty() {
                continue;
            }
            let parsed: Result<serde_json::Value, _> = serde_json::from_str(line);
            let Ok(mut v) = parsed else {
                tracing::warn!(line = lineno + 1, "memory.jsonl malformed, skipping");
                continue;
            };
            let kind = v
                .as_object_mut()
                .and_then(|m| m.remove("type"))
                .and_then(|v| v.as_str().map(String::from));
            match kind.as_deref() {
                Some("entity") => {
                    if let Ok(e) = serde_json::from_value::<Entity>(v) {
                        g.entities.push(e);
                    }
                }
                Some("relation") => {
                    if let Ok(r) = serde_json::from_value::<Relation>(v) {
                        g.relations.push(r);
                    }
                }
                _ => {}
            }
        }
        g
    }

    pub fn to_ndjson(&self) -> String {
        let mut out = String::new();
        for e in &self.entities {
            let mut m = serde_json::Map::new();
            m.insert("type".into(), serde_json::Value::String("entity".into()));
            if let serde_json::Value::Object(o) = serde_json::to_value(e).unwrap() {
                m.extend(o);
            }
            out.push_str(&serde_json::to_string(&m).unwrap());
            out.push('\n');
        }
        for r in &self.relations {
            let mut m = serde_json::Map::new();
            m.insert("type".into(), serde_json::Value::String("relation".into()));
            if let serde_json::Value::Object(o) = serde_json::to_value(r).unwrap() {
                m.extend(o);
            }
            out.push_str(&serde_json::to_string(&m).unwrap());
            out.push('\n');
        }
        out
    }

}

pub fn rel_key(r: &Relation) -> (String, String, String) {
    (r.from.clone(), r.to.clone(), r.relation_type.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let mut g = Graph::new();
        g.entities.push(Entity {
            name: "a".into(),
            entity_type: "person".into(),
            observations: vec!["likes coffee".into()],
        });
        g.relations.push(Relation {
            from: "a".into(),
            to: "b".into(),
            relation_type: "knows".into(),
        });
        let s = g.to_ndjson();
        let g2 = Graph::from_ndjson(&s);
        assert_eq!(g2.entities.len(), 1);
        assert_eq!(g2.relations.len(), 1);
        assert_eq!(g2.entities[0].name, "a");
        assert_eq!(g2.relations[0].relation_type, "knows");
    }
}
