---
title: "Scaling Data Teams: The Case for Centralized Data Governance Standards"
pubDatetime: 2026-01-07T09:00:00+01:00
description: "How to maintain consistent data governance when multiple teams independently create and manage their own dbt models using centralized policies with decentralized execution."
heroImage: /assets/img/2025/scaling-data-governance/dbt-mesh.jpg
tags: ["dwh", "data-governance", "dlt", "dbt", "duckdb", "python", "sql"]
---

*In a dbt mesh architecture, multiple teams maintain independent dbt projects that can reference each other's models. Without shared governance standards, each team develops its own conventions—leading to the coordination challenges explored below.*

As organizations scale their data platforms with data mesh architectures, a practical challenge emerges: **how do you maintain consistent data governance when multiple teams independently create and manage their own data models?** Cross-domain data often lacks clear ownership, and upstream changes can break downstream systems without warning. Data mesh architectures benefit from governance structures that match their scale.

The approach described here uses **centralized policies with decentralized execution**. This article covers why decentralized governance becomes difficult at scale, how centralized standards address this, and walks through an implementation using the [`dbt-data-governance-standards`](https://github.com/ekoepplin/dbt-data-governance-standards) package as a reference.

Every organization is different. The goal is to illustrate one approach that you can adapt for your own governance strategy.

*Credit to [Darren Haken's talk at Coalesce](https://www.youtube.com/watch?v=aCiOZcWM1J0) which influenced many of the ideas here.*

---

## The Problem with Decentralized Governance

### When Every Team Invents Their Own Standards

Imagine a typical enterprise data platform with three analytics teams: the Customer Analytics team, the Finance Analytics team, and the Product Analytics team. Each team maintains their own dbt project within a dbt mesh architecture. Without coordination, here's what their model metadata might look like:

```yaml
# Team A (Customer Analytics) - uses "owner" with names
models:
  - name: dim_customers
    description: "Customer dimension table"
    meta:
      owner: "John Smith"
      classification: "sensitive"
      pii: "yes"

# Team B (Finance Analytics) - uses "data_owner" with emails
models:
  - name: fct_revenue
    description: "Revenue fact table"
    meta:
      data_owner: "jane.doe@company.com"
      data_classification: "CONFIDENTIAL"
      contains_pii: false

# Team C (Product Analytics) - minimal or no metadata
models:
  - name: fct_user_events
    description: "User events fact table"
    # No governance metadata at all
```

At a glance, this might seem fine—each team is documenting their models. But look closer:

- **Inconsistent field names**: `owner` vs `data_owner` vs nothing
- **Inconsistent values**: `"sensitive"` vs `"CONFIDENTIAL"`, `"yes"` vs `false`
- **Missing fields**: Team C has no governance metadata whatsoever
- **No schema enforcement**: Any value can be put in any field

### The Consequences at Scale

These inconsistencies compound as the organization grows. Consider a common scenario:

**A data scientist discovers an issue in `fct_revenue`. The numbers don't match the finance report. Who owns this model?**

- Team A's model says `owner: "John"` — but John left the company 6 months ago
- Team B's model says `data_owner: "finance-team@company.com"` — but that distribution list may be outdated
- Team C's model has no ownership metadata at all

**Result**: Messages to various channels, emails that may not reach anyone, time spent on discovery rather than resolution.

This scenario repeats across every governance dimension:

**Compliance audits become manual discovery exercises.** When Legal asks "show me all models containing PII and their retention policies," someone must review every YAML file, interpret each team's conventions, and manually compile results.

**Cross-team collaboration breaks down.** Without shared vocabulary, teams can't answer basic questions: "Is this model stable? Can we depend on it? Will the schema change without warning?"

**Data catalogs show incomplete information.** Tools like Atlan, DataHub, or Monte Carlo expect consistent schemas. When every team uses different conventions, these tools require custom mapping logic for each team.

**Standards drift over time.** Even if teams start with similar conventions, without enforcement, they diverge. New team members bring their own preferences. Six months later, consistency is difficult to recover.

---

## The Centralized Standards Pattern

### Define Once, Distribute Everywhere, Enforce Automatically

Rather than relying on documentation alone, this approach uses tooling:

1. **Define the standard** in a central, versioned package
2. **Distribute the standard** as a dbt package that teams install
3. **Provide tools** (macros) that make compliance the path of least resistance
4. **Enforce automatically** in CI/CD so non-compliant models cannot merge

The central package contains everything needed for consistent governance:

- **Schema definitions** specifying exactly which fields are required and their types
- **Retention policies** codifying compliance requirements (GDPR, CCPA, HIPAA)
- **Validation rules** that check models against the schema and policies
- **dbt macros** that generate compliant metadata with minimal effort

### The Schema: Your Single Source of Truth

At the core of centralized governance is a well-defined metadata schema. Here's how it's defined in Python:

```python
# dbt_data_governance_standards/schemas/metadata_schema.py

class DataClassification(str, Enum):
    """Data classification levels."""
    PUBLIC = "PUBLIC"
    INTERNAL = "INTERNAL"
    CONFIDENTIAL = "CONFIDENTIAL"
    RESTRICTED = "RESTRICTED"


class DataLifecycle(str, Enum):
    """Data lifecycle stages."""
    DEVELOPMENT = "DEVELOPMENT"
    STAGING = "STAGING"
    PRODUCTION = "PRODUCTION"
    DEPRECATED = "DEPRECATED"


class StandardMetadata:
    """Standard metadata structure for dbt models."""

    REQUIRED_FIELDS = {
        "data_governance.data_owner": str,
        "data_governance.data_steward": str,
        "data_governance.data_classification": str,
        "data_governance.data_lifecycle": str,
    }

    OPTIONAL_FIELDS = {
        "data_governance.has_pii": bool,
        "data_governance.pii_retention_days": int,
        "data_governance.can_be_referenced": bool,
        "data_governance.update_schedule": str,
        "data_governance.sla": str,
    }
```

This schema is explicit:

- **Four required fields** that every model must have: data owner, data steward, classification, and lifecycle stage
- **Five optional fields** for additional governance metadata like PII flags and retention periods
- **Enums for controlled vocabularies** ensuring `data_classification` can only be one of four valid values

### The Macro: Making Compliance Easy

Knowing the schema exists is one thing. Getting engineers to use it correctly is another. That's where the dbt macro comes in:

```sql
-- macros/governance/get_standard_metadata.sql

{% macro get_standard_metadata(
    data_owner,
    data_steward,
    data_classification,
    data_lifecycle,
    has_pii=false,
    pii_retention_days=none,
    can_be_referenced=true,
    update_schedule=none,
    sla=none
) %}
  {% set metadata = {
    "data_governance": {
      "data_owner": data_owner,
      "data_steward": data_steward,
      "data_classification": data_classification,
      "data_lifecycle": data_lifecycle,
      "has_pii": has_pii,
      "can_be_referenced": can_be_referenced
    }
  } %}

  {% if pii_retention_days is not none %}
    {% set _ = metadata["data_governance"].update({"pii_retention_days": pii_retention_days}) %}
  {% endif %}

  {% if update_schedule is not none %}
    {% set _ = metadata["data_governance"].update({"update_schedule": update_schedule}) %}
  {% endif %}

  {% if sla is not none %}
    {% set _ = metadata["data_governance"].update({"sla": sla}) %}
  {% endif %}

  {{ return(metadata) }}
{% endmacro %}
```

The macro is optional but provides several benefits:

1. **Named parameters** make it clear what values are needed
2. **Default values** for optional fields reduce boilerplate
3. **Consistent structure** is guaranteed—no typos in field names
4. **IDE autocomplete** helps engineers discover available options

Alternatively, teams can write the same structure directly in YAML without using the macro—the validator checks the structure regardless of how it was authored.

---

## Dual Installation: Macros for Authors, Validation for CI

The `dbt-data-data-governance-standards` package illustrates two complementary purposes through two installation methods:

### 1. dbt Package: For Model Authors

Teams add the package to their `packages.yml`:

```yaml
# packages.yml
packages:
  - git: "https://github.com/ekoepplin/dbt-data-governance-standards.git"
    revision: main
```

After running `dbt deps`, teams can add governance metadata to their models. There are two equivalent approaches:

**Option A: Using the macro** (provides autocomplete and compile-time validation)

```yaml
# models/marts/schema.yml
version: 2

models:
  - name: dim_customers
    description: "Customer dimension table with profile and contact information"
    meta: {{ dbt_data_governance_standards.get_standard_metadata(
      data_owner="customer-analytics@company.com",
      data_steward="data-governance@company.com",
      data_classification="CONFIDENTIAL",
      data_lifecycle="PRODUCTION",
      has_pii=true,
      pii_retention_days=365
    ) }}
```

**Option B: Writing YAML directly** (no macro needed)

```yaml
# models/marts/schema.yml
version: 2

models:
  - name: dim_customers
    description: "Customer dimension table with profile and contact information"
    meta:
      data_governance:
        data_owner: "customer-analytics@company.com"
        data_steward: "data-governance@company.com"
        data_classification: "CONFIDENTIAL"
        data_lifecycle: "PRODUCTION"
        has_pii: true
        pii_retention_days: 365
```

Both approaches produce the same structure. The macro provides autocomplete and catches missing required fields at compile time, while direct YAML is simpler for teams that prefer not to use the macro. Choose whichever fits your workflow.

**Column-level metadata** is always written as plain YAML:

```yaml
    columns:
      - name: customer_id
        description: "Unique customer identifier (surrogate key)"
      - name: email
        description: "Customer email address"
        meta:
          data_governance:
            is_pii: true
            anonymization_method: "hash"
      - name: full_name
        description: "Customer full name"
        meta:
          data_governance:
            is_pii: true
            anonymization_method: "redact"
      - name: created_at
        description: "Account creation timestamp"
        meta:
          data_governance:
            retention_date_field: true
```

The macro approach makes compliance the path of least resistance—engineers get IDE autocomplete and don't need to memorize the schema. But teams who prefer plain YAML can use it directly; the validator checks the structure regardless of how it was authored.

### 2. Python Package: For CI/CD Validation

The same package can be installed as a Python package for running validation:

```bash
# Install using pip
pip install git+https://github.com/ekoepplin/dbt-data-governance-standards.git@main

# Or using uv (faster)
uv pip install git+https://github.com/ekoepplin/dbt-data-governance-standards.git@main
```

Once installed, validate any dbt project:

```bash
dbt-governance-validate --dbt-project /path/to/your/dbt/project
```

What this approach means:

- **Authors** get helpful macros that make writing compliant metadata easy
- **CI/CD** gets a validation tool that ensures compliance is mandatory

---

## Validation Rules: Governance as Code

Validation rules are the heart of automated enforcement. The validator parses your dbt model YAML files (e.g., `models/schema.yml`), extracts the `meta` block from each model, and checks it against the governance rules.

Rules are defined as Python functions and configured via YAML for flexibility.

### Rule Configuration

Rules are configured in `rules_config.yml`, allowing teams to enable, disable, or adjust severity without modifying code:

```yaml
rules:
  - name: "PII models without retention_days"
    func: "detect_pii_without_retention_days"
    severity: "error"
    enabled: true
  # ... additional rules for metadata, classification, etc.
```

Each rule maps to a validation function. Teams can set `severity: "warning"` during migration, then tighten to `"error"` once compliant.

### Rule Implementation

Each rule receives the parsed models from your YAML files and follows a simple pattern: iterate models, check conditions, collect errors.

```python
def detect_pii_without_retention_days(models, validator):
    """
    models: list of model dictionaries parsed from your schema.yml files
    Each model dict contains 'name', 'meta', 'columns', etc.
    """
    errors = []
    for model in models:
        if model_has_pii(model) and not has_retention_days(model):
            errors.append(f"Model '{model['name']}': missing retention_days")
    return len(errors) == 0, errors
```

The pattern is the same for any rule—check a condition, report violations. This consistency makes it easy to add new rules as governance requirements evolve.

### Example: Complete Validation Run

Here's what a validation run looks like against a project with mixed compliance:

```bash
$ dbt-governance-validate --dbt-project ./analytics

Scanning 47 models in ./analytics/models...

✓ dim_products: all checks passed
✓ dim_dates: all checks passed
✗ dim_customers: 2 errors
    - has_pii is True but pii_retention_days is not specified
    - Column 'email' missing anonymization_method
✓ fct_orders: all checks passed
✗ fct_user_sessions: 3 errors
    - Missing required field: data_governance.data_owner
    - Missing required field: data_governance.data_classification
    - Missing required field: data_governance.data_lifecycle
✓ stg_stripe__payments: all checks passed
...

Summary:
  Models scanned: 47
  Passed: 42
  Failed: 5
  Errors: 11

Failed models:
  - dim_customers (2 errors)
  - fct_user_sessions (3 errors)
  - int_customer_orders (2 errors)
  - mart_revenue_daily (3 errors)
  - mart_churn_analysis (1 error)
```

Each error is specific and actionable. The engineer knows exactly which model, which field, and what's missing.

---

## PII and Compliance: Policy-Driven Validation

Handling PII correctly is a practical requirement under regulations like GDPR, CCPA, and HIPAA. These impose specific requirements on how personal data must be managed, retained, and deleted. Regulations like GDPR, CCPA, and HIPAA impose specific requirements on how personal data must be managed, retained, and eventually deleted.

### Defining Retention Policies

Policies are defined in `policies/retention_policies.yml`, separate from validation rules. This makes them easy to update as regulations change:

```yaml
# policies/retention_policies.yml
retention_policies:
  pii_retention:
    minimum_days: 90    # Can't delete too quickly
    maximum_days: 2555  # Must delete eventually (GDPR)
  deletion:
    require_anonymization_method: true
```

When policy requirements change, you update this file. The next CI run checks all models against the new values.

For example, if legal requires reducing the maximum retention from 7 years to 3 years:

```yaml
# Before
pii_retention:
  maximum_days: 2555  # ~7 years

# After
pii_retention:
  maximum_days: 1095  # ~3 years
```

The next CI run across all team projects will flag any model with `pii_retention_days > 1095`.

### Validating Against Policies

Validation rules load the `retention_policies.yml` file and check each model's metadata against those policy values. The pattern is straightforward:

```python
def detect_invalid_retention_periods(models, validator):
    # Load policies from retention_policies.yml
    policies = load_policies()  # reads policies/retention_policies.yml
    min_days = policies["pii_retention"]["minimum_days"]
    max_days = policies["pii_retention"]["maximum_days"]

    for model in models:
        if model_has_pii(model):
            if retention_days < min_days or retention_days > max_days:
                errors.append(f"Model '{model['name']}': retention out of range")
```

The key insight: policies are data, not code. When regulations change, update `retention_policies.yml`—no code deployment needed.

### Column-Level PII Metadata

Beyond model-level metadata, PII columns specify how they should be handled during deletion:

```yaml
columns:
  - name: email
    meta:
      data_governance:
        is_pii: true
        anonymization_method: "hash"  # or "redact", "generalize"
```

This column-level metadata enables automated deletion workflows. Here's how a GDPR deletion request can be processed:

```python
# Example: Generate deletion SQL from governance metadata
def generate_deletion_sql(model_name: str, customer_id: str) -> str:
    """Generate anonymization SQL based on column metadata."""
    model = load_model_metadata(model_name)
    updates = []

    for column in model["columns"]:
        meta = column.get("meta", {}).get("data_governance", {})
        if meta.get("is_pii"):
            method = meta.get("anonymization_method", "redact")
            if method == "hash":
                updates.append(f"{column['name']} = SHA256({column['name']})")
            elif method == "redact":
                updates.append(f"{column['name']} = '[REDACTED]'")
            elif method == "generalize":
                updates.append(f"{column['name']} = NULL")

    return f"""
    UPDATE {model_name}
    SET {', '.join(updates)}
    WHERE customer_id = '{customer_id}'
    """

# For dim_customers with email (hash) and full_name (redact):
# UPDATE dim_customers
# SET email = SHA256(email), full_name = '[REDACTED]'
# WHERE customer_id = 'cust_12345'
```

The deletion logic derives directly from the metadata. No manual mapping required.

---

## CI/CD Integration: The Enforcement Layer

Having standards and macros is not enough. Compliance must be enforced automatically, or it will erode over time.

### Why CI Matters for Governance at Scale

Documentation alone is insufficient for consistent enforcement. CI/CD integration provides automated validation.

When governance validation runs in CI/CD:

- **Non-compliant models cannot merge.** The gate is automatic.
- **Feedback is immediate.** Engineers see what needs fixing before code review.
- **Standards evolve together.** Update the central package, and every team's next CI run validates against the new rules.
- **Audits are straightforward.** If it passed CI, it meets the defined standards.

### What Enforcement Looks Like

When a model doesn't meet governance standards, CI fails with clear, actionable messages:

```
❌ Model 'dim_customers': has_pii is True but pii_retention_days is not specified
❌ Column 'email': missing anonymization_method
```

The engineer knows exactly what to fix. No ambiguity, no interpretation.

### Comparison: Manual vs. Automated Enforcement

| Manual Enforcement                   | Automated Enforcement                         |
| ------------------------------------ | --------------------------------------------- |
| "Please follow the governance guide" | "PR blocked until compliant"                  |
| Standards drift over months          | Standards checked on every commit             |
| Audit requires manual file review    | Audit relies on CI validation history         |

The implementation—GitHub Actions, pre-commit hooks, choice of validator—is straightforward once automated enforcement is in place.

Here's a complete GitHub Actions workflow example:

```yaml
# .github/workflows/governance-check.yml
name: Governance Validation

on:
  pull_request:
    paths:
      - 'models/**/*.yml'
      - 'models/**/*.sql'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - name: Install validator
        run: |
          pip install git+https://github.com/ekoepplin/dbt-data-governance-standards.git@main

      - name: Validate governance metadata
        run: |
          dbt-governance-validate --dbt-project . --output-format github

      - name: Generate compliance report
        if: always()
        run: |
          dbt-governance-validate --dbt-project . --output-format markdown > compliance-report.md

      - name: Upload report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: compliance-report
          path: compliance-report.md
```

This workflow runs on every PR that modifies model files, blocks non-compliant changes, and generates an audit-ready compliance report.

---

## Benefits Summary: Why Centralize?

| Aspect                  | Decentralized Approach                | Centralized Approach                    |
| ----------------------- | ------------------------------------- | --------------------------------------- |
| **Schema**              | Each team invents their own           | Single schema, many consumers           |
| **Compliance**          | Manual, audit-driven                  | Automated, continuous                   |
| **Standards Evolution** | Drift over time, inconsistent updates | Evolve in one place, version-controlled |
| **Enforcement**         | Hope and documentation                | CI blocks non-compliant models          |
| **PII Handling**        | Varies by team interpretation         | Uniform policies enforced everywhere    |
| **Onboarding**          | Learn each team's conventions         | Learn one standard, use everywhere      |
| **Tooling Integration** | Custom mappings per team              | Consistent metadata for all tools       |
| **Audit Readiness**     | Manual discovery and compilation      | Automated reports from metadata         |

The centralized approach doesn't remove team autonomy—teams still own their models and make decisions about data classification and ownership. What it does remove is the burden of inventing and maintaining governance conventions. That responsibility moves to a central team that can:

- Keep up with regulatory changes
- Evolve the schema as needs change
- Ensure all teams benefit from improvements
- Provide a single point of truth for compliance

---

## Conclusion

Data governance at scale requires more than good intentions and documentation. It requires:

1. **A single source of truth** for what compliant metadata looks like
2. **Tools that make compliance easy** for the engineers writing models
3. **Automated enforcement** that makes non-compliance impossible to merge

The `dbt-data-governance-standards` package provides one reference implementation. By centralizing the definition of governance standards while decentralizing their application, organizations can scale their data mesh architectures while maintaining consistency.

Practical outcomes of this approach:

- Compliance audits can query metadata directly rather than reviewing files manually
- New team members learn one standard that applies across all projects
- GDPR deletion requests can be automated against documented PII fields
- Data catalogs receive consistent metadata across all teams

Start with one team. Validate the approach. Expand from there.