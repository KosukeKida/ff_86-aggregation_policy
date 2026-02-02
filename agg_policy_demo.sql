-- データベース作成、ロール作成からやるのでsysadminやuseradminが使えること
-- WAREHOUSEだけ事前作成済みのmy_whを使用しています。

USE ROLE useradmin;
CREATE ROLE ff;
GRANT ROLE ff TO ROLE sysadmin;

USE ROLE sysadmin;
GRANT usage ON WAREHOUSE my_wh TO ROLE ff;

USE ROLE sysadmin;
CREATE DATABASE frosty_friday;
GRANT OWNERSHIP ON DATABASE frosty_friday TO ROLE ff;

USE ROLE ff;
USE WAREHOUSE my_wh;
USE DATABASE frosty_friday;
CREATE SCHEMA agg_demo;
USE SCHEMA agg_demo;


-- Create the Sales_Records table
CREATE TABLE Sales_Records (
    Order_ID INT,
    Product_Name VARCHAR(50),
    Product_Category VARCHAR(50),
    Quantity INT,
    Unit_Price DECIMAL(10,2),
    Customer_ID INT
);

-- Insert sample data into the Sales_Records table
INSERT INTO Sales_Records (Order_ID, Product_Name, Product_Category, Quantity, Unit_Price, Customer_ID) VALUES
(1, 'Laptop', 'Electronics', 2, 1200.00, 101),
(2, 'Smartphone', 'Electronics', 1, 800.00, 102),
(3, 'Headphones', 'Electronics', 5, 50.00, 103),
(4, 'T-shirt', 'Apparel', 3, 20.00, 104),
(5, 'Jeans', 'Apparel', 2, 30.00, 105),
(6, 'Sneakers', 'Footwear', 1, 80.00, 106),
(7, 'Backpack', 'Accessories', 4, 40.00, 107),
(8, 'Sunglasses', 'Accessories', 2, 50.00, 108),
(9, 'Watch', 'Accessories', 1, 150.00, 109),
(10, 'Tablet', 'Electronics', 3, 500.00, 110),
(11, 'Jacket', 'Apparel', 2, 70.00, 111),
(12, 'Dress', 'Apparel', 1, 60.00, 112),
(13, 'Sandals', 'Footwear', 4, 25.00, 113),
(14, 'Belt', 'Accessories', 2, 30.00, 114),
(15, 'Speaker', 'Electronics', 1, 150.00, 115),
(16, 'Wallet', 'Accessories', 3, 20.00, 116),
(17, 'Hoodie', 'Apparel', 2, 40.00, 117),
(18, 'Running Shoes', 'Footwear', 1, 90.00, 118),
(19, 'Earrings', 'Accessories', 4, 15.00, 119),
(20, 'Ring', 'Accessories', 2, 50.00, 120);

-- test query
SELECT * FROM Sales_Records;
/*
ORDER_ID PRODUCT_NAME      PRODUCT_CATEGORY     QUANTITY   UNIT_PRICE    CUSTOMER_ID
-------- ---------------- -------------------- ----------- ------------- -----------
1        Laptop            Electronics          2               1200.00   101
2        Smartphone        Electronics          1                800.00   102
*/


SELECT product_category,count(order_id),sum(unit_price) AS total_sales
FROM sales_records
GROUP BY product_category;

/*
PRODUCT_CATEGORY     COUNT      TOTAL_SALES (sum of unit price) 
------------------- ----------- -------------------------------
Electronics          5                                  2700.00 
*/

-- 単に集計値を求めたと見えなくもありませんが、このクエリのガバナンス的な意味を考えてみましょう。
-- このクエリの意図は非権限者からは「customer_id」の明細行レベルが見えない状態で、カテゴリ別売上という集計値は見せるという点にあります。
-- 通常のGRANT文でテーブルに対するSELECT権限を与えてしまうと明細/集計に関わらずなんでもSELECTできてしまいます。


USE ROLE useradmin;
CREATE ROLE ff_cs_dept;  -- customer_id まで見て個々の製品購入者に対する問い合わせ対応にあたる
CREATE ROLE ff_mk_dept;  -- マーケ目的では売れ筋の商品などがわかればよく「誰が何を買った」はプライバシーの観点から閲覧禁止したい
GRANT ROLE ff_cs_dept TO ROLE ff;
GRANT ROLE ff_mk_dept TO ROLE ff;


USE ROLE ff;
GRANT usage ON DATABASE frosty_friday TO ROLE ff_cs_dept;
GRANT usage ON SCHEMA agg_demo TO ROLE ff_cs_dept;
GRANT select ON ALL TABLES IN SCHEMA agg_demo TO ROLE ff_cs_dept;
CREATE DATABASE ROLE bypass_agg_for_csinfo;
GRANT DATABASE ROLE bypass_agg_for_csinfo TO ROLE ff_cs_dept;

GRANT usage ON DATABASE frosty_friday TO ROLE ff_mk_dept;
GRANT usage ON SCHEMA agg_demo TO ROLE ff_mk_dept;
GRANT select ON ALL TABLES IN SCHEMA agg_demo TO ROLE ff_mk_dept;


-- 権限チェック
USE SECONDARY ROLE none;

USE ROLE ff_cs_dept;
SELECT IS_DATABASE_ROLE_IN_SESSION('BYPASS_AGG_FOR_CSINFO');
SELECT * FROM sales_records;

USE ROLE ff_mk_dept;
SELECT IS_DATABASE_ROLE_IN_SESSION('BYPASS_AGG_FOR_CSINFO');
SELECT * FROM sales_records;


-- ポリシー作成
USE ROLE ff;
CREATE AGGREGATION POLICY ff_agg_policy
  AS () RETURNS AGGREGATION_CONSTRAINT ->
    CASE
      WHEN IS_DATABASE_ROLE_IN_SESSION('BYPASS_AGG_FOR_CSINFO') = true
        THEN NO_AGGREGATION_CONSTRAINT()
      ELSE AGGREGATION_CONSTRAINT(MIN_GROUP_SIZE => 4)
    END;

ALTER TABLE Sales_Records SET AGGREGATION POLICY ff_agg_policy;

/* その他運用操作
ALTER TABLE Sales_Records SET AGGREGATION POLICY ff_agg_policy_2 FORCE; -- 既存ポリシーを置き換える際、タイミング問題で閲覧できてしまう瞬間を防ぐ
ALTER TABLE Sales_Records UNSET AGGREGATION POLICY; -- テーブルからポリシーを除去
*/

-- 実行
-- 許可されたロールのみが許可された集約関数を実行できる
-- https://docs.snowflake.com/ja/user-guide/aggregation-policies#query-requirements

USE SECONDARY ROLE none;

USE ROLE ff_cs_dept;
SELECT IS_DATABASE_ROLE_IN_SESSION('BYPASS_AGG_FOR_CSINFO');
SELECT * FROM sales_records; -- このロールは個人情報まで見れるのでGROUP BYが無くても閲覧可能

USE ROLE ff_mk_dept;
SELECT IS_DATABASE_ROLE_IN_SESSION('BYPASS_AGG_FOR_CSINFO');
SELECT * FROM sales_records; -- このロールは個人情報を見せたくないが集計値なら見せてOK

SELECT product_category,count(order_id),sum(unit_price) AS total_sales
FROM sales_records
GROUP BY product_category;

-- クエリは成功して集計値は返る。でもNULL行が一つ混ざってる。

USE ROLE ff_cs_dept;
SELECT product_category,count(order_id),sum(unit_price) AS total_sales
FROM sales_records
GROUP BY product_category;

-- policyで指定した MIN_GROUP_SIZE => 4 が効いてるね！


-- 許可されない集計関数の例
-- 集計関数なんだけど明細レベルの情報を返してくる子がいるよね

USE ROLE ff_cs_dept;
SELECT product_category,count(order_id),sum(unit_price) AS total_sales,ANY_VALUE(customer_id) AS sample_cusotmer
FROM sales_records
GROUP BY product_category;

SELECT product_category,count(order_id),sum(unit_price) AS total_sales,array_agg(customer_id) AS list_cusotmer
FROM sales_records
GROUP BY product_category;



USE ROLE ff_mk_dept;

SELECT product_category,count(order_id),sum(unit_price) AS total_sales,ANY_VALUE(customer_id) AS sample_cusotmer
FROM sales_records
GROUP BY product_category;

-- こういうのはダメです。

SELECT product_category,count(order_id),sum(unit_price) AS total_sales,array_agg(customer_id) AS list_cusotmer
FROM sales_records
GROUP BY product_category;

-- これももちろんダメです。

-- 超応用編！

/*
あるマーケ担当者が社外ブース展示で操作を教えて、その場で商品を買ってくれそうな顧客をつかまえました。
（でも、その人が何を買おうとしているかはわかっていません。）
このマーケ担当者は目の前の顧客が何を買ったのか把握し、それとなく、さらにおススメ商品をゴリ押ししたいと考えました。

このマーケ担当者がセキュリティの穴をついて目の前の顧客が買ったものを知る手段があります。SQLに詳しければね！

USE ROLE ff_mk_dept;
SELECT product_category,count(order_id),sum(unit_price) AS total_sales
FROM sales_records
GROUP BY product_category;

を繰り返し実行することです。
*/

/*
PRODUCT_CATEGORY     COUNT      TOTAL_SALES (sum of unit price) 
------------------- ----------- -------------------------------
Electronics          5                                  2700.00 
*/

/*
PRODUCT_CATEGORY     COUNT      TOTAL_SALES (sum of unit price) 
------------------- ----------- -------------------------------
Electronics          6                                  3200.00 
*/

/*
になった瞬間を捉えられれば、高確率で目の前の顧客がElectronicsカテゴリの500円商品を買ったことになります。

この問題を解消するための手段として差分プライバシーという機能があります。
集計値に常に少量のブレを加えたり（クエリするたびに数件の誤差をあえて加える）
その列のデータが明細行の特定に影響するスコアを設定しておいて、
クエリされたスコアの累積が一日のバジェットを超えるとそれ以上はクエリさせないという機能があります。
いずれも上記例のように「連続実行することである値が増えた瞬間を捕まえる」ことを防ぎます。
*/

