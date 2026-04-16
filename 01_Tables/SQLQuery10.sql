-- 1. Create Table
CREATE TABLE EmployeeDemo (
    Id INT PRIMARY KEY,
    Name VARCHAR(100)
);

-- 2. Add Column
ALTER TABLE EmployeeDemo
ADD Age INT;

-- 3. Insert Record (with new column)
INSERT INTO EmployeeDemo (Id, Name, Age)
VALUES (1, 'Sujata', 25);

-- Check data
SELECT * FROM EmployeeDemo;

-- 4. Add Another Column
ALTER TABLE EmployeeDemo
ADD City VARCHAR(100);

-- 5. Insert Record Again (with new column)
INSERT INTO EmployeeDemo (Id, Name, Age, City)
VALUES (2, 'Rahul', 30, 'Mumbai');

-- Check data
SELECT * FROM EmployeeDemo;

-- 6. Drop Column
ALTER TABLE EmployeeDemo
DROP COLUMN Age;

-- Final check
SELECT * FROM EmployeeDemo;