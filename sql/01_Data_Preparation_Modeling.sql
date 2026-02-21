--create database Supermarchés
USE Supermarchés
GO

DROP TABLE if exists train_work;

-- Créer une copie de train
SELECT *
INTO train_work
FROM train;

-- Sélectionner les doublons
WITH cte AS (
    SELECT *,
           COUNT(*) OVER (
               PARTITION BY [Order ID], [Customer ID], [Product ID]
           ) AS Dup_Count
    FROM train_work
)
SELECT *
FROM cte
WHERE Dup_Count > 1;

-- Parmi les doublons, trois produits présentent des montants de vente différents, tandis qu’un produit est strictement identique.

-- Vérification du nombre de lignes avant suppression
SELECT COUNT(*) FROM train_work;

-- Identification des doublons par combinaison Order ID, Customer ID, Product ID et Sales
-- Row_num > 1 correspond aux lignes dupliquées à exclure
WITH duplicate_cte AS(
SELECT *,
		ROW_NUMBER() OVER(partition by [Order ID], [Customer ID], [Product ID], Sales 
		ORDER BY [Row ID]) as Row_num
FROM train_work
)
DELETE FROM duplicate_cte
WHERE Row_num >1;

-- Vérification du nombre de lignes après suppression
SELECT COUNT(*) FROM train_work;

------------Standardiser les données---------------

-- Vérifier si nous avons des champs vides
DECLARE @sql NVARCHAR(MAX) = '';

SELECT @sql = @sql + '
SELECT ''' + COLUMN_NAME + ''' AS ColumnName,
       COUNT(*) AS TotalRows,
       SUM(CASE
            WHEN ' + QUOTENAME(COLUMN_NAME) + ' IS NULL
                 OR LTRIM(RTRIM(CAST(' + QUOTENAME(COLUMN_NAME) + ' AS NVARCHAR(MAX)))) = ''''
            THEN 1 ELSE 0 END) AS NullOrEmpty
FROM train_work
UNION ALL'
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'train_work';

SET @sql = LEFT(@sql, LEN(@sql) - 9); -- enlever le dernier UNION ALL

EXEC sp_executesql @sql;

-- Résultat : seules 11 lignes présentent une valeur manquante dans la colonne Postal Code

-- Transformer les champs vides en NULL
UPDATE train_work
SET [Postal Code] = NULL
WHERE LTRIM(RTRIM([Postal Code])) = '';

-- Vérifier les types 
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'train_work'
ORDER BY ORDINAL_POSITION;

-- Convertir Row ID à entier
ALTER TABLE train_work
ALTER COLUMN [Row ID] INT NOT NULL;

-- Convertir Order Date et Ship Date (103 c'est format DD/MM/YYYY)
UPDATE train_work
SET [Order Date] = CONVERT(DATE, [Order Date], 103),
    [Ship Date]  = CONVERT(DATE, [Ship Date], 103);

ALTER TABLE train_work
ALTER COLUMN [Order Date] DATE;

ALTER TABLE train_work
ALTER COLUMN [Ship Date] DATE;

-- Convertir Sales de Varchar à Decimal(12,2)
ALTER TABLE train_work
ALTER COLUMN Sales DECIMAL(12,2);

-- Vérifier type après modification
SELECT COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'train_work'
ORDER BY ORDINAL_POSITION;

-- Identifier les codes postaux non conformes au format américain (5 chiffres)
SELECT DISTINCT [Postal Code] 
FROM train_work
WHERE LEN([Postal Code])<5

-- Corriger les codes postaux
UPDATE train_work
SET [Postal Code] =
    RIGHT('00000' + CAST([Postal Code] AS VARCHAR(5)), 5)
WHERE LEN(CAST([Postal Code] AS VARCHAR(5))) = 4 ;

-- Vérifier après correction 
SELECT DISTINCT [Postal Code] 
FROM train_work
WHERE LEN([Postal Code])<>5;

--------Normalisation----------

DROP TABLE IF EXISTS Fact_Sales;
DROP TABLE IF EXISTS Dim_Customer;
DROP TABLE IF EXISTS Dim_Product;

--Création de la table Customer
CREATE TABLE Dim_Customer (
    [Customer ID]   VARCHAR(50)  NOT NULL,
    [Customer Name] VARCHAR(200) NULL,
    Segment         VARCHAR(50)  NULL,
);

--Création de la table Dim_Product
CREATE TABLE Dim_Product (
    [Product ID]   VARCHAR(50)  NOT NULL,
    [Product Name] VARCHAR(200) NULL,
    Category       VARCHAR(50)  NULL,
    [Sub-Category] VARCHAR(50)  NULL,
);

--Création de la table Fact_Sales
CREATE TABLE dbo.Fact_Sales (
    [Row ID]       INT           NOT NULL,
    [Order ID]     VARCHAR(50)   NOT NULL,
    [Order Date]   DATE          NOT NULL,
    [Ship Date]    DATE          NULL,
    [Ship Mode]    VARCHAR(50)   NULL,
    Country        VARCHAR(50)   NULL,
    City           VARCHAR(50)   NULL,
    State          VARCHAR(50)   NULL,
    [Postal Code]  VARCHAR(5)    NULL,
    Region         VARCHAR(50)   NULL,
    Sales          DECIMAL(12,2) NOT NULL,
    [Customer ID]  VARCHAR(50)   NOT NULL,
    [Product ID]   VARCHAR(50)   NOT NULL,
);

-- Insérer les données dans la table Dim_Customer
INSERT INTO Dim_Customer ([Customer ID], [Customer Name], Segment)
SELECT DISTINCT
    [Customer ID],
    [Customer Name],
    Segment
FROM train_work
WHERE [Customer ID] IS NOT NULL;

-- Insérer les données dans la table Dim_Product
INSERT INTO Dim_Product ([Product ID], [Product Name], Category, [Sub-Category])
SELECT
    [Product ID],
    [Product Name],
    Category,
    [Sub-Category]
FROM train_work
WHERE [Product ID] IS NOT NULL;

-- Insérer les données dans la table Fact_Sales
INSERT INTO dbo.Fact_Sales (
    [Row ID],
    [Order ID],
    [Order Date],
    [Ship Date],
    [Ship Mode],
    Country,
    City,
    State,
    [Postal Code],
    Region,
    Sales,
    [Customer ID],
    [Product ID]
)
SELECT
    CAST([Row ID] AS INT),
    [Order ID],
    [Order Date],
    [Ship Date],
    [Ship Mode],
    Country,
    City,
    State,
    [Postal Code],
    Region,
    Sales,
    [Customer ID],
    [Product ID]
FROM dbo.train_work;

-- Vérifier la présence de doublons dans la table Dim_Customer
SELECT [Customer ID], COUNT(*) c
FROM Dim_Customer
GROUP BY [Customer ID]
HAVING COUNT(*) > 1;

-- Vérifier la présence de doublons dans la table Dim_Product
SELECT [Product ID], COUNT(*) c
FROM Dim_Product
GROUP BY [Product ID]
HAVING COUNT(*) > 1;

-- Résultat : Plusieurs Product ID sont associés à des noms de produits différents.

WITH dup_products AS (
    SELECT [Product ID]
    FROM train_work
    GROUP BY [Product ID]
    HAVING COUNT(DISTINCT [Product Name]) > 1
)
SELECT
    t.[Product ID],
    t.[Product Name],
    t.Category,
    t.[Sub-Category],
    COUNT(*) AS Nb_Lignes,
    SUM(t.Sales) AS Total_Sales
FROM train_work t
JOIN dup_products d
  ON t.[Product ID] = d.[Product ID]
GROUP BY
    t.[Product ID], t.[Product Name], t.Category, t.[Sub-Category]
ORDER BY
    t.[Product ID], Total_Sales DESC;

-- Décision : Pour chaque Product ID associé à plusieurs noms de produits, le nom conservé est celui générant le plus grand Total_Sales.

DELETE FROM Dim_Product;

;WITH sales_per_name AS (
    SELECT
        [Product ID],
        [Product Name],
        Category,
        [Sub-Category],
        SUM(Sales) AS Total_Sales
    FROM train_work
    GROUP BY
        [Product ID], [Product Name], Category, [Sub-Category]
),
ranked AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY [Product ID]
               ORDER BY Total_Sales DESC, [Product Name]
           ) AS rn
    FROM sales_per_name
)
INSERT INTO Dim_Product ([Product ID], [Product Name], Category, [Sub-Category])
SELECT
    [Product ID],
    [Product Name],
    Category,
    [Sub-Category]
FROM ranked
WHERE rn = 1;


-- Vérifier la présence de doublons dans la table Dim_Product après la modification
SELECT [Product ID], COUNT(*) c
FROM Dim_Product
GROUP BY [Product ID]
HAVING COUNT(*) > 1;

-- Ajouter les clés primaires et étrangères

-- Dim_Customer
ALTER TABLE Dim_Customer
ADD CONSTRAINT PK_Dim_Customer
PRIMARY KEY ([Customer ID]);

-- Dim_Product
ALTER TABLE Dim_Product
ADD CONSTRAINT PK_Dim_Product
PRIMARY KEY ([Product ID]);

-- Dim_Sales
ALTER TABLE Fact_Sales
ADD CONSTRAINT PK_Fact_Sales
PRIMARY KEY ([Row ID]);

ALTER TABLE Fact_Sales
ADD CONSTRAINT FK_Fact_Sales_Customer
FOREIGN KEY ([Customer ID])
REFERENCES Dim_Customer ([Customer ID]);

ALTER TABLE Fact_Sales
ADD CONSTRAINT FK_Fact_Sales_Product
FOREIGN KEY ([Product ID])
REFERENCES Dim_Product ([Product ID]);
