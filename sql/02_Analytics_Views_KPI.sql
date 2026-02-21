USE Supermarchés;
GO

-- Créer table Dim_Date
IF OBJECT_ID('FK_Fact_Sales_OrderDate', 'F') IS NOT NULL
BEGIN
    ALTER TABLE dbo.Fact_Sales DROP CONSTRAINT FK_Fact_Sales_OrderDate;
END

DROP TABLE IF EXISTS Dim_Date;

CREATE TABLE Dim_Date (
    DateKey        INT        NOT NULL, -- yyyymmdd
    FullDate       DATE       NOT NULL,
    DayNumber      TINYINT    NOT NULL,
    MonthNumber    TINYINT    NOT NULL,
    MonthName      VARCHAR(20) NOT NULL,
    YearNumber     SMALLINT   NOT NULL,
    QuarterNumber  TINYINT    NOT NULL,
    IsWeekend      BIT        NOT NULL,

    CONSTRAINT PK_Dim_Date
        PRIMARY KEY (DateKey)
);

DECLARE @StartDate DATE, @EndDate DATE;

SELECT
    @StartDate = MIN([Order Date]),
    @EndDate   = MAX([Order Date])
FROM Fact_Sales;

;WITH DateSeries AS (
    SELECT @StartDate AS FullDate
    UNION ALL
    SELECT DATEADD(DAY, 1, FullDate)
    FROM DateSeries
    WHERE FullDate < @EndDate
)
INSERT INTO Dim_Date (
    DateKey,
    FullDate,
    DayNumber,
    MonthNumber,
    MonthName,
    YearNumber,
    QuarterNumber,
    IsWeekend
)
SELECT
    CONVERT(INT, FORMAT(FullDate, 'yyyyMMdd')) AS DateKey,
    FullDate,
    DAY(FullDate),
    MONTH(FullDate),
    DATENAME(MONTH, FullDate),
    YEAR(FullDate),
    DATEPART(QUARTER, FullDate),
    CASE WHEN DATENAME(WEEKDAY, FullDate) IN ('Saturday','Sunday')
         THEN 1 ELSE 0 END
FROM DateSeries
OPTION (MAXRECURSION 0);
GO

ALTER TABLE Fact_Sales
DROP COLUMN OrderDateKey;

ALTER TABLE Fact_Sales
ADD OrderDateKey INT;

UPDATE Fact_Sales
SET OrderDateKey = CONVERT(INT, FORMAT([Order Date], 'yyyyMMdd'));

ALTER TABLE Fact_Sales
ADD CONSTRAINT FK_Fact_Sales_OrderDate
FOREIGN KEY (OrderDateKey)
REFERENCES Dim_Date (DateKey);

-- Créer View : Ventes par mois
DROP VIEW IF Exists vw_Sales_By_Month;
GO
CREATE VIEW vw_Sales_By_Month AS
SELECT
    d.YearNumber,
    d.MonthNumber,
    d.MonthName,
    SUM(f.Sales) AS Total_Sales
FROM dbo.Fact_Sales f
JOIN dbo.Dim_Date d
  ON f.OrderDateKey = d.DateKey
GROUP BY
    d.YearNumber,
    d.MonthNumber,
    d.MonthName;
GO

-- Créer View KPI globaux
DROP VIEW IF EXISTS vw_KPI_Global;
GO
CREATE VIEW vw_KPI_Global AS
SELECT
    SUM(Sales)                             AS [Total Sales],
    COUNT(DISTINCT [Order ID])             AS [Total Orders],
    COUNT(DISTINCT [Customer ID])          AS [Total Customers],
    SUM(Sales) / COUNT(DISTINCT [Order ID]) AS [Avg Order Value]
FROM dbo.Fact_Sales
GO

-- Créer View vw_Sales_By_Category
DROP VIEW IF EXISTS vw_Sales_By_Category;
GO
CREATE VIEW vw_Sales_By_Category AS
SELECT
    p.Category,
	p.[sub-Category] AS [Sub Category],
    SUM(f.Sales) AS [Total Sales]
FROM dbo.Fact_Sales f
JOIN dbo.Dim_Product p
  ON f.[Product ID] = p.[Product ID]
GROUP BY 
	p.Category, 
	p.[sub-Category];
GO

-- Créer View vw_Sales_By_State
DROP VIEW IF EXISTS vw_Sales_By_State;
GO
CREATE VIEW vw_Sales_By_State AS
SELECT
	f.Region,
    f.State,
    SUM(f.Sales)                    AS Total_Sales,
    COUNT(DISTINCT f.[Order ID])    AS Total_Orders,
    COUNT(DISTINCT f.[Customer ID]) AS Total_Customers
FROM Fact_Sales f
GROUP BY 
	f.Region,
	f.State;
GO

-- Créer View Sales by Customer
DROP VIEW IF EXISTS vw_Sales_By_Customer;

GO
CREATE VIEW vw_Sales_By_Customer AS
SELECT
    c.[Customer Name],
	c.Segment,
    SUM(f.Sales) AS [Total Sales]
FROM dbo.Fact_Sales f
JOIN dbo.Dim_Customer c
  ON f.[Customer ID] = c.[Customer ID]
GROUP BY 
	c.Segment,
	c.[Customer Name]
GO

-- Créer View RFM_Base
DROP VIEW IF EXISTS vw_RFM_Base

GO
CREATE VIEW vw_RFM_Base AS
SELECT
    f.[Customer ID],
    DATEDIFF(DAY, MAX(f.[Order Date]), '2018-12-31') AS Recency,
    COUNT(DISTINCT f.[Order ID])                         AS Frequency,
    SUM(f.Sales)                                         AS Monetary
FROM Fact_Sales f
GROUP BY f.[Customer ID];
GO

-- Créer View RFM_Score

DROP VIEW IF EXISTS vw_RFM_Score;
GO

CREATE VIEW vw_RFM_Score AS
    SELECT
        r.[Customer ID],
        r.Recency,
        r.Frequency,
        r.Monetary,
		-- Recency
        CASE
            WHEN r.Recency < 30 THEN 4
            WHEN r.Recency BETWEEN 30 AND 90 THEN 3
            WHEN r.Recency BETWEEN 91 AND 365 THEN 2
            ELSE 1
        END AS R_Score,

        -- Frequency
        CASE
            WHEN r.Frequency > 12 THEN 4
            WHEN r.Frequency BETWEEN 8 AND 12 THEN 3
            WHEN r.Frequency BETWEEN 4 AND 7 THEN 2
            ELSE 1
        END AS F_Score,

        -- Monetary
        CASE
            WHEN r.Monetary > 7500 THEN 4
            WHEN r.Monetary BETWEEN 2001 AND 7500 THEN 3
            WHEN r.Monetary BETWEEN 500 AND 2000 THEN 2
            ELSE 1
        END AS M_Score
    FROM vw_RFM_Base r;

GO
-- Créer View RFM_Segment
DROP VIEW IF EXISTS vw_RFM_Segment;

GO
CREATE VIEW vw_RFM_Segment AS
SELECT
    s.[Customer ID],
    s.Recency,
    s.Frequency,
    s.Monetary,
    s.R_Score,
    s.F_Score,
    s.M_Score,
    CONCAT(s.R_Score, s.F_Score, s.M_Score) AS RFM_Code,

	CASE
		WHEN s.R_Score = 4 AND s.F_Score >= 3 AND s.M_Score >= 3
			THEN 'Champions'

		WHEN s.R_Score >= 3 AND s.F_Score >= 3
			THEN 'Loyal Customers'

		WHEN s.R_Score = 4 AND s.F_Score <= 2
			THEN 'Recent Customers'

		WHEN s.R_Score = 1
			THEN 'Lost Customers'

		WHEN s.R_Score = 2 AND s.F_Score <= 2
			THEN 'At Risk'

		ELSE 'Need Attention'
	END AS RFM_Segment
FROM vw_RFM_Score s;
GO

select * from vw_RFM_Segment where RFM_Segment='Need Attention'



