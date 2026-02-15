---
title: "DuckLake: ACID Transactions for Your Data Lakehouse"
pubDatetime: 2026-02-07T10:00:00+01:00
description: "DuckLake brings ACID transactions, time travel, and schema evolution to your Parquet-based data lake—without the operational overhead of traditional lakehouse solutions."
heroImage: /assets/img/2026/ducklake/ducklake.png
tags: ["ducklake", "duckdb", "data-lake", "analytics", "parquet", "dlt", "dbt", "elt"]
---

## What is DuckLake?

DuckLake is an open table format that adds ACID transactions to Parquet files. It covers the same ground as Delta Lake or Apache Iceberg—snapshots, time travel, schema evolution—but takes a different architectural approach that trades ecosystem maturity for simplicity.

> Much of the inspiration for this article comes from the [DuckLake presentation](https://www.youtube.com/watch?v=zeonmOO9jm4) by DuckDB creators Hannes Mühleisen and Mark Raasveldt. It's a refreshingly honest talk that walks through the design rationale and what they think existing formats get wrong. It's what got me interested enough to build a pipeline on top of DuckLake and write this up.

The core idea: **lakehouse table formats got complex because they tried to make blob storage behave like a transactional metadata store.** DuckLake takes a different route—put all metadata (catalog + table metadata) into a real SQL database, and keep the actual data as Parquet on object storage.

## The Metadata File Forest Problem

Parquet files are excellent for analytical workloads: columnar storage, efficient compression, and universal support across tools. But they lack transaction semantics. What happens when two processes write to the same dataset? How do you roll back a failed write? How do you query data as it existed yesterday?

Apache Iceberg, Delta Lake, and Apache Hudi solve these problems by storing metadata alongside data as files in blob storage: JSON manifests, Avro snapshots, checkpoint files, transaction logs. Over time this creates what you might call a **metadata file forest**—lots of small files that need to be read, reconciled, and garbage-collected just to answer the question "what is the current state of this table?"

In practice, this leads to a few pain points:

- **Metadata bloat**: Manifest lists and snapshot files accumulate over time, requiring periodic compaction and cleanup
- **Cold start latency**: Reading the current table state means fetching and parsing multiple metadata files from object storage—each with its own network round-trip
- **Atomicity gymnastics**: Object stores don't support atomic multi-file writes, so formats rely on rename-based commits and optimistic concurrency that can get tricky at scale
- **Operational complexity**: You need Spark or a comparable engine just to manage metadata—compaction jobs, snapshot expiration, orphan file cleanup

### Catalogs Are a Database Anyway

The ecosystem recognized these issues and responded by adding *catalogs*—transactional services like the Hive Metastore, AWS Glue, or Nessie—that map table names to locations and versions. But this raises a reasonable question: **if you already need a database for some metadata, why not put *all* metadata there?**

That's the bet DuckLake makes.

## How DuckLake Works

DuckLake stores all metadata—schemas, snapshots, column statistics, partition info—in relational tables using standard SQL transactions. The metadata database can be:

- **DuckDB or SQLite** for local/embedded use (single-file, zero config)
- **PostgreSQL or MySQL** for multi-user, server-based deployments

Any SQL database that supports ACID transactions and primary keys can serve as the catalog database.

Data stays as Parquet files on whatever storage you're already using: local filesystem, S3, GCS, or any S3-compatible object store. The metadata layer gets ACID guarantees from a SQL engine, while the data layer stays in a format every tool can read.

```
┌─────────────────────────────────────────┐
│           DuckLake Architecture          │
├─────────────────────────────────────────┤
│                                         │
│   ┌───────────────┐                     │
│   │  DuckDB /    │  ← Metadata layer   │
│   │  PostgreSQL / │    (SQL + ACID)     │
│   │  MySQL/SQLite │                     │
│   └───────┬───────┘                     │
│           │                             │
│           ▼                             │
│   ┌───────────────┐                     │
│   │  Parquet on   │  ← Data layer       │
│   │  S3 / GCS /   │    (object storage) │
│   │  local FS     │                     │
│   └───────────────┘                     │
│                                         │
└─────────────────────────────────────────┘
```

The basic insight is that metadata operations—schema lookups, snapshot resolution, statistics queries—are exactly the kind of work SQL databases have been doing well for decades.

## What You Get

### ACID Transactions Across Multiple Tables

Because metadata lives in a SQL database, concurrent readers and writers are handled by the database's own transaction machinery. Failed writes don't leave corrupted state. You also get **cross-table transactions**—insert into a fact table and update a dimension table in a single atomic operation. With file-based formats, this is difficult to achieve.

### Snapshots and Time Travel

Every write creates a snapshot. You can query your data as it existed at any point in its history, which is useful for debugging pipeline issues or auditing changes. Because snapshot metadata is just rows in a SQL table, resolving "what did this table look like at timestamp X?" is an indexed query rather than a walk through a chain of manifest files. I'll show concrete examples of this later.

### Schema Evolution

You can add columns, rename fields, and change types without rewriting data. The catalog tracks schema history alongside data history, so time travel queries return results using the schema that was active at the queried point in time.

### Isolation

Read and write operations are isolated from each other. Long-running analytical queries see a consistent snapshot while concurrent writes proceed. This comes from the SQL metadata store's transaction isolation—it's not something DuckLake had to invent.

### Minimal Setup (for Local Use)

In local mode, DuckLake needs no servers or configuration files. With DuckDB or SQLite as the catalog, you can get a transactional lakehouse running on your laptop in a couple of minutes. That said, "lakehouse on your laptop" is more useful for development and testing than for production—for that, you'll want a proper catalog backend.

## Where MotherDuck Fits In

For production use, MotherDuck offers a managed DuckLake experience: hosted catalog, compute close to your data, and automatic optimization. The model is **bring your own bucket**—your Parquet data stays in your S3 or GCS account, MotherDuck handles the catalog and compute.

The practical upgrade path looks like: start local with DuckDB for development, use PostgreSQL as the catalog when you need multi-user access, and move to MotherDuck if you want someone else to manage the infrastructure.

## DuckLake in Practice: A Real ELT Pipeline

To test whether DuckLake actually holds up beyond toy examples, I built a reference implementation—[dwh-on-a-lake](https://github.com/ekoepplin/dwh-on-a-lake)—that wires up an end-to-end ELT pipeline using three open-source tools:

- **[dlt](https://dlthub.com/)** (data load tool) for ingestion
- **[dbt](https://www.getdbt.com/)** for transformation
- **DuckLake** as the storage layer

The stack is Python files, SQL files, and YAML. It runs locally without any infrastructure beyond a Python environment.

### Ingestion: dlt Into DuckLake

dlt handles extraction and loading. The important pattern here is `write_disposition="merge"` with a `primary_key`—dlt writes into DuckLake, and DuckLake handles deduplication as part of the transaction:

```python
@dlt.resource(
    table_name="articles_us_en",
    write_disposition="merge",
    primary_key="url",
)
def get_articles_us_en(api_key=dlt.secrets.value):
    newsapi = NewsApiClient(api_key=api_key)
    response = newsapi.get_everything(language="en", q="Data Engineering", ...)

    for article in response.get("articles", []):
        validated = Article.model_validate(article)  # Pydantic validation
        yield validated.model_dump(mode="json")
```

Run this pipeline twice with overlapping data and DuckLake's merge handles the dedup—you don't write any dedup logic yourself. If a load fails mid-way, the transaction rolls back and you don't end up with partial state.

The pipeline target is a single CLI flag:

```bash
# Local development: DuckLake with DuckDB catalog
uv run python newsapi_pipeline.py --dev

# Production: DuckLake with MotherDuck catalog
uv run python newsapi_pipeline.py --prod
```

Same code, same schema validation, different catalog backend.

### Transformation: dbt on DuckLake

dbt attaches to the DuckLake catalog and runs SQL transformations in the standard staging → intermediate → mart pattern. The `profiles.yml` shows how DuckLake plugs into dbt's existing DuckDB adapter:

```yaml
# Local dev: attach DuckLake catalog to in-memory DuckDB
dev:
  type: duckdb
  path: ":memory:"
  extensions:
    - ducklake
  attach:
    - path: /tmp/newsapi_ducklake_catalog.duckdb
      alias: newsapi_lake
      type: ducklake
      is_ducklake: true
      options:
        data_path: /tmp/newsapi_ducklake_data/

# Production: MotherDuck handles the catalog natively
motherduck:
  type: duckdb
  path: "md:?motherduck_token={{ env_var('MOTHERDUCK_TOKEN') }}"
  is_ducklake: true
```

From here, dbt models look like standard SQL—the staging layer renames and standardizes columns, the intermediate layer enriches with derived fields, and the mart layer aggregates for reporting:

```sql
-- mart_newsapi__articles.sql
SELECT
    article_date,
    source_name,
    COUNT(*) AS total_articles,
    SUM(CASE WHEN is_data_engineering_related THEN 1 ELSE 0 END)
        AS data_engineering_articles
FROM {{ ref('int_newsapi__articles') }}
GROUP BY article_date, source_name
ORDER BY article_date DESC, source_name
```

There's no DuckLake-specific syntax in the models. As far as dbt is concerned, it's reading and writing tables—it doesn't need to know those tables are backed by Parquet files managed through a DuckLake catalog.

### Data Quality at Every Layer

One pattern worth calling out: validation happens at every stage of the pipeline, not just at the end.

1. **At extraction**: Pydantic models validate schema and types before data enters the pipeline
2. **At load**: DuckLake's merge deduplicates on primary key with ACID guarantees
3. **At transformation**: dbt tests enforce uniqueness, not-null constraints, and accepted values

```yaml
# dbt schema tests (from int_newsapi__articles.yml)
columns:
  - name: url
    data_tests:
      - unique
      - not_null
  - name: topic_category
    data_tests:
      - accepted_values:
          arguments:
            values: ["Data Engineering", "AI", "Tech", "Startups", "Other"]
```

### Dev/Prod Parity

The full pipeline runs with a single `make` command:

```bash
make pipeline-dev         # Ingest → Transform → Test (local DuckLake)
make pipeline-motherduck  # Same pipeline, MotherDuck DuckLake
```

Identical code at every layer. The only difference is the connection string. This was one of the things that actually surprised me in practice—I expected more friction switching between local DuckDB and MotherDuck, but the dbt models and dlt pipeline genuinely don't change.

## Time Travel, Snapshots, and Change Tracking

I mentioned time travel earlier but kept it abstract. Here's what it actually looks like in practice, using the dwh-on-a-lake pipeline. Every write creates a snapshot, and because snapshots are rows in a SQL table, querying history is just SQL.

First, attach the local DuckLake catalog—this is the same catalog that dlt writes to and dbt reads from:

```sql
INSTALL ducklake; LOAD ducklake;
ATTACH '/tmp/newsapi_ducklake_catalog.duckdb' AS lake
    (TYPE DUCKLAKE, DATA_PATH '/tmp/newsapi_ducklake_data/');
```

### Listing Snapshots

Every DuckLake database exposes a `snapshots()` function that returns the full commit history. After running `make pipeline-dev` a couple of times, you'll see something like:

```sql
SELECT snapshot_id, snapshot_time, commit_message
FROM lake.snapshots();
```

| snapshot_id | snapshot_time           | commit_message               |
|-------------|-------------------------|------------------------------|
| 1           | 2026-02-07 10:00:00     | Initial article load         |
| 2           | 2026-02-07 14:30:00     | Incremental merge            |
| 3           | 2026-02-08 09:00:00     | dbt run                      |

Each snapshot corresponds to a pipeline action: dlt ingesting articles, dlt merging a second batch, dbt materializing the transformed models. You can also inspect the current state of your connection:

```sql
FROM lake.current_snapshot();
FROM lake.last_committed_snapshot();
```

### Querying Historical State

Time travel works with both snapshot versions and timestamps via the `AT` clause. Using the actual articles table from our pipeline:

```sql
-- How many articles did we have after the very first load?
SELECT COUNT(*) FROM lake.ingest_newsapi_v1.articles_us_en AT (VERSION => 1);

-- What did the articles table look like a week ago?
SELECT title, url, published_at
FROM lake.ingest_newsapi_v1.articles_us_en
AT (TIMESTAMP => now() - INTERVAL '1 week')
ORDER BY published_at DESC
LIMIT 10;
```

You can also attach the entire catalog at a point in time—useful when you want the raw articles *and* the dbt models to reflect the same historical moment:

```sql
-- Attach the catalog as it existed before today's pipeline run
ATTACH '/tmp/newsapi_ducklake_catalog.duckdb' AS lake_yesterday
    (TYPE DUCKLAKE, SNAPSHOT_TIME '2026-02-07 10:00:00');

-- Now compare: current mart vs. yesterday's mart
SELECT 'current' AS version, COUNT(*) AS articles FROM lake.dbt_dev.mart_newsapi__articles
UNION ALL
SELECT 'yesterday', COUNT(*) FROM lake_yesterday.dbt_dev.mart_newsapi__articles;
```

### Practical Use Case: Debugging a Bad Load

This is where time travel became useful for me in practice. Say you run `make ingest-dev` and the article counts in the mart look off. Instead of restoring backups or grepping through pipeline logs, you can just ask the database what changed:

```sql
-- Current row count in the raw articles table
SELECT COUNT(*) AS current_count
FROM lake.ingest_newsapi_v1.articles_us_en;

-- Row count before today's ingestion
SELECT COUNT(*) AS previous_count
FROM lake.ingest_newsapi_v1.articles_us_en
AT (TIMESTAMP => CURRENT_DATE::TIMESTAMP);

-- What exactly did the last pipeline run change?
SELECT change_type, COUNT(*) AS row_count
FROM lake.table_changes('ingest_newsapi_v1.articles_us_en', 1, 2)
GROUP BY change_type;
```

| change_type       | row_count |
|-------------------|-----------|
| insert            | 42        |
| update_preimage   | 7         |
| update_postimage  | 7         |

This tells you: between snapshot 1 and 2, dlt inserted 42 new articles and updated 7 existing ones (the merge on `url` in action). The `update_preimage` rows show the old values, `update_postimage` shows the new values—so you can see exactly which fields changed for each updated article.

Want to see the actual before/after for those 7 updated articles?

```sql
SELECT change_type, url, title
FROM lake.table_changes('ingest_newsapi_v1.articles_us_en', 1, 2)
WHERE change_type IN ('update_preimage', 'update_postimage')
ORDER BY url, change_type;
```

### Change Tracking Across Time Ranges

The `table_changes` function accepts either snapshot IDs or timestamps as bounds. This is useful for both real-time debugging and periodic auditing:

```sql
-- All changes across the full history (by snapshot ID)
SELECT * FROM lake.table_changes('ingest_newsapi_v1.articles_us_en', 1, 3)
ORDER BY snapshot_id;

-- Everything that changed in the last 24 hours (by timestamp)
SELECT change_type, title, published_at
FROM lake.table_changes(
    'ingest_newsapi_v1.articles_us_en',
    now() - INTERVAL '1 day',
    now()
)
ORDER BY published_at DESC;
```

Each row includes a `change_type` column (`insert`, `delete`, `update_preimage`, or `update_postimage`) alongside the full row data. It's essentially built-in change data capture. In the dwh-on-a-lake pipeline, I've found this useful for tracing how articles entered and evolved across ingestion runs—especially when debugging why a merge updated records I didn't expect it to.

### Annotating Snapshots

DuckLake also lets you attach commit messages and metadata to snapshots, which helps when you're looking at the history weeks later and trying to figure out what each snapshot was:

```sql
BEGIN;
INSERT INTO lake.ingest_newsapi_v1.articles_us_en VALUES (...);
CALL lake.set_commit_message(
    'newsapi-pipeline',
    'Daily incremental load - 42 new articles',
    extra_info => '{"source": "newsapi", "query": "Data Engineering", "batch_date": "2026-02-08"}'
);
COMMIT;
```

The `author`, `commit_message`, and `extra_info` fields show up in `snapshots()` output—similar to `git log` but for data. Combined with dlt's built-in `_dlt_load_id` column on every row, you can trace a record back to the pipeline run and snapshot that produced it.

## When Does DuckLake Make Sense?

Based on my experience building dwh-on-a-lake, DuckLake is a good fit when:

- **You don't want to manage metadata file cleanup**: No compaction jobs, no orphan file cleaners, no manifest expiration
- **You need multi-table transactions**: Atomic writes across multiple tables are straightforward since the metadata store is a real database
- **Your team is small**: You'd rather manage a PostgreSQL instance (or use MotherDuck) than operate Spark clusters for metadata management
- **You're already using DuckDB**: DuckLake is a natural extension if DuckDB is already part of your stack

The tradeoffs are real, though. You're adding a dependency on a SQL database for metadata—if that database goes down, your lakehouse is unavailable. The ecosystem is much younger than Iceberg or Delta, which means less tooling, fewer integrations, and less battle-testing at large scale. If you're running petabyte-scale workloads with dozens of concurrent writers, the established formats are probably still the safer choice.

But for small-to-medium teams that want lakehouse semantics without the operational overhead, DuckLake is worth evaluating. It's an open format with a published specification, so you're not locked into a single query engine.

## Getting Started

### Quick Start: DuckDB Extension

The fastest way to try DuckLake is through the DuckDB extension:

```sql
-- Install and load the DuckLake extension
INSTALL ducklake;
LOAD ducklake;

-- Attach a local DuckLake catalog (DuckDB as metadata store)
ATTACH 'ducklake:metadata.ducklake' AS my_lake;

-- Create a table—data is written as Parquet
CREATE TABLE my_lake.main.events (
    event_id INTEGER,
    event_type VARCHAR,
    created_at TIMESTAMP
);

-- Insert data transactionally
INSERT INTO my_lake.main.events VALUES
    (1, 'page_view', '2026-02-07 10:00:00'),
    (2, 'click', '2026-02-07 10:01:00');

-- Time travel: query a previous snapshot
SELECT * FROM ducklake_snapshots('my_lake', 'main', 'events');
```

### Full Reference Implementation

If you want to see how the pieces fit together in a real pipeline, the [dwh-on-a-lake](https://github.com/ekoepplin/dwh-on-a-lake) repo has the full implementation—dlt ingestion, dbt transformations, data quality tests, and the DuckLake configuration covered in this post. Clone the repo, set a NewsAPI key, and run:

```bash
make install       # Install dependencies
make pipeline-dev  # Ingest → Transform → Test (local DuckLake)
```

The same code runs against MotherDuck for production use by switching the target flag.

---
