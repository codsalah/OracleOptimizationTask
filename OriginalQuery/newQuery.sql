-- Optimized Query
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

-- Metrics for this query
WITH filtered_sales AS (
  SELECT /*+ gather_plan_statistics parallel(sales_prj, 4) */
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

-- Execution Plans
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


-- Runtime Explain plan
WITH filtered_sales AS (
  SELECT /*+ gather_plan_statistics parallel(sales_prj, 4) */
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


SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY_CURSOR(NULL, NULL, 'ALLSTATS LAST'));