CREATE TABLE sales_prj (
    sales_id NUMBER PRIMARY KEY,
    customer_id NUMBER,
    product_id NUMBER,
    amount NUMBER,
    order_date DATE,
    status VARCHAR2(20)
);

DECLARE
  v_batch_size NUMBER := 100000;
  v_total_rows NUMBER := 50000000;
  v_start_id NUMBER := 1;
BEGIN
  FOR i IN 1..CEIL(v_total_rows / v_batch_size) LOOP
    INSERT /*+ APPEND */ INTO sales_prj
    SELECT v_start_id + LEVEL - 1,
           MOD(v_start_id + LEVEL - 1, 5000000) + 1,
           MOD(v_start_id + LEVEL - 1, 500000) + 1,
           TRUNC(DBMS_RANDOM.VALUE(100, 10000)),
           SYSDATE - MOD(v_start_id + LEVEL - 1, 730),
           CASE WHEN MOD(v_start_id + LEVEL - 1, 10) = 0 THEN 'CANCELLED'
                ELSE 'COMPLETED' END
    FROM dual CONNECT BY LEVEL <= LEAST(v_batch_size, v_total_rows - v_start_id + 1);
    
    v_start_id := v_start_id + v_batch_size;
    COMMIT;
  END LOOP;
END;
/

