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
| **Elapsed Time (seconds)** | `174.45 sec` |
| **CPU Time (seconds)** | `60.53 sec` |
| **Disk Reads** | `425585` |
| **Buffer Gets (Logical Reads)** | `335876` |
| **Rows Processed** | `20` |
| **Sorts** | `3` |
| **Optimizer Cost** | `104364` |
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
Plan hash value: 354816077

--------------------------------------------------------------------------------------------------
| Id  | Operation                | Name          | Rows  | Bytes |TempSpc| Cost (%CPU)| Time     |
--------------------------------------------------------------------------------------------------
|   0 | SELECT STATEMENT         |               |    31 |  2945 |       |   104K  (2)| 00:20:53 |
|*  1 |  VIEW                    |               |    31 |  2945 |       |   104K  (2)| 00:20:53 |
|*  2 |   WINDOW SORT PUSHED RANK|               |    31 |  2139 |       |   104K  (2)| 00:20:53 |
|   3 |    WINDOW BUFFER         |               |    31 |  2139 |       |   104K  (2)| 00:20:53 |
|   4 |     SORT GROUP BY        |               |    31 |  2139 |       |   104K  (2)| 00:20:53 |
|*  5 |      HASH JOIN           |               |   447K|    29M|    24M|   104K  (2)| 00:20:52 |
|*  6 |       HASH JOIN          |               |   447K|    19M|    11M| 86449   (3)| 00:17:18 |
|   7 |        TABLE ACCESS FULL | PRODUCTS_PRJ  |   500K|  6347K|       |   619   (1)| 00:00:08 |
|*  8 |        TABLE ACCESS FULL | SALES_PRJ     |   447K|    14M|       | 84278   (3)| 00:16:52 |
|   9 |       TABLE ACCESS FULL  | CUSTOMERS_PRJ |  5000K|   109M|       |  8319   (1)| 00:01:40 |
--------------------------------------------------------------------------------------------------
```

Predicate Information (identified by operation id):
---------------------------------------------------

1 - filter("SALES_RANK"<=5)
2 - filter(RANK() OVER ( PARTITION BY "C"."CITY" ORDER BY SUM("S"."AMOUNT") DESC )<=5)
5 - access("C"."CUSTOMER_ID"="S"."CUSTOMER_ID")
6 - access("S"."PRODUCT_ID"="P"."PRODUCT_ID")
8 - filter("S"."STATUS"<>'CANCELLED' AND TO_CHAR(INTERNAL_FUNCTION("S"."SALE_DATE"),'YY
YY')='2025')```

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
SQL_ID  7n6phu9ra4rkb, child number 1
-------------------------------------
SELECT /*+ gather_plan_statistics */ * FROM (     SELECT c.city,
p.category,            c.segment,            SUM(s.amount) AS
total_sales,            RANK() OVER (PARTITION BY c.city ORDER BY
SUM(s.amount) DESC) AS sales_rank,            AVG(SUM(s.amount)) OVER
(PARTITION BY c.segment)              AS avg_segment_sales     FROM
customers_prj c,          sales_prj     s,          products_prj  p
WHERE c.customer_id = s.customer_id       AND s.product_id  =
p.product_id       AND TO_CHAR(s.sale_date, 'YYYY') = '2025'       AND
s.status <> 'CANCELLED'     GROUP BY c.city, p.category, c.segment )
WHERE sales_rank <= 5

Plan hash value: 4200398583

-----------------------------------------------------------------------------------------------------------------------------------------------------------
| Id  | Operation                | Name          | Starts | E-Rows | A-Rows |   A-Time   | Buffers | Reads  | Writes |  OMem |  1Mem | Used-Mem | Used-Tmp|
-----------------------------------------------------------------------------------------------------------------------------------------------------------
|   0 | SELECT STATEMENT         |               |      1 |        |     20 |00:01:38.85 |     335K|    407K|  74679 |       |       |          |         |
|*  1 |  VIEW                    |               |      1 |     31 |     20 |00:01:38.85 |     335K|    407K|  74679 |       |       |          |         |
|*  2 |   WINDOW SORT PUSHED RANK|               |      1 |     31 |     24 |00:01:38.85 |     335K|    407K|  74679 |  6144 |  6144 | 6144  (0)|         |
|   3 |    WINDOW BUFFER         |               |      1 |     31 |     54 |00:01:38.85 |     335K|    407K|  74679 |  4096 |  4096 | 4096  (0)|         |
|   4 |     SORT GROUP BY        |               |      1 |     31 |     54 |00:01:38.85 |     335K|    407K|  74679 |  4096 |  4096 | 4096  (0)|         |
|*  5 |      HASH JOIN           |               |      1 |     22M|     22M|00:01:17.99 |     335K|    407K|  74679 |   185M|  8752K|   73M (1)|     605K|
|   6 |       TABLE ACCESS FULL  | CUSTOMERS_PRJ |      1 |   5000K|   5000K|00:00:04.99 |   29775 |  29765 |      0 |       |       |          |         |
|*  7 |       HASH JOIN          |               |      1 |     22M|     22M|00:00:39.65 |     306K|    303K|     62 |    14M|  2367K|   20M (0)|         |
|   8 |        TABLE ACCESS FULL | PRODUCTS_PRJ  |      1 |    500K|    500K|00:00:00.10 |    2265 |      0 |      0 |       |       |          |         |
|*  9 |        TABLE ACCESS FULL | SALES_PRJ     |      1 |     22M|     22M|00:00:22.74 |     303K|    303K|      0 |       |       |          |         |
-----------------------------------------------------------------------------------------------------------------------------------------------------------

Predicate Information (identified by operation id):
---------------------------------------------------

1 - filter("SALES_RANK"<=5)
2 - filter(RANK() OVER ( PARTITION BY "C"."CITY" ORDER BY SUM("S"."AMOUNT") DESC )<=5)
5 - access("C"."CUSTOMER_ID"="S"."CUSTOMER_ID")
7 - access("S"."PRODUCT_ID"="P"."PRODUCT_ID")
9 - filter(("S"."STATUS"<>'CANCELLED' AND TO_CHAR(INTERNAL_FUNCTION("S"."SALE_DATE"),'YYYY')='2025'))

Note
-----
- cardinality feedback used for this statement
```

---

### 2.4 What's Wrong With It

> Fill in each problem after analyzing the execution plan above.

| # | Problem | Where it shows up in the plan | Impact |
|---|---|---|---|
| 1 | `Function on indexed column (TO_CHAR(s.sale_date, 'YYYY'))` | `Step 9 – TABLE ACCESS FULL SALES_PRJ` | `Prevents index usage → forces full scan of 22M rows` |
| 2 | `Full table scan on large fact table` | `Step 9 – TABLE ACCESS FULL SALES_PRJ` | `Reads 303K blocks → heavy I/O cost` |
| 3 | `Huge hash join spilling to disk` | `Step 5 – HASH JOIN (Used-Tmp: 605K)` | `Temp space usage → slows execution significantly` |
| 4 | `Late filtering (after scan, not before)` | `Step 9 filter applied after full scan` | `Processes unnecessary rows → wastes CPU & memory` |
| 5 | `Expensive sorting for GROUP BY + WINDOW functions` | `Steps 2, 4 – SORT GROUP BY, WINDOW SORT` | `High memory usage + 74K writes → sorting overhead` |

---

## 3. Optimization Steps

### 3.1 The Optimized Query

> Replace this placeholder with the final rewritten query after all changes are applied.

```sql
WITH filtered_sales AS (
    SELECT customer_id, product_id, amount
    FROM sales_prj
    WHERE sale_date >= DATE '2025-01-01'
      AND sale_date < DATE '2026-01-01'
      AND status = 'COMPLETED'
),
aggregated AS (
    SELECT c.city,
           p.category,
           c.segment,
           SUM(s.amount) AS total_sales
    FROM filtered_sales s
    JOIN customers_prj c 
        ON c.customer_id = s.customer_id
    JOIN products_prj p 
        ON p.product_id = s.product_id
    GROUP BY c.city, p.category, c.segment
)
SELECT city, category, segment, total_sales, sales_rank, avg_segment_sales
FROM (
    SELECT city,
           category,
           segment,
           total_sales,
           RANK() OVER (
               PARTITION BY city
               ORDER BY total_sales DESC
           ) AS sales_rank,
           AVG(total_sales) OVER (
               PARTITION BY segment
           ) AS avg_segment_sales
    FROM aggregated
)
WHERE sales_rank <= 5;

```

---

### 3.2 What Changed and Why

Each change below targets a specific root cause identified in Section 2.4.

---

#### Change 1 — `Removed Non-SARGable Date Filter`

**What was changed:**
> `TO_CHAR(s.sale_date,'YYYY') = '2025'`

**To:**
> `sale_date >= DATE '2025-01-01'
AND sale_date <  DATE '2026-01-01'`

**Why:**
> `The original expression applied a function (TO_CHAR) on the column, making it non-SARGable, which prevents index usage on sale_date.
The new range predicate allows the optimizer to use indexes efficiently and reduces full table scans.`

---

#### Change 2 — `Early Data Reduction Using CTE (filtered_sales)`

**What was changed:**
> Introduced a CTE to filter rows before joins:

WITH filtered_sales AS (
    SELECT customer_id, product_id, amount
    FROM sales_prj
    WHERE ...
)`

**Why:**
> `Filtering early significantly reduces the number of rows participating in joins and aggregation.
This lowers:
I/O cost
Join cost
Memory usage
This is especially important for large fact tables like sales_prj.`

---

#### Change 3 — `Replaced status <> 'CANCELLED' with Positive Filter`

**What was changed:**
> `status <> 'CANCELLED'`

**To:**
> `status = 'COMPLETED'`

**Why:**
> `Inequality conditions (<>) are less selective and harder to optimize, often leading to full scans.
Using an equality condition:
Improves cardinality estimation
Enables index usage on status
Reduces unnecessary rows earlier in execution`

---

#### Change 4 — `Separated Aggregation from Window Functions`

**What was changed:**
> `Moved aggregation into its own CTE`

**Why:**
> `By separating:
Aggregation happens once
Window functions operate on pre-aggregated data`

---

#### Change 5 — `Converted Implicit Joins to Explicit JOIN Syntax`

**What was changed:**
> `FROM customers_prj c, sales_prj s, products_prj p
WHERE ...`

**To:**
> `FROM filtered_sales s
JOIN customers_prj c ON ...
JOIN products_prj p ON ...`

**Why:**
> `Improve readability and maintainability
Help the optimizer better understand join relationships
Reduce risk of accidental Cartesian products`

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