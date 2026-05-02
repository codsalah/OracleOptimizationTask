CREATE TABLE sales_prj (
    sale_id NUMBER PRIMARY KEY,
    customer_id NUMBER,
    product_id NUMBER,
    amount NUMBER,
    sale_date DATE,
    status VARCHAR2(20)
);

INSERT /*+ APPEND */ INTO sales_prj
SELECT LEVEL,
       MOD(LEVEL,500000)+1,
       MOD(LEVEL,50000)+1,
       TRUNC(DBMS_RANDOM.VALUE(100,10000)),
       SYSDATE - MOD(LEVEL,730),
       CASE WHEN MOD(LEVEL,10)=0 THEN 'CANCELLED'
            ELSE 'COMPLETED' END
FROM dual CONNECT BY LEVEL <= 5000000;

COMMIT;

