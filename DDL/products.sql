CREATE TABLE products_prj (
    product_id NUMBER PRIMARY KEY,
    product_name VARCHAR2(50),
    category VARCHAR2(30)
);

INSERT INTO products_prj
SELECT LEVEL,
       'Product ' || LEVEL,
       CASE WHEN MOD(LEVEL,5)=0 THEN 'Electronics'
            WHEN MOD(LEVEL,5)=1 THEN 'Food'
            WHEN MOD(LEVEL,5)=2 THEN 'Clothes'
            WHEN MOD(LEVEL,5)=3 THEN 'Furniture'
            ELSE 'Toys' END
FROM dual CONNECT BY LEVEL <= 50000;

COMMIT;
