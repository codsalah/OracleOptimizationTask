--explain plan for
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

--SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);