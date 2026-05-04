
-- Selecting tables to investigate the structure
SELECT * FROM SALES_PRJ;

SELECT * FROM CUSTOMERS_PRJ;

SELECT * FROM PRODUCTS_PRJ;

-- Running query to investigate the time it takes to execute
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

-- Indexes
-- The 3 PK Columns are Indexed by default, a composite index on sales_date and status is created
CREATE INDEX idx_sales_date_status
ON sales_prj (sale_date, status);

-- Refreshing Statistics after Indexing
BEGIN
    DBMS_STATS.GATHER_TABLE_STATS(
        ownname          => 'SQL_TUNING',
        tabname          => 'SALES_PRJ',
        estimate_percent => DBMS_STATS.AUTO_SAMPLE_SIZE,
        method_opt       => 'FOR ALL COLUMNS SIZE AUTO',
        cascade          => TRUE
    );
END;

-- Gathering Metrics after running the SQL Query
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

-- Gathering Execution Plans
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

-- Runtime Execution Plan (The actual plan Oracle Ran, not the provisioned one)
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