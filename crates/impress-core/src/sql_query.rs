use crate::query::{ItemQuery, Predicate, SortDescriptor};
use rusqlite::types::Value as SqlValue;

/// Compiled SQL query fragment with bound parameters.
pub(crate) struct CompiledQuery {
    pub where_clause: String,
    pub params: Vec<SqlValue>,
    pub order_clause: String,
    pub limit_offset: String,
}

/// Translate an ItemQuery into SQL fragments.
pub(crate) fn compile_query(q: &ItemQuery) -> CompiledQuery {
    let mut params = Vec::new();

    // WHERE
    let mut conditions = Vec::new();
    if let Some(ref schema) = q.schema {
        conditions.push("schema_ref = ?".to_string());
        params.push(SqlValue::Text(schema.clone()));
    }
    for pred in &q.predicates {
        let (sql, pred_params) = compile_predicate(pred);
        conditions.push(sql);
        params.extend(pred_params);
    }
    let where_clause = if conditions.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", conditions.join(" AND "))
    };

    // ORDER BY
    let order_clause = compile_sort(&q.sort);

    // LIMIT / OFFSET
    let mut limit_offset = String::new();
    if let Some(limit) = q.limit {
        limit_offset.push_str(&format!("LIMIT {}", limit));
        if let Some(offset) = q.offset {
            limit_offset.push_str(&format!(" OFFSET {}", offset));
        }
    }

    CompiledQuery {
        where_clause,
        params,
        order_clause,
        limit_offset,
    }
}

fn compile_predicate(pred: &Predicate) -> (String, Vec<SqlValue>) {
    let mut params = Vec::new();
    let sql = match pred {
        Predicate::Eq(field, value) => {
            let col = field_to_column(field);
            params.push(value_to_sql(value));
            format!("{} = ?", col)
        }
        Predicate::Neq(field, value) => {
            let col = field_to_column(field);
            params.push(value_to_sql(value));
            format!("{} != ?", col)
        }
        Predicate::Gt(field, value) => {
            let col = field_to_column(field);
            params.push(value_to_sql(value));
            format!("{} > ?", col)
        }
        Predicate::Lt(field, value) => {
            let col = field_to_column(field);
            params.push(value_to_sql(value));
            format!("{} < ?", col)
        }
        Predicate::Gte(field, value) => {
            let col = field_to_column(field);
            params.push(value_to_sql(value));
            format!("{} >= ?", col)
        }
        Predicate::Lte(field, value) => {
            let col = field_to_column(field);
            params.push(value_to_sql(value));
            format!("{} <= ?", col)
        }
        Predicate::Contains(field, text) => {
            // Use FTS for title/author_text/abstract_text/note, LIKE for others
            if is_fts_field(field) {
                params.push(SqlValue::Text(fts_escape(text)));
                "id IN (SELECT item_id FROM items_fts WHERE items_fts MATCH ?)".to_string()
            } else {
                let col = field_to_column(field);
                params.push(SqlValue::Text(format!("%{}%", text)));
                format!("{} LIKE ?", col)
            }
        }
        Predicate::In(field, values) => {
            let col = field_to_column(field);
            let placeholders: Vec<String> = values
                .iter()
                .map(|v| {
                    params.push(value_to_sql(v));
                    "?".to_string()
                })
                .collect();
            format!("{} IN ({})", col, placeholders.join(", "))
        }
        Predicate::HasTag(tag_path) => {
            // Match exact tag or descendants (prefix match)
            params.push(SqlValue::Text(tag_path.clone()));
            params.push(SqlValue::Text(format!("{}/", tag_path)));
            "id IN (SELECT item_id FROM item_tags WHERE tag_path = ? OR tag_path LIKE ? || '%')".to_string()
        }
        Predicate::HasFlag(color) => match color {
            Some(c) => {
                params.push(SqlValue::Text(c.clone()));
                "flag_color = ?".to_string()
            }
            None => "flag_color IS NOT NULL".to_string(),
        },
        Predicate::IsRead(v) => {
            format!("is_read = {}", if *v { 1 } else { 0 })
        }
        Predicate::IsStarred(v) => {
            format!("is_starred = {}", if *v { 1 } else { 0 })
        }
        Predicate::HasParent(id) => {
            params.push(SqlValue::Text(id.to_string()));
            "parent_id = ?".to_string()
        }
        Predicate::HasReference(edge_type, target_id) => {
            let edge_str = serde_json::to_string(edge_type).unwrap_or_default();
            params.push(SqlValue::Text(target_id.to_string()));
            params.push(SqlValue::Text(edge_str));
            "id IN (SELECT source_id FROM item_references WHERE target_id = ? AND edge_type = ?)".to_string()
        }
        Predicate::ReferencedBy(edge_type, source_id) => {
            let edge_str = serde_json::to_string(edge_type).unwrap_or_default();
            params.push(SqlValue::Text(source_id.to_string()));
            params.push(SqlValue::Text(edge_str));
            "id IN (SELECT target_id FROM item_references WHERE source_id = ? AND edge_type = ?)".to_string()
        }
        Predicate::And(preds) => {
            let mut sub_params = Vec::new();
            let parts: Vec<String> = preds
                .iter()
                .map(|p| {
                    let (sql, ps) = compile_predicate(p);
                    sub_params.extend(ps);
                    sql
                })
                .collect();
            params.extend(sub_params);
            if parts.is_empty() {
                "1".to_string()
            } else {
                format!("({})", parts.join(" AND "))
            }
        }
        Predicate::Or(preds) => {
            let mut sub_params = Vec::new();
            let parts: Vec<String> = preds
                .iter()
                .map(|p| {
                    let (sql, ps) = compile_predicate(p);
                    sub_params.extend(ps);
                    sql
                })
                .collect();
            params.extend(sub_params);
            if parts.is_empty() {
                "0".to_string()
            } else {
                format!("({})", parts.join(" OR "))
            }
        }
        Predicate::Not(pred) => {
            let (sql, ps) = compile_predicate(pred);
            params.extend(ps);
            format!("NOT ({})", sql)
        }
    };
    (sql, params)
}

fn compile_sort(sorts: &[SortDescriptor]) -> String {
    if sorts.is_empty() {
        return String::new();
    }
    let parts: Vec<String> = sorts
        .iter()
        .map(|s| {
            let col = sort_field_to_column(&s.field);
            let dir = if s.ascending { "ASC" } else { "DESC" };
            format!("{} {}", col, dir)
        })
        .collect();
    format!("ORDER BY {}", parts.join(", "))
}

/// Map a field path to a SQL column expression.
fn field_to_column(field: &str) -> String {
    match field {
        "id" => "id".to_string(),
        "schema" | "schema_ref" => "schema_ref".to_string(),
        "created" => "created".to_string(),
        "modified" => "modified".to_string(),
        "author" => "author".to_string(),
        "author_kind" => "author_kind".to_string(),
        "is_read" => "is_read".to_string(),
        "is_starred" => "is_starred".to_string(),
        "flag_color" => "flag_color".to_string(),
        "flag_style" => "flag_style".to_string(),
        "flag_length" => "flag_length".to_string(),
        "parent_id" | "parent" => "parent_id".to_string(),
        "logical_clock" => "logical_clock".to_string(),
        "origin" => "origin".to_string(),
        "canonical_id" => "canonical_id".to_string(),
        "priority" => "priority".to_string(),
        "visibility" => "visibility".to_string(),
        "message_type" => "message_type".to_string(),
        "produced_by" => "produced_by".to_string(),
        "version" => "version".to_string(),
        "batch_id" => "batch_id".to_string(),
        "op_target_id" => "op_target_id".to_string(),
        // payload.field → json_extract(payload, '$.field')
        f if f.starts_with("payload.") => {
            let json_path = format!("$.{}", &f["payload.".len()..]);
            format!("json_extract(payload, '{}')", json_path)
        }
        // Bare field name also treated as payload access
        f => format!("json_extract(payload, '$.{}')", f),
    }
}

/// Map a sort field to a SQL column expression.
fn sort_field_to_column(field: &str) -> String {
    match field {
        "created" => "created".to_string(),
        "modified" => "modified".to_string(),
        "is_read" => "is_read".to_string(),
        "is_starred" => "is_starred".to_string(),
        "flag_color" => "flag_color".to_string(),
        f if f.starts_with("payload.") => {
            let json_path = format!("$.{}", &f["payload.".len()..]);
            format!("json_extract(payload, '{}')", json_path)
        }
        f => format!("json_extract(payload, '$.{}')", f),
    }
}

/// Fields that should use FTS search.
fn is_fts_field(field: &str) -> bool {
    matches!(
        field,
        "title" | "author_text" | "abstract_text" | "note" | "payload.title"
            | "payload.author_text"
            | "payload.abstract_text"
            | "payload.note"
    )
}

/// Escape FTS5 special characters in a query string.
fn fts_escape(text: &str) -> String {
    // For FTS5, wrap terms in double quotes to treat as literal
    format!("\"{}\"", text.replace('"', "\"\""))
}

/// Convert an impress Value to a rusqlite SqlValue.
pub(crate) fn value_to_sql(value: &crate::item::Value) -> SqlValue {
    match value {
        crate::item::Value::Null => SqlValue::Null,
        crate::item::Value::Bool(b) => SqlValue::Integer(if *b { 1 } else { 0 }),
        crate::item::Value::Int(i) => SqlValue::Integer(*i),
        crate::item::Value::Float(f) => SqlValue::Real(*f),
        crate::item::Value::String(s) => SqlValue::Text(s.clone()),
        crate::item::Value::Array(_) | crate::item::Value::Object(_) => {
            SqlValue::Text(serde_json::to_string(value).unwrap_or_default())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::Value;
    use crate::query::{ItemQuery, Predicate, SortDescriptor};
    use uuid::Uuid;

    #[test]
    fn compile_empty_query() {
        let q = ItemQuery::default();
        let compiled = compile_query(&q);
        assert_eq!(compiled.where_clause, "");
        assert_eq!(compiled.order_clause, "");
        assert_eq!(compiled.limit_offset, "");
        assert!(compiled.params.is_empty());
    }

    #[test]
    fn compile_schema_filter() {
        let q = ItemQuery {
            schema: Some("bibliography-entry".into()),
            ..Default::default()
        };
        let compiled = compile_query(&q);
        assert!(compiled.where_clause.contains("schema_ref = ?"));
        assert_eq!(compiled.params.len(), 1);
    }

    #[test]
    fn compile_has_parent() {
        let parent_id = Uuid::new_v4();
        let q = ItemQuery {
            predicates: vec![Predicate::HasParent(parent_id)],
            ..Default::default()
        };
        let compiled = compile_query(&q);
        assert!(compiled.where_clause.contains("parent_id = ?"));
    }

    #[test]
    fn compile_is_read() {
        let q = ItemQuery {
            predicates: vec![Predicate::IsRead(true)],
            ..Default::default()
        };
        let compiled = compile_query(&q);
        assert!(compiled.where_clause.contains("is_read = 1"));
    }

    #[test]
    fn compile_has_flag_some() {
        let q = ItemQuery {
            predicates: vec![Predicate::HasFlag(Some("red".into()))],
            ..Default::default()
        };
        let compiled = compile_query(&q);
        assert!(compiled.where_clause.contains("flag_color = ?"));
    }

    #[test]
    fn compile_has_flag_any() {
        let q = ItemQuery {
            predicates: vec![Predicate::HasFlag(None)],
            ..Default::default()
        };
        let compiled = compile_query(&q);
        assert!(compiled.where_clause.contains("flag_color IS NOT NULL"));
    }

    #[test]
    fn compile_has_tag() {
        let q = ItemQuery {
            predicates: vec![Predicate::HasTag("methods/sims".into())],
            ..Default::default()
        };
        let compiled = compile_query(&q);
        assert!(compiled.where_clause.contains("item_tags"));
        assert_eq!(compiled.params.len(), 2); // exact + prefix
    }

    #[test]
    fn compile_fts_search() {
        let q = ItemQuery {
            predicates: vec![Predicate::Contains("title".into(), "dark matter".into())],
            ..Default::default()
        };
        let compiled = compile_query(&q);
        assert!(compiled.where_clause.contains("items_fts MATCH"));
    }

    #[test]
    fn compile_payload_field() {
        let q = ItemQuery {
            predicates: vec![Predicate::Eq(
                "payload.doi".into(),
                Value::String("10.1234/test".into()),
            )],
            ..Default::default()
        };
        let compiled = compile_query(&q);
        assert!(compiled.where_clause.contains("json_extract(payload, '$.doi')"));
    }

    #[test]
    fn compile_nested_and_or() {
        let q = ItemQuery {
            predicates: vec![Predicate::And(vec![
                Predicate::IsRead(false),
                Predicate::Or(vec![
                    Predicate::HasTag("methods".into()),
                    Predicate::HasFlag(Some("red".into())),
                ]),
            ])],
            ..Default::default()
        };
        let compiled = compile_query(&q);
        assert!(compiled.where_clause.contains("AND"));
        assert!(compiled.where_clause.contains("OR"));
    }

    #[test]
    fn compile_sort() {
        let q = ItemQuery {
            sort: vec![
                SortDescriptor {
                    field: "created".into(),
                    ascending: false,
                },
                SortDescriptor {
                    field: "payload.title".into(),
                    ascending: true,
                },
            ],
            ..Default::default()
        };
        let compiled = compile_query(&q);
        assert!(compiled.order_clause.contains("created DESC"));
        assert!(compiled.order_clause.contains("json_extract(payload, '$.title') ASC"));
    }

    #[test]
    fn compile_limit_offset() {
        let q = ItemQuery {
            limit: Some(50),
            offset: Some(100),
            ..Default::default()
        };
        let compiled = compile_query(&q);
        assert_eq!(compiled.limit_offset, "LIMIT 50 OFFSET 100");
    }

    #[test]
    fn compile_not_predicate() {
        let q = ItemQuery {
            predicates: vec![Predicate::Not(Box::new(Predicate::IsRead(true)))],
            ..Default::default()
        };
        let compiled = compile_query(&q);
        assert!(compiled.where_clause.contains("NOT (is_read = 1)"));
    }
}
