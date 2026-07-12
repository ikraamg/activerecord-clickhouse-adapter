# activerecord-clickhouse-adapter

A fully featured Active Record adapter for [ClickHouse](https://clickhouse.com). Native
types, server-side bind parameters, MergeTree-aware migrations, and real instrumentation
(read rows/bytes, server elapsed time) on every query.

**Status: pre-alpha, under active development.** See [PLAN.md](PLAN.md) for the
architecture and roadmap.

## Development

Everything runs against a real ClickHouse server — no mocks.

```sh
docker compose up -d --wait   # ClickHouse 25.8 LTS on localhost:18123 (tmpfs, disposable)
bundle install
bundle exec rspec
bundle exec rubocop
```

Run the suite against Rails edge (local `../rails-main` worktree):

```sh
RAILS_SOURCE=edge bundle install
RAILS_SOURCE=edge bundle exec rspec
```

## Usage (target API)

```yaml
# config/database.yml
analytics:
  adapter: clickhouse
  host: localhost
  port: 8123
  database: analytics_production
  username: rails
  password: <%= ENV["CLICKHOUSE_PASSWORD"] %>
```

```ruby
class AnalyticsRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :analytics, reading: :analytics }
end
```
