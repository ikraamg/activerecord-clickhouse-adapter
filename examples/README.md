# Examples

## OLAP on Rails (`olap_on_rails.rb`)

A runnable tour of the adapter's ClickHouse-native surface, expressed as
ordinary Active Record. The domain is web analytics:

- **Fact table**: a partitioned `MergeTree` with a `(site_id, ts)` sorting key
  and no autoincrement id.
- **Ingestion**: `insert_all!` for small batches, `insert_stream` for one
  chunked HTTP insert from a lazy enumerator.
- **Query surface**: `prewhere`, `limit_by`, `settings`, `group_by_period`,
  `rollup`, window functions, and the approximate/conditional aggregates
  (`uniq_count`, `quantile`, `top_k`, `arg_max`, `if:`).
- **Dictionaries**: `dict_get` replaces the dimension JOIN.
- **Pre-aggregation pipeline**: a materialized view folds raw inserts into an
  `AggregatingMergeTree`; reads finish the partial states with `merge: true`.
- **Mutable dimensions**: `ReplacingMergeTree` + `.final` — the OLAP update is
  a re-insert.
- **Operations**: partition lifecycle and `EXPLAIN`, plus the per-query server
  stats (`read_rows`, `written_rows`) on `sql.active_record` notifications.

Run it against the compose server:

```sh
docker compose up -d --wait
bundle exec ruby examples/olap_on_rails.rb
```

`spec/examples/olap_on_rails_spec.rb` runs the script in CI, so the example
cannot drift from the adapter.
