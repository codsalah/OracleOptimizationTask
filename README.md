# SQL Tuning Project
### Oracle Database Performance Optimization

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Before Tuning](#2-before-tuning)
   - [The Original Query](#21-the-original-query)
   - [Performance Metrics Baseline](#22-performance-metrics-baseline)
   - [Execution Plan](#23-execution-plan)
   - [What's Wrong With It](#24-whats-wrong-with-it)
3. [Optimization Steps](#3-optimization-steps)
   - [The Optimized Query](#31-the-optimized-query)
   - [What Changed and Why](#32-what-changed-and-why)
4. [After Tuning](#4-after-tuning)
   - [Performance Metrics (Post-Optimization)](#41-performance-metrics-post-optimization)
   - [New Execution Plan](#42-new-execution-plan)
   - [What Actually Improved](#43-what-actually-improved)

---

## 1. Problem Statement

Management needs a report that answers a straightforward business question: **which product categories are selling the most in each city?**

Specifically, they want to see:

- The **top 5 product categories per city**, ranked by total sales amount
- Only sales that were **completed** (cancelled orders are excluded)
- Only sales that happened **during the year 2025**
- Along with two extra numbers for context: each category's **rank within its city**, and the **average total sales across all categories in the same customer segment**

To produce this report, we're working with three tables:

| Table | What it holds | Size |
|---|---|---|
| `customers_prj` | Customer info — name, city, and segment (Retail, Corporate, Small Biz) | 500,000 rows |
| `products_prj` | Product info — name and category (Electronics, Food, Clothes, etc.) | 50,000 rows |
| `sales_prj` | Every sale — which customer bought which product, how much, when, and whether it was completed or cancelled | 50,000,000 rows |

A query was written to pull this report and it **produces the correct results** — but it runs painfully slow. The goal of this project is to figure out exactly *why* it's slow, fix it, and prove that the fix actually worked.

---

## 2. Before Tuning

### 2.1 The Original Query

This is the query as it was originally written — correct results, poor performance.

```sql
SELECT *
FROM (
    SELECT c.city,
           p.category,
           c.segment,
           SUM(s.amount) AS total_sales,
           RANK() OVER (
               PARTITION BY c.city
               ORDER BY SUM(s.amount) DESC
           ) AS sales_rank,
           AVG(SUM(s.amount)) OVER (
               PARTITION BY c.segment
           ) AS avg_segment_sales
    FROM customers_prj c,
         sales_prj s,
         products_prj p
    WHERE c.customer_id = s.customer_id
      AND s.product_id  = p.product_id
      AND TO_CHAR(s.sale_date, 'YYYY') = '2025'
      AND s.status <> 'CANCELLED'
    GROUP BY c.city, p.category, c.segment
)
WHERE sales_rank <= 5;
```

---

### 2.2 Performance Metrics Baseline

#### What Each Metric Means

| Metric | What it tells you |
|---|---|
| **Elapsed Time (seconds)** | Total wall-clock time from start to finish |
| **CPU Time (seconds)** | How much of that time was pure processing work |
| **Disk Reads** | How many times Oracle had to go to disk to fetch data — high values mean the data wasn't in memory and Oracle had to do expensive physical I/O |
| **Buffer Gets (Logical Reads)** | How many data blocks Oracle read from memory — this is your main I/O cost indicator even when no disk is involved |
| **Rows Processed** | How many rows Oracle handled in total across all operations in the query |
| **Sorts** | How many sort operations were triggered — sorts are expensive, especially when they run out of memory and spill to temp disk |
| **Optimizer Cost** | Oracle's internal estimate of how expensive it thought the query would be before running it |
| **Executions** | How many times this exact query has run — used to calculate honest per-run averages |

#### Recorded Values

> Run the queries below first, then fill in the values here.

| Metric | Recorded Value |
|---|---|
| **Elapsed Time (seconds)** | `___ sec` |
| **CPU Time (seconds)** | `___ sec` |
| **Disk Reads** | `___` |
| **Buffer Gets (Logical Reads)** | `___` |
| **Rows Processed** | `___` |
| **Sorts** | `___` |
| **Optimizer Cost** | `___` |
| **Executions** | `___` |

#### Queries Used to Capture These Values

**Step 1 — Run the original query with the stats-gathering hint:**

```sql
SELECT /*+ gather_plan_statistics */
*
FROM (
    SELECT c.city,
           p.category,
           c.segment,
           SUM(s.amount) AS total_sales,
           RANK() OVER (PARTITION BY c.city ORDER BY SUM(s.amount) DESC) AS sales_rank,
           AVG(SUM(s.amount)) OVER (PARTITION BY c.segment)              AS avg_segment_sales
    FROM customers_prj c,
         sales_prj     s,
         products_prj  p
    WHERE c.customer_id = s.customer_id
      AND s.product_id  = p.product_id
      AND TO_CHAR(s.sale_date, 'YYYY') = '2025'
      AND s.status <> 'CANCELLED'
    GROUP BY c.city, p.category, c.segment
)
WHERE sales_rank <= 5;
```

**Step 2 — Pull the metrics from `v$sql`:**

```sql
SELECT *
FROM (
    SELECT sql_id,
           executions,
           ROUND(elapsed_time / 1e6, 2)               AS elapsed_sec,
           ROUND(cpu_time     / 1e6, 2)               AS cpu_sec,
           disk_reads,
           buffer_gets,
           rows_processed,
           sorts,
           optimizer_cost,
           ROUND(disk_reads  / NULLIF(executions, 0)) AS disk_reads_per_exec,
           ROUND(buffer_gets / NULLIF(executions, 0)) AS buffer_gets_per_exec
    FROM   v$sql
    WHERE  sql_text LIKE '%sales_prj%'
      AND  sql_text LIKE '%sales_rank%'
      AND  sql_text NOT LIKE '%v$sql%'
    ORDER  BY last_active_time DESC
)
WHERE ROWNUM <= 5;
```

**Step 3 — Check which table is doing the most I/O:**

```sql
SELECT *
FROM (
    SELECT object_name,
           object_type,
           SUM(CASE WHEN statistic_name = 'logical reads'  THEN value ELSE 0 END) AS logical_reads,
           SUM(CASE WHEN statistic_name = 'physical reads' THEN value ELSE 0 END) AS physical_reads,
           SUM(CASE WHEN statistic_name = 'segment scans'  THEN value ELSE 0 END) AS segment_scans
    FROM   v$segment_statistics
    WHERE  owner       NOT IN ('SYS', 'SYSTEM')
      AND  object_type IN ('TABLE', 'INDEX')
    GROUP  BY owner, object_name, object_type
    ORDER  BY physical_reads DESC
)
WHERE ROWNUM <= 10;
```

---

### 2.3 Execution Plan

Two methods are provided below. Use **Method A** for a quick estimated look before running the full query. Use **Method B** to get the actual runtime plan — this is the one your recorded values should come from.

---

#### Method A — Estimated Plan (query does not execute)

> This shows what Oracle *thinks* it will do based on current statistics. No rows are actually processed. Useful as a first look, but the numbers are estimates only.

```sql
EXPLAIN PLAN FOR
SELECT *
FROM (
    SELECT c.city,
           p.category,
           c.segment,
           SUM(s.amount) AS total_sales,
           RANK() OVER (PARTITION BY c.city ORDER BY SUM(s.amount) DESC) AS sales_rank,
           AVG(SUM(s.amount)) OVER (PARTITION BY c.segment)              AS avg_segment_sales
    FROM customers_prj c,
         sales_prj     s,
         products_prj  p
    WHERE c.customer_id = s.customer_id
      AND s.product_id  = p.product_id
      AND TO_CHAR(s.sale_date, 'YYYY') = '2025'
      AND s.status <> 'CANCELLED'
    GROUP BY c.city, p.category, c.segment
)
WHERE sales_rank <= 5;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);
```

**Paste your estimated plan output below:**

```
[ PASTE DBMS_XPLAN.DISPLAY OUTPUT HERE ]
```

---

#### Method B — Actual Runtime Plan (query executes fully)

> This shows what Oracle *actually did* — real row counts, real time per operation, and real buffer gets at every step.

```sql
SELECT /*+ gather_plan_statistics */
*
FROM (
    SELECT c.city,
           p.category,
           c.segment,
           SUM(s.amount) AS total_sales,
           RANK() OVER (PARTITION BY c.city ORDER BY SUM(s.amount) DESC) AS sales_rank,
           AVG(SUM(s.amount)) OVER (PARTITION BY c.segment)              AS avg_segment_sales
    FROM customers_prj c,
         sales_prj     s,
         products_prj  p
    WHERE c.customer_id = s.customer_id
      AND s.product_id  = p.product_id
      AND TO_CHAR(s.sale_date, 'YYYY') = '2025'
      AND s.status <> 'CANCELLED'
    GROUP BY c.city, p.category, c.segment
)
WHERE sales_rank <= 5;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));
```

**Paste your actual runtime plan output below:**

```
[ PASTE DBMS_XPLAN.DISPLAY_CURSOR OUTPUT HERE ]
```

---

### 2.4 What's Wrong With It

> Fill in each problem after analyzing the execution plan above.

| # | Problem | Where it shows up in the plan | Impact |
|---|---|---|---|
| 1 | `[ placeholder ]` | `[ placeholder ]` | `[ placeholder ]` |
| 2 | `[ placeholder ]` | `[ placeholder ]` | `[ placeholder ]` |
| 3 | `[ placeholder ]` | `[ placeholder ]` | `[ placeholder ]` |
| 4 | `[ placeholder ]` | `[ placeholder ]` | `[ placeholder ]` |
| 5 | `[ placeholder ]` | `[ placeholder ]` | `[ placeholder ]` |

---

## 3. Optimization Steps

### 3.1 The Optimized Query

> Replace this placeholder with the final rewritten query after all changes are applied.

```sql
[ PASTE OPTIMIZED QUERY HERE ]
```

---

### 3.2 What Changed and Why

Each change below targets a specific root cause identified in Section 2.4.

---

#### Change 1 — `[ Short title of the change ]`

**What was changed:**
> `[ placeholder ]`

**Why:**
> `[ placeholder ]`

---

#### Change 2 — `[ Short title of the change ]`

**What was changed:**
> `[ placeholder ]`

**Why:**
> `[ placeholder ]`

---

#### Change 3 — `[ Short title of the change ]`

**What was changed:**
> `[ placeholder ]`

**Why:**
> `[ placeholder ]`

---

#### Change 4 — `[ Short title of the change ]`

**What was changed:**
> `[ placeholder ]`

**Why:**
> `[ placeholder ]`

---

#### Change 5 — `[ Short title of the change ]`

**What was changed:**
> `[ placeholder ]`

**Why:**
> `[ placeholder ]`

---

#### Change 6 — `[ Short title of the change ]`

**What was changed:**
> `[ placeholder ]`

**Why:**
> `[ placeholder ]`

---

## 4. After Tuning

### 4.1 Performance Metrics (Post-Optimization)

#### Recorded Values

> Run the same metric queries from Section 2.2, this time against the optimized query. Fill in both columns then calculate the improvement.

| Metric | Before | After | Improvement |
|---|---|---|---|
| **Elapsed Time (seconds)** | `___` | `___` | `___ × faster` |
| **CPU Time (seconds)** | `___` | `___` | `↓ ___` |
| **Disk Reads** | `___` | `___` | `↓ ___` |
| **Buffer Gets (Logical Reads)** | `___` | `___` | `↓ ___` |
| **Rows Processed** | `___` | `___` | `↓ ___` |
| **Sorts** | `___` | `___` | `↓ ___` |
| **Optimizer Cost** | `___` | `___` | `↓ ___` |

---

### 4.2 New Execution Plan

Two methods are provided below, same as in Section 2.3. Capture both and compare against the original plan output.

---

#### Method A — Estimated Plan (query does not execute)

> Same approach as before — gives you Oracle's cost estimate for the optimized query before it runs.

```sql
EXPLAIN PLAN FOR
[ PASTE OPTIMIZED QUERY HERE ];

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);
```

**Paste your estimated plan output below:**

```
[ PASTE DBMS_XPLAN.DISPLAY OUTPUT HERE ]
```

---

#### Method B — Actual Runtime Plan (query executes fully)

> Run the optimized query with the hint and capture the actual plan. This is what you compare directly against the original Method B output from Section 2.3.

```sql
SELECT /*+ gather_plan_statistics */
[ PASTE OPTIMIZED QUERY BODY HERE ];

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));
```

**Paste your actual runtime plan output below:**

```
[ PASTE DBMS_XPLAN.DISPLAY_CURSOR OUTPUT HERE ]
```

---

### 4.3 What Actually Improved

> Compare the two plans side by side. Fill in what changed for each point.

| What we looked at | Before | After |
|---|---|---|
| **Access path on `sales_prj`** | `[ e.g. TABLE ACCESS FULL ]` | `[ e.g. INDEX RANGE SCAN ]` |
| **Join method** | `[ placeholder ]` | `[ placeholder ]` |
| **Estimated vs actual rows (cardinality)** | `[ placeholder ]` | `[ placeholder ]` |
| **Number of sort operations** | `[ placeholder ]` | `[ placeholder ]` |
| **Temp tablespace usage (sort spill)** | `[ placeholder ]` | `[ placeholder ]` |
| **Overall plan cost** | `[ placeholder ]` | `[ placeholder ]` |

---

*Project submitted as part of the SQL Tuning course. All optimizations were tested against the same dataset and Oracle environment.*