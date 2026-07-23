//! Parquet reader round-trip: write a small file with the parquet crate's
//! low-level API, read it back through the implore-io `DataReader` interface.
#![cfg(feature = "parquet")]

use std::fs::File;
use std::sync::Arc;

use parquet::data_type::{DoubleType, Int64Type};
use parquet::file::properties::WriterProperties;
use parquet::file::writer::SerializedFileWriter;
use parquet::schema::parser::parse_message_type;

use implore_io::reader::{open_file, DataReader};
use implore_io::schema::DataColumn;

fn write_sample(path: &std::path::Path, n: usize) {
    let message = "
        message sample {
            required double flux;
            required int64 idx;
        }
    ";
    let schema = Arc::new(parse_message_type(message).unwrap());
    let file = File::create(path).unwrap();
    let props = Arc::new(WriterProperties::builder().build());
    let mut writer = SerializedFileWriter::new(file, schema, props).unwrap();

    let flux: Vec<f64> = (0..n).map(|i| (i as f64) * 0.5).collect();
    let idx: Vec<i64> = (0..n as i64).collect();

    let mut rg = writer.next_row_group().unwrap();
    {
        let mut col = rg.next_column().unwrap().unwrap();
        col.typed::<DoubleType>()
            .write_batch(&flux, None, None)
            .unwrap();
        col.close().unwrap();
    }
    {
        let mut col = rg.next_column().unwrap().unwrap();
        col.typed::<Int64Type>()
            .write_batch(&idx, None, None)
            .unwrap();
        col.close().unwrap();
    }
    rg.close().unwrap();
    writer.close().unwrap();
}

#[test]
fn parquet_write_read_roundtrip() {
    let dir = std::env::temp_dir();
    let path = dir.join(format!("implore_pq_test_{}.parquet", std::process::id()));
    write_sample(&path, 100);

    // Through the generic open_file dispatch (extension-based).
    let reader = open_file(&path.to_string_lossy()).expect("open parquet");
    assert_eq!(reader.format_name(), "parquet");

    let schema = reader.read_schema().expect("schema");
    assert_eq!(schema.num_records, 100);
    let names: Vec<&str> = schema.columns.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["flux", "idx"]);

    // Column values + to_f64 (the plot-panel path).
    let flux = reader.read_column("flux").expect("flux column");
    let flux64 = flux.to_f64().expect("numeric");
    assert_eq!(flux64.len(), 100);
    assert_eq!(flux64[0], 0.0);
    assert_eq!(flux64[99], 49.5);

    let idx = reader.read_column("idx").expect("idx column");
    match &idx {
        DataColumn::Int64(v) => assert_eq!(v[99], 99),
        other => panic!("expected Int64, got {other:?}"),
    }

    // Missing column errors cleanly.
    assert!(reader.read_column("nope").is_err());

    let _ = std::fs::remove_file(&path);
}
