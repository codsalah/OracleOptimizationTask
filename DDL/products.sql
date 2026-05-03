CREATE TABLE products_prj (
    product_id NUMBER PRIMARY KEY,
    product_name VARCHAR2(100),
    category VARCHAR2(50)
);

DECLARE
  v_batch_size NUMBER := 100000;
  v_total_rows NUMBER := 500000;
  v_start_id NUMBER := 1;
BEGIN
  FOR i IN 1..CEIL(v_total_rows / v_batch_size) LOOP
    INSERT INTO products_prj
    SELECT v_start_id + LEVEL - 1,
           'Product ' || (v_start_id + LEVEL - 1),
           CASE WHEN MOD(v_start_id + LEVEL - 1, 5) = 0 THEN 'Electronics'
                WHEN MOD(v_start_id + LEVEL - 1, 5) = 1 THEN 'Food'
                WHEN MOD(v_start_id + LEVEL - 1, 5) = 2 THEN 'Clothes'
                WHEN MOD(v_start_id + LEVEL - 1, 5) = 3 THEN 'Furniture'
                ELSE 'Toys' END
    FROM dual CONNECT BY LEVEL <= LEAST(v_batch_size, v_total_rows - v_start_id + 1);
    
    v_start_id := v_start_id + v_batch_size;
    COMMIT;
  END LOOP;
END;
/
