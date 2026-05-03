CREATE TABLE customers_prj (
    customer_id NUMBER PRIMARY KEY,
    customer_name VARCHAR2(50),
    city VARCHAR2(50),
    segment VARCHAR2(20)
);

INSERT INTO customers_prj
SELECT LEVEL,
       'Customer ' || LEVEL,
       CASE WHEN MOD(LEVEL,4)=0 THEN 'Cairo'
            WHEN MOD(LEVEL,4)=1 THEN 'Alex'
            WHEN MOD(LEVEL,4)=2 THEN 'Ismailia'
            ELSE 'Tanta' END,
       CASE WHEN MOD(LEVEL,3)=0 THEN 'RETAIL'
            WHEN MOD(LEVEL,3)=1 THEN 'CORPORATE'
            ELSE 'SMALL_BIZ' END
FROM dual CONNECT BY LEVEL <= 500000;

COMMIT;
