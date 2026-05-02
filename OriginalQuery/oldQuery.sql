-- Run the following query and analyze its performance:
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
      AND s.product_id = p.product_id
      AND TO_CHAR(s.sale_date,'YYYY') = '2025'
      AND s.status <> 'CANCELLED'
    GROUP BY c.city, p.category, c.segment
)
WHERE sales_rank <= 5;
