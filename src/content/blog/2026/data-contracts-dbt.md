---
title: "Data Contracts in dbt: What Actually Gets Enforced"
pubDatetime: 2026-11-05T10:00:00+01:00
description: "Why data contracts matter: they build trust between the people who produce data and the people who use it, and they quietly give you a metadata repository on the side. From dbt model contracts to the Open Data Contract Standard, with a runnable example you can break on purpose."
heroImage: /assets/img/2026/data-contracts/hero.png
tags: ["data-contracts", "odcs", "dbt", "dlt", "duckdb", "data-governance"]
draft: false
---

## Why Data Contracts?

As soon as more than one team works with data, tables start depending on each other. One team loads orders, another builds a funnel dashboard on top, a third trains a recommendation model on the same table. Each step is reasonable on its own. Together they form a web of dependencies that nobody sees in full.

Then someone renames a column or changes a type. The producer's pipeline runs green. The dashboard breaks the next morning, the model quietly trains on nulls, and the other team finds out last. After that happens twice, people stop trusting the data. They build their own copies, add defensive checks everywhere, and ask in Slack before they use any table.

A **data contract** is the fix for that. It describes what a dataset promises, in a file that both sides can read and a machine can check. The shortest way to put it: **a data contract is an API for data.**

What I like most about data contracts is that they pay off twice:

1. **They build trust.** Promises become explicit, they get checked, and changes stop being surprises.
2. **They give you a metadata repository.** Every contract describes a dataset: what it's for, who owns it, how fresh it is, what you may do with it. Put the contracts in Git and you have a catalog of your data products, almost as a side effect.

This post starts with the contract dbt gives you for free, moves to the open standard, takes a contract apart field by field, and then looks at both payoffs. The examples come from a small demo (NewsAPI articles, dlt, dbt and DuckDB) that you can run and break yourself.

---

## What Is a Data Contract?

A data contract sits between two parties:

- The **producer** owns a dataset and promises its shape and behaviour.
- The **consumers** build on it: dashboards, ML features, other teams.

The contract covers more than columns and types. It says what each field means, which quality rules hold, how fresh the data is, who owns it and how it may be used. It lives in source control, next to the code that produces the data.

In Data Mesh terms, the producer's **output port** implements the contract, and a consumer's **input port** can verify it. The practical consequence: **contracts belong where data is handed over** to someone else, not on every internal step of a pipeline.

---

## Start Where You Are: dbt Model Contracts

If you use dbt, you already have a small contract mechanism. A **model contract** declares the columns and types a model must produce:

```yaml
models:
  - name: stg_newsapi__articles
    config:
      contract:
        enforced: true
    columns:
      - name: published_at
        data_type: timestamp with time zone
```

With `enforced: true`, dbt compares the model's output against this declaration on every build. If they disagree, the table is never created.

In my demo, that caught a real bug. Every file in the project said `published_at` was a plain `TIMESTAMP`. The data disagreed: dlt had loaded it as `TIMESTAMP WITH TIME ZONE`, and nobody knew, because the pipeline had never run end to end with real data. The first time it did, `dbt build` stopped:

```
This model has an enforced contract that failed.
Please ensure the name, data_type, and number of columns in your contract match the columns in your model's definition.
| column_name  | definition_type          | contract_type | mismatch_reason    |
| ------------ | ------------------------ | ------------- | ------------------ |
| published_at | TIMESTAMP WITH TIME ZONE | TIMESTAMP     | data type mismatch |
```

No broken table reached anyone downstream. That's the promise of contracts in one error message.

But a dbt model contract only goes so far. It covers **shape**, not quality, freshness, ownership or terms of use. And it **only lives in dbt**: a consumer who doesn't open your dbt project never sees it, and neither does a catalog, a quality tool or another team's Spark job. That's not a flaw in dbt. A model contract is a detail of one tool, while a data contract has to be readable by everyone on both sides of the handover.

---

## From Model Contract to Data Contract: ODCS

The **[Open Data Contract Standard](https://bitol-io.github.io/open-data-contract-standard/v3.2.0/)** (ODCS) describes a data contract as a YAML file. It started as PayPal's internal [data contract template](https://github.com/paypal/data-contract-template), which PayPal open-sourced in 2023. Today it's maintained by [Bitol](https://bitol.io), a project hosted by the Linux Foundation.

That history matters. ODCS isn't a feature of a product. **It's an open standard, and that's what makes it interoperable.** One contract can feed dbt tests, a quality tool, a catalog and generated documentation, instead of each tool keeping its own slightly different definition of the same table.

The [Data Contract CLI](https://docs.datacontract.com/) is an open-source implementation of the standard, and the tool I use throughout. Compared with dbt's model contract:

| | dbt model contract | ODCS data contract |
|---|---|---|
| **What it covers** | Column names, types, constraints | Schema, quality rules, service levels, owner, terms of use |
| **Where it lives** | Inside the dbt project | Standalone file, independent of any tool |
| **Who can read it** | Whoever opens the dbt project | Any person, and any tool that speaks ODCS |
| **Role** | Enforces the shape at build time | Defines the promise |

**dbt enforces, ODCS defines.** You want both, connected.

---

## Anatomy of a Contract

Before going further, here is one complete contract. It describes a small mart table with daily article counts per news source. Every later example is a piece of a file like this one.

```yaml
# 1. Identity: which standard, which contract, which version
apiVersion: v3.2.0
kind: DataContract
id: newsapi-mart-source-daily-counts
name: NewsAPI Source Daily Counts
version: 1.0.0
status: active

# 2. Meaning: what the data is for and what it isn't
description:
  purpose: Daily article counts per source, for reporting.
  limitations: Covers only the AI-topic slice of NewsAPI.

# 3. Location: where the data physically lives
servers:
  - server: duckdb-local
    type: duckdb
    database: ./newsapi_articles.duckdb
    schema: main

# 4. Shape: tables, columns, types
schema:
  - name: mart_newsapi__source_daily_counts
    physicalType: table
    properties:
      - name: source_name
        logicalType: string
        physicalType: VARCHAR
        required: true
      - name: article_date
        logicalType: date
        physicalType: DATE
        required: true
      - name: article_count
        logicalType: integer
        physicalType: BIGINT
        required: true
    # 5. Quality: rules the data must satisfy
    quality:
      - type: sql
        description: Counts must be positive.
        query: SELECT COUNT(*) FROM {model} WHERE article_count <= 0
        mustBe: 0

# 6. Service levels: how fresh, how available
slaProperties:
  - property: freshness
    value: 24
    unit: h

# 7. Ownership: who to ask, who decides
team:
  name: NewsAPI Demo Team
  members:
    - username: demo-owner
      role: Data Product Owner
```

Three things are worth noticing:

- **Section 4 is all a dbt model contract covers.** Everything else, from purpose and quality rules to service levels and ownership, is what the standard adds.
- **Each column has two types.** `logicalType` is the meaning (`date`, `integer`) that any tool understands. `physicalType` is what one specific database stores (`DATE`, `BIGINT`). They can drift apart, and you'll see below that they did.
- **`version` is part of the identity.** Consumers depend on a version, so a breaking change should get a new one.

You can check that a file follows the standard with `datacontract lint`, and check it against the real data with `datacontract test`. This exact file passes both. It uses ODCS v3.2.0, the current release; the contracts in the demo repo still declare v3.1.0, and the CLI accepts either.

---

## Two Payoffs From One File

Here's the core idea of this article in one picture:

![One contract file feeding executed checks on one side and readable metadata on the other](/assets/img/2026/data-contracts/contract-uses.png)

*On the left, tools execute the contract. On the right, people and tools read it. Each half needs the other.*

The left side is where trust comes from. The right side is the metadata repository. Let's look at each.

---

## Payoff 1: Trust

Trust between teams doesn't come from good intentions. It comes from three things a contract makes possible.

### Promises become explicit

A contract turns tribal knowledge into something written down. Take the quality rule from the anatomy above:

```yaml
quality:
  - type: sql
    description: Counts must be positive.
    query: SELECT COUNT(*) FROM {model} WHERE article_count <= 0
    mustBe: 0
```

"Counts must be positive" is a sentence a producer and a consumer agreed on. Before the contract, it lived in someone's head.

### Promises get checked

The CLI can turn those rules into dbt tests (`datacontract dbt sync`), and run the whole contract against the real data (`datacontract test`). The nice part is that `datacontract dbt test` reports the synced tests in the contract's own language, not as cryptic test IDs:

```
╭────────┬───────────────────────────────────────────┬───────────────┬─────────╮
│ Result │ Check                                     │ Field         │ Details │
├────────┼───────────────────────────────────────────┼───────────────┼─────────┤
│ passed │ Counts must be positive.                  │               │         │
│ passed │ Check that field article_count has no     │ article_count │         │
│        │ missing values                            │               │         │
```

From three columns and one rule, the CLI derives 10 checks: each column must exist, have its type and contain no nulls, plus the custom rule. The rule was written once, in the contract, and runs in both dbt and the CLI.

### Changes stop being surprises

Back to the problem from the start: a producer changes something, and consumers find out last. The `published_at` fix was exactly that kind of change. Because contracts are versioned files, the CLI can compare the old and new versions from Git:

```bash
$ datacontract breaking v_old.yaml v_new.yaml
Perspective: consumer
Summary
[ 1 Error ]
╭──────────┬─────────┬──────────────────────────────────────────────────────╮
│ Severity │ Change  │ Field                                                │
├──────────┼─────────┼──────────────────────────────────────────────────────┤
│ ERROR    │ Updated │ schema.stg_newsapi__articles.properties.published_at │
╰──────────┴─────────┴──────────────────────────────────────────────────────╯
```

The command exits with code 1, so in CI it blocks the merge until someone decides. That decision has two parts: tell the consumers, and bump the contract's `version`. It's easy to forget the second one. When I ran this on the demo, both files still said `version: 1.0.0`. The check catches exactly that kind of slip. A dbt model contract never could, because it has no history and doesn't know who its consumers are.

### The catch

All of this only works where something runs the contract. Having a contract file is not the same as enforcing it. The demo has three contracts, and each one ended up with a different level of protection:

![Table of the three ODCS contracts in the demo, what runs for each, and the result](/assets/img/2026/data-contracts/pipeline-gates.png)

*Same standard, three different outcomes. The difference is what sits underneath each contract.*

- **Raw tables:** the contract is linted, so the file is valid, but nothing tests the data against it. One rule says US articles are no older than 60 days. 197 of 295 rows break it, and `dbt build` stays green.
- **Staging model:** the rules exist twice, once in the contract and once as hand-written dbt tests. Two copies drift apart, and one already has.
- **Mart model:** the contract was written first and synced into dbt. One definition, executed everywhere, and all 10 checks pass.

**A wrong rule that runs gets fixed. A wrong rule that doesn't run looks like governance.**

**A contract only protects you where something executes it.**

---

## Payoff 2: A Metadata Repository for Free

The second payoff is easy to overlook, because it isn't about checks at all.

Look at what the demo's staging contract says beyond its schema:

```yaml
description:
  purpose: >
    Single, typed, deduplicated view of NewsAPI articles across supported
    locales. This is the entry point for all downstream analytics.
  limitations: >
    Contains only the AI-topic slice from the ingestion job. [...]
    Do not redistribute the `content` column outside the org — NewsAPI ToS.

slaProperties:
  - property: freshness
    value: 24
    unit: h

team:
  name: NewsAPI Demo Team
  members:
    - username: demo-owner
      role: Data Product Owner
    - username: demo-steward
      role: Data Steward
```

That's exactly the information a new consumer needs and usually has to ask around for. What is this table for? What isn't in it? Am I allowed to share this column? How fresh is it? Who do I ask? Here it sits next to the code, gets reviewed in pull requests, and changes with the data.

Now multiply that by every dataset you hand over. **A folder of contracts in Git is a metadata repository**: versioned, reviewed, and maintained by the people who actually own the data. And because ODCS is a standard, tools can read it. One command turns a folder of contracts into a searchable website:

```bash
$ datacontract catalog --files "contracts/*.odcs.yaml" --output catalog/
```

![Data Contract Catalog generated from the three contracts in the demo repo](/assets/img/2026/data-contracts/catalog.png)

*Generated straight from the demo's contracts. Each card links to a page with the schema, terms of use, team and service levels.*

The same files can be exported to other formats, published to a data catalog, or linked to business definitions: ODCS fields can point to a glossary term through `authoritativeDefinitions`, which makes the contract the place where meaning and data meet.

### Metadata is only as good as the checks behind it

A catalog shows whatever the contracts say, including what's missing or wrong. Two lessons from the demo's catalog apply to any contract:

- **Empty fields stay empty.** One card has no team, because nobody wrote one into that contract. A catalog makes such gaps visible, which is useful, but it can't fill them.
- **Logical and physical types drift.** The staging page lists `published_at` as a `date`. The fix for the timestamp bug updated the `physicalType` and missed the `logicalType`. Nothing in the catalog warns you. `datacontract test` does: it compares the logical type with the real column and fails.

**Metadata nobody checks slowly turns into fiction.** The two payoffs depend on each other.

---

## Getting a Contract: Data-First or Contract-First

There are two ways to arrive at a contract.

**Data-first** is for what you already have. `datacontract import dbt` reads your dbt project's `manifest.json` and produces a draft contract with the schema filled in. Quality rules, service levels and owner are left for you. It's a fast way to make an existing model visible and a good starting point for a conversation with its consumers.

**Contract-first** is for new data products. Producer and consumers agree on the contract before any data exists, and the model is built to fit it. `datacontract dbt sync` then generates the dbt YAML and tests from the contract, so nobody has to write the rules a second time. It won't write your SQL, though. A schema can't tell a tool how to compute `article_count`.

The mart in the demo was built contract-first, and it's the contract with the fewest problems.

---

## Try It Yourself

The whole loop fits in a handful of commands. Install the CLI with the extra for your database, next to the dbt adapter you already use (the `dbt` commands call the `dbt` executable on your path):

```bash
pip install "datacontract-cli[duckdb]" dbt-duckdb
```

Then, for an existing dbt project:

```bash
# 1. Draft a contract from what you have (data-first)
dbt parse
datacontract import dbt --source target/manifest.json --output orders.odcs.yaml

# 2. Fill in servers, purpose, quality rules, SLAs and team, then validate the file
datacontract lint orders.odcs.yaml

# 3. Generate dbt tests from the contract and run them
datacontract dbt sync orders.odcs.yaml --project-dir .
datacontract dbt test

# 4. Test the contract against the real data (uses the servers block)
datacontract test orders.odcs.yaml

# 5. Before merging a change, compare it with the previous version
git show main:orders.odcs.yaml > orders.old.yaml
datacontract breaking orders.old.yaml orders.odcs.yaml
```

Starting from scratch instead? `datacontract init` creates an empty contract to fill in.

---

## Tradeoffs

**Contracts are one more file to maintain.** If one team owns a dbt project and all of its consumers, a dbt model contract plus tests is probably enough. ODCS earns its cost when consumers sit outside the project, use other tools, or need to read the promise without reading your dbt code.

**Someone has to own the contract.** A contract is an agreement, so it needs a person on each side who can change it. Without that, it turns into documentation nobody updates.

**The tooling is young.** The standard is stable, but the CLI changes quickly between releases. Pin the version, and re-check features after upgrading.

### Practical notes

- **Sync rewrites your YAML.** It replaces hand-written descriptions with the contract's wording and normalises types to upper case. That's right if the contract is your source of truth, but it's a diff you have to read.
- **Write rules with `{model}`, not table names.** The `{model}` placeholder becomes a proper dbt `ref()`. Rules that name the table directly still run in a full `dbt build`, but they get skipped when you select just that model.
- **Versions used here:** Data Contract CLI 1.2.9, dbt-core 1.12.0, dbt-duckdb 1.10.1. Older CLI releases (1.1.0) couldn't test DuckDB at all.

---

## Where to Start

If you want to try this on your own project, here's the order I'd follow:

1. **Pick one output port.** A model that another team or tool consumes. In the demo, the staging model calls itself "the entry point for all downstream analytics", and the mart sits on top of it. Both are output ports, and both deserve a contract. Internal models in between don't.
2. **Write the contract with its consumers**, or start data-first with `import` and fill in the rest together. Owner, purpose and limitations matter as much as the schema.
3. **Make every promise executable.** Sync the rules into dbt and run `datacontract test`. If a promise can't be checked, say so in the contract rather than pretending.
4. **Add CI.** Run the tests and `datacontract breaking` on every pull request. Checks that only run when someone remembers to run them stop running. As I argued in my [data governance post](/posts/2025/scaling-data-governance), standards without automated enforcement erode.
5. **Publish the catalog.** Once the contracts are trustworthy, make them easy to find.

For any contract you have today, go through its promises one at a time and ask: **what fails if this stops being true?** If the answer is "nothing", you have documentation. That's useful, but it isn't a contract yet.

---

### Acknowledgments

Credit to [Simon Harrer](https://www.innoq.com/en/staff/dr-simon-harrer/), co-founder of [Entropy Data](https://www.entropy-data.com), whose talks shaped much of this article. [Data Contracts: Creating APIs for Your Data](https://www.youtube.com/watch?v=qYl21EWNL44) is a great short introduction.

The cover image is my own drawing, based on the provider, contract and consumer diagram in Entropy Data's [What is a data contract?](https://www.entropy-data.com/de/lernen/was-ist-ein-data-contract) by Jochen Christ.

Thanks also to the [Bitol](https://bitol.io) community and the maintainers of the [Data Contract CLI](https://docs.datacontract.com/) for keeping both the standard and the tooling open.

---

*The complete demo is available at [github.com/ekoepplin/dbt-data-contract-workflow](https://github.com/ekoepplin/dbt-data-contract-workflow): NewsAPI articles loaded by [dlt](https://dlthub.com) into DuckDB, modelled with dbt, the same stack as my [lightweight data stack post](/posts/2026/dwh-on-a-lake). Clone it, add a NewsAPI key, and follow the README. Its "Break the contract" section shows each layer failing on purpose.*
