CREATE TABLE customers_prj (
    customer_id NUMBER PRIMARY KEY,
    customer_name VARCHAR2(50),
    city VARCHAR2(50),
    segment VARCHAR2(20)
);

DECLARE
  v_batch_size NUMBER := 100000;
  v_total_rows NUMBER := 5000000;
  v_start_id NUMBER := 1;
BEGIN
  FOR i IN 1..CEIL(v_total_rows / v_batch_size) LOOP
    INSERT INTO customers_prj
    SELECT v_start_id + LEVEL - 1,
           'Customer ' || (v_start_id + LEVEL - 1),
           CASE WHEN MOD(v_start_id + LEVEL - 1, 4) = 0 THEN 'Cairo'
                WHEN MOD(v_start_id + LEVEL - 1, 4) = 1 THEN 'Alex'
                WHEN MOD(v_start_id + LEVEL - 1, 4) = 2 THEN 'Ismailia'
                ELSE 'Tanta' END,
           CASE WHEN MOD(v_start_id + LEVEL - 1, 3) = 0 THEN 'RETAIL'
                WHEN MOD(v_start_id + LEVEL - 1, 3) = 1 THEN 'CORPORATE'
                ELSE 'SMALL_BIZ' END
    FROM dual CONNECT BY LEVEL <= LEAST(v_batch_size, v_total_rows - v_start_id + 1);
    
    v_start_id := v_start_id + v_batch_size;
    COMMIT;
  END LOOP;
END;
/
