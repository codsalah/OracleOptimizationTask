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
| **Elapsed Time (seconds)** | `10.36 sec` |
| **CPU Time (seconds)** | `10.15 sec` |
| **Disk Reads** | `312507` |
| **Buffer Gets (Logical Reads)** | `307017` |
| **Rows Processed** | `20` |
| **Sorts** | `3` |
| **Optimizer Cost** | `87153` |
| **Executions** | `1` |

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

```
PLAN_TABLE_OUTPUT                                                                                 |
--------------------------------------------------------------------------------------------------+
Plan hash value: 354816077                                                                        |
                                                                                                  |
--------------------------------------------------------------------------------------------------|
| Id  | Operation                | Name          | Rows  | Bytes |TempSpc| Cost (%CPU)| Time     ||
--------------------------------------------------------------------------------------------------|
|   0 | SELECT STATEMENT         |               |    31 |  2945 |       | 87169   (3)| 00:17:27 ||
|*  1 |  VIEW                    |               |    31 |  2945 |       | 87169   (3)| 00:17:27 ||
|*  2 |   WINDOW SORT PUSHED RANK|               |    31 |  2108 |       | 87169   (3)| 00:17:27 ||
|   3 |    WINDOW BUFFER         |               |    31 |  2108 |       | 87169   (3)| 00:17:27 ||
|   4 |     SORT GROUP BY        |               |    31 |  2108 |       | 87169   (3)| 00:17:27 ||
|*  5 |      HASH JOIN           |               | 75221 |  4995K|  4264K| 87162   (3)| 00:17:26 ||
|*  6 |       HASH JOIN          |               | 75221 |  3379K|  1224K| 85367   (3)| 00:17:05 ||
|   7 |        TABLE ACCESS FULL | PRODUCTS_PRJ  | 50000 |   634K|       |    63   (2)| 00:00:01 ||
|*  8 |        TABLE ACCESS FULL | SALES_PRJ     |   449K|    14M|       | 84283   (3)| 00:16:52 ||
|   9 |       TABLE ACCESS FULL  | CUSTOMERS_PRJ |   500K|    10M|       |   778   (1)| 00:00:10 ||
--------------------------------------------------------------------------------------------------|
                                                                                                  |
Predicate Information (identified by operation id):                                               |
---------------------------------------------------                                               |
                                                                                                  |
   1 - filter("SALES_RANK"<=5)                                                                    |
   2 - filter(RANK() OVER ( PARTITION BY "C"."CITY" ORDER BY SUM("S"."AMOUNT") DESC )<=5)         |
   5 - access("C"."CUSTOMER_ID"="S"."CUSTOMER_ID")                                                |
   6 - access("S"."PRODUCT_ID"="P"."PRODUCT_ID")                                                  |
   8 - filter("S"."STATUS"<>'CANCELLED' AND TO_CHAR(INTERNAL_FUNCTION("S"."SALE_DATE"),'YY        |
              YY')='2025')                                                                        |
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

```
PLAN_TABLE_OUTPUT                                                                                                                       |
----------------------------------------------------------------------------------------------------------------------------------------+
SQL_ID  4qd0rh1r28mrh, child number 1                                                                                                   |
-------------------------------------                                                                                                   |
SELECT /*+ gather_plan_statistics */ * FROM (     SELECT c.city,                                                                        |
        p.category,            c.segment,            SUM(s.amount) AS                                                                   |
total_sales,            RANK() OVER (PARTITION BY c.city ORDER BY                                                                       |
SUM(s.amount) DESC) AS sales_rank,            AVG(SUM(s.amount)) OVER                                                                   |
(PARTITION BY c.segment)              AS avg_segment_sales     FROM                                                                     |
customers_prj c,          sales_prj     s,          products_prj  p                                                                     |
   WHERE c.customer_id = s.customer_id       AND s.product_id  =                                                                        |
p.product_id       AND TO_CHAR(s.sale_date, 'YYYY') = '2025'                                                                            |
AND s.status <> 'CANCELLED'     GROUP BY c.city, p.category,                                                                            |
c.segment ) WHERE sales_rank <= 5                                                                                                       |
                                                                                                                                        |
Plan hash value: 4200398583                                                                                                             |
                                                                                                                                        |
----------------------------------------------------------------------------------------------------------------------------------------|
| Id  | Operation                | Name          | Starts | E-Rows | A-Rows |   A-Time   | Buffers | Reads  |  OMem |  1Mem | Used-Mem ||
----------------------------------------------------------------------------------------------------------------------------------------|
|   0 | SELECT STATEMENT         |               |      1 |        |     20 |00:00:10.28 |     306K|    306K|       |       |          ||
|*  1 |  VIEW                    |               |      1 |     31 |     20 |00:00:10.28 |     306K|    306K|       |       |          ||
|*  2 |   WINDOW SORT PUSHED RANK|               |      1 |     31 |     24 |00:00:10.28 |     306K|    306K|  6144 |  6144 | 6144  (0)||
|   3 |    WINDOW BUFFER         |               |      1 |     31 |     54 |00:00:10.28 |     306K|    306K|  4096 |  4096 | 4096  (0)||
|   4 |     SORT GROUP BY        |               |      1 |     31 |     54 |00:00:10.28 |     306K|    306K|  4096 |  4096 | 4096  (0)||
|*  5 |      HASH JOIN           |               |      1 |    600K|    225K|00:00:00.40 |     306K|    306K|    19M|  4401K|   24M (0)||
|   6 |       TABLE ACCESS FULL  | CUSTOMERS_PRJ |      1 |    500K|    500K|00:00:00.05 |    2850 |   2845 |       |       |          ||
|*  7 |       HASH JOIN          |               |      1 |   2224K|   2253K|00:00:01.27 |     304K|    303K|  2070K|  1183K| 3238K (0)||
|   8 |        TABLE ACCESS FULL | PRODUCTS_PRJ  |      1 |  50000 |  50000 |00:00:00.01 |     225 |      0 |       |       |          ||
|*  9 |        TABLE ACCESS FULL | SALES_PRJ     |      1 |     22M|     22M|00:00:07.85 |     303K|    303K|       |       |          ||
----------------------------------------------------------------------------------------------------------------------------------------|
                                                                                                                                        |
Predicate Information (identified by operation id):                                                                                     |
---------------------------------------------------                                                                                     |
                                                                                                                                        |
   1 - filter("SALES_RANK"<=5)                                                                                                          |
   2 - filter(RANK() OVER ( PARTITION BY "C"."CITY" ORDER BY SUM("S"."AMOUNT") DESC )<=5)                                               |
   5 - access("C"."CUSTOMER_ID"="S"."CUSTOMER_ID")                                                                                      |
   7 - access("S"."PRODUCT_ID"="P"."PRODUCT_ID")                                                                                        |
   9 - filter(("S"."STATUS"<>'CANCELLED' AND TO_CHAR(INTERNAL_FUNCTION("S"."SALE_DATE"),'YYYY')='2025'))                                |
                                                                                                                                        |
Note                                                                                                                                    |
-----                                                                                                                                   |
   - cardinality feedback used for this statement                                                                                       |
```

---

### 2.4 What's Wrong With It

| # | Problem | Where it shows up in the plan | Impact |
|---|---|---|---|
| 1 | `TO_CHAR(sale_date, 'YYYY')` wraps the column in a function, making it non-indexable | `TABLE ACCESS FULL` on `sales_prj` — Oracle has no choice but to scan all 50M rows | Every single row in the largest table gets read and evaluated on every execution, regardless of how selective the date filter actually is |
| 2 | Filters for `sale_date` and `status` are applied **after** the join, not before | `FILTER` step appears downstream of the `HASH JOIN` operations | Oracle joins all three tables first — carrying the full 50M row dataset into the join — then discards the rows it didn't need. All that join work is wasted on rows that should never have entered it |
| 3 | No statistics gathered after data load | Cardinality estimates (`E-Rows`) in the plan will be wildly off compared to actual rows (`A-Rows`) | The optimizer makes every decision — join order, join method, access path — based on wrong numbers, which can lead to catastrophically bad plan choices |
| 4 | Three separate sort operations triggered — `SORT GROUP BY`, `WINDOW SORT` for `RANK()`, and `WINDOW SORT` for `AVG()` | Three distinct `SORT` or `WINDOW SORT` lines in the plan | Each sort pass on a large intermediate dataset consumes PGA memory. If the dataset doesn't fit in memory, Oracle spills to temp disk — turning an in-memory operation into physical I/O |
| 5 | `SELECT *` on the outer query and implicit comma-style joins on the inner query | Outer `SELECT *` pulls every column through every layer; comma joins obscure join structure from the optimizer | Unnecessary columns carried through the entire pipeline add I/O overhead at every step, and implicit joins can limit the optimizer's ability to determine the most efficient join order |
---

## 3. Optimization Steps

### 3.1 The Optimized Query

> Replace this placeholder with the final rewritten query after all changes are applied.

```sql
WITH filtered_sales AS (
  SELECT /*+ parallel(sales_prj, 6) */
         customer_id,
         product_id,
         amount
  FROM   sales_prj
  WHERE  status    = 'COMPLETED'
    AND  sale_date >= DATE '2025-01-01'
    AND  sale_date <  DATE '2026-01-01'
),
aggregated AS (
  SELECT c.city,
         p.category,
         c.segment,
         SUM(fs.amount) AS total_sales
  FROM   filtered_sales fs
  JOIN   products_prj   p ON p.product_id  = fs.product_id
  JOIN   customers_prj  c ON c.customer_id = fs.customer_id
  GROUP  BY c.city, p.category, c.segment
),
ranked AS (
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
  FROM   aggregated
)
SELECT city,
       category,
       segment,
       total_sales,
       sales_rank,
       avg_segment_sales
FROM   ranked
WHERE  sales_rank <= 5;
```

---

### 3.2 What Changed and Why

Each change below targets a specific root cause identified in Section 2.4.

---

#### Change 1 — `Composite Index on Sales_PRJ`

**What was changed:**
> `A composite index on sales_date and status was created for table Sales_PRJ.`

```sql
CREATE INDEX idx_sales_date_status
ON sales_prj (sale_date, status);
```

**Why:**
> `Allows for more efficent sorting and filtering over the table.`

---

#### Change 2 — `Early Filtering`

**What was changed:**
> `Delegated appropriate filtering to each relevant CTEs.`

**Why:**
> `Avoid filtering after joining the data, making the operation more expensive by having to filter over a bigger number of rows.`

---

#### Change 3 — `CTEs instead of inline views`

**What was changed:**
> `Created CTEs for each stage of our original query instead of inline views.`

**Why:**
> `Seperation of each stage of our queries, efficently decreasing the number of rows processed compared to the original query.`

---

#### Change 4 — `Parallel HINT`

**What was changed:**
> `Used parallel hint over our new query with a parallel factor of 4 (adjustable).`

**Why:**
> `Processed the large Sales_PRJ table (50M rows) in parallel, distributing workload over different cores/thread on our CPU.`

---

#### Change 5 — `Reordered Joins`

**What was changed:**
> `Reordered joins between each table and another.`

**Why:**
> `This allows for less sorting and less processing by joining appropriately sized tables first before joining to the large one.`

---

#### Change 6 — `Column Pruning`

**What was changed:**
> `Got rid of SELECT * in our original query with only the columns we needed.`

**Why:**
> `Avoid the costly process of having to retrieve data from columns we might not even need in our query.`

---

#### Change 7 — `Misc. Changes`

**What was changed:**
> `Made adjustments over window functions and other parts of the queries wrapped around functions (ex: year filtering by using TO_CHAR)`

**Why:**
> `Wrapping the filter inside TO_CHAR disabled any index that might have been created on this column, also ranking in our original query caused unnecessary sorting that was later adjusted.`

---

## 4. After Tuning

### 4.1 Performance Metrics (Post-Optimization)

#### Recorded Values

> Run the same metric queries from Section 2.2, this time against the optimized query. Fill in both columns then calculate the improvement.

| Metric | Before | After | 
|---|---|---|
| **Elapsed Time (seconds)** | `10.36` | `5.02` |
| **CPU Time (seconds)** | `10.05` | `4.8` | 
| **Disk Reads** | `312507` | `306175` | 
| **Buffer Gets (Logical Reads)** | `307017` | `306911` | 
| **Rows Processed** | `20` | `20` |
| **Sorts** | `3` | `3` | `↓ ___` |
| **Optimizer Cost** | `138866` | `138866` |

---

### 4.2 New Execution Plan

Two methods are provided below, same as in Section 2.3. Capture both and compare against the original plan output.

---

#### Method A — Estimated Plan (query does not execute)

> Same approach as before — gives you Oracle's cost estimate for the optimized query before it runs.

```sql
EXPLAIN PLAN FOR
WITH filtered_sales AS (
  SELECT /*+ parallel(sales_prj, 6) */
         customer_id,
         product_id,
         amount
  FROM   sales_prj
  WHERE  status    = 'COMPLETED'
    AND  sale_date >= DATE '2025-01-01'
    AND  sale_date <  DATE '2026-01-01'
),
aggregated AS (
  SELECT c.city,
         p.category,
         c.segment,
         SUM(fs.amount) AS total_sales
  FROM   filtered_sales fs
  JOIN   products_prj   p ON p.product_id  = fs.product_id
  JOIN   customers_prj  c ON c.customer_id = fs.customer_id
  GROUP  BY c.city, p.category, c.segment
),
ranked AS (
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
  FROM   aggregated
)
SELECT city,
       category,
       segment,
       total_sales,
       sales_rank,
       avg_segment_sales
FROM   ranked
WHERE  sales_rank <= 5;

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);
```

```
PLAN_TABLE_OUTPUT                                                                                 |
--------------------------------------------------------------------------------------------------+
Plan hash value: 4200398583                                                                       |
                                                                                                  |
--------------------------------------------------------------------------------------------------|
| Id  | Operation                | Name          | Rows  | Bytes |TempSpc| Cost (%CPU)| Time     ||
--------------------------------------------------------------------------------------------------|
|   0 | SELECT STATEMENT         |               |    31 |  2945 |       |   138K  (1)| 00:27:47 ||
|*  1 |  VIEW                    |               |    31 |  2945 |       |   138K  (1)| 00:27:47 ||
|*  2 |   WINDOW SORT PUSHED RANK|               |    31 |  2108 |       |   138K  (1)| 00:27:47 ||
|   3 |    WINDOW BUFFER         |               |    31 |  2108 |       |   138K  (1)| 00:27:47 ||
|   4 |     SORT GROUP BY        |               |    31 |  2108 |       |   138K  (1)| 00:27:47 ||
|*  5 |      HASH JOIN           |               |   599K|    38M|    16M|   138K  (1)| 00:27:46 ||
|   6 |       TABLE ACCESS FULL  | CUSTOMERS_PRJ |   500K|    10M|       |   778   (1)| 00:00:10 ||
|*  7 |       HASH JOIN          |               |  2205K|    96M|  1224K|   131K  (1)| 00:26:14 ||
|   8 |        TABLE ACCESS FULL | PRODUCTS_PRJ  | 50000 |   634K|       |    63   (2)| 00:00:01 ||
|*  9 |        TABLE ACCESS FULL | SALES_PRJ     |    22M|   703M|       | 83292   (2)| 00:16:40 ||
--------------------------------------------------------------------------------------------------|
                                                                                                  |
Predicate Information (identified by operation id):                                               |
---------------------------------------------------                                               |
                                                                                                  |
   1 - filter("SALES_RANK"<=5)                                                                    |
   2 - filter(RANK() OVER ( PARTITION BY "C"."CITY" ORDER BY SUM("AMOUNT") DESC )<=5)             |
   5 - access("C"."CUSTOMER_ID"="CUSTOMER_ID")                                                    |
   7 - access("P"."PRODUCT_ID"="PRODUCT_ID")                                                      |
   9 - filter("SALE_DATE">=TO_DATE(' 2025-01-01 00:00:00', 'syyyy-mm-dd hh24:mi:ss') AND          |
              "SALE_DATE"<TO_DATE(' 2026-01-01 00:00:00', 'syyyy-mm-dd hh24:mi:ss') AND           |
              "STATUS"='COMPLETED')                                                               |
```

---

#### Method B — Actual Runtime Plan (query executes fully)

> Run the optimized query with the hint and capture the actual plan. This is what you compare directly against the original Method B output from Section 2.3.

```sql
SELECT /*+ gather_plan_statistics */
[ PASTE OPTIMIZED QUERY BODY HERE ];

SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));
```

```
PLAN_TABLE_OUTPUT                                                                                                                       |
----------------------------------------------------------------------------------------------------------------------------------------+
SQL_ID  9k2n3j9zttpat, child number 0                                                                                                   |
-------------------------------------                                                                                                   |
WITH filtered_sales AS (   SELECT /*+ gather_plan_statistics                                                                            |
parallel(sales_prj, 4) */          customer_id,          product_id,                                                                    |
         amount   FROM   sales_prj   WHERE  status    = 'COMPLETED'                                                                     |
   AND  sale_date >= DATE '2025-01-01'     AND  sale_date <  DATE                                                                       |
'2026-01-01' ), aggregated AS (   SELECT c.city,                                                                                        |
p.category,          c.segment,          SUM(fs.amount) AS                                                                              |
total_sales   FROM   filtered_sales fs   JOIN   products_prj   p ON                                                                     |
p.product_id  = fs.product_id   JOIN   customers_prj  c ON                                                                              |
c.customer_id = fs.customer_id   GROUP  BY c.city, p.category,                                                                          |
c.segment ), ranked AS (   SELECT city,          category,                                                                              |
 segment,          total_sales,          RANK() OVER (                                                                                  |
PARTITION BY city            ORDER BY total_sales DESC          ) AS                                                                    |
sales_rank,          AVG(total_sales) OVER (            PARTITION BY                                                                    |
segment          ) AS avg_segment_sales   FROM   aggregated )                                                                           |
SELECT city,        category,        segment,        total                                                                              |
                                                                                                                                        |
Plan hash value: 4200398583                                                                                                             |
                                                                                                                                        |
----------------------------------------------------------------------------------------------------------------------------------------|
| Id  | Operation                | Name          | Starts | E-Rows | A-Rows |   A-Time   | Buffers | Reads  |  OMem |  1Mem | Used-Mem ||
----------------------------------------------------------------------------------------------------------------------------------------|
|   0 | SELECT STATEMENT         |               |      1 |        |     20 |00:00:04.57 |     306K|    303K|       |       |          ||
|*  1 |  VIEW                    |               |      1 |     31 |     20 |00:00:04.57 |     306K|    303K|       |       |          ||
|*  2 |   WINDOW SORT PUSHED RANK|               |      1 |     31 |     24 |00:00:04.57 |     306K|    303K|  6144 |  6144 | 6144  (0)||
|   3 |    WINDOW BUFFER         |               |      1 |     31 |     54 |00:00:04.57 |     306K|    303K|  4096 |  4096 | 4096  (0)||
|   4 |     SORT GROUP BY        |               |      1 |     31 |     54 |00:00:04.57 |     306K|    303K|  4096 |  4096 | 4096  (0)||
|*  5 |      HASH JOIN           |               |      1 |    599K|    225K|00:00:00.25 |     306K|    303K|    19M|  4401K|   24M (0)||
|   6 |       TABLE ACCESS FULL  | CUSTOMERS_PRJ |      1 |    500K|    500K|00:00:00.03 |    2850 |      0 |       |       |          ||
|*  7 |       HASH JOIN          |               |      1 |   2205K|   2253K|00:00:00.68 |     304K|    303K|  2070K|  1183K| 3208K (0)||
|   8 |        TABLE ACCESS FULL | PRODUCTS_PRJ  |      1 |  50000 |  50000 |00:00:00.01 |     225 |      0 |       |       |          ||
|*  9 |        TABLE ACCESS FULL | SALES_PRJ     |      1 |     22M|     22M|00:00:02.87 |     303K|    303K|       |       |          ||
----------------------------------------------------------------------------------------------------------------------------------------|
                                                                                                                                        |
Predicate Information (identified by operation id):                                                                                     |
---------------------------------------------------                                                                                     |
                                                                                                                                        |
   1 - filter("SALES_RANK"<=5)                                                                                                          |
   2 - filter(RANK() OVER ( PARTITION BY "C"."CITY" ORDER BY SUM("AMOUNT") DESC )<=5)                                                   |
   5 - access("C"."CUSTOMER_ID"="CUSTOMER_ID")                                                                                          |
   7 - access("P"."PRODUCT_ID"="PRODUCT_ID")                                                                                            |
   9 - filter(("SALE_DATE">=TO_DATE(' 2025-01-01 00:00:00', 'syyyy-mm-dd hh24:mi:ss') AND "SALE_DATE"<TO_DATE(' 2026-01-01              |
              00:00:00', 'syyyy-mm-dd hh24:mi:ss') AND "STATUS"='COMPLETED'))                                                           |
                                                                                                                                        |
```

---

*Project submitted as part of the SQL Tuning course. All optimizations were tested against the same dataset and Oracle environment.*