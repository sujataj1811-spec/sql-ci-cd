IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[dbo].[DatabaseLog]') AND type = 'U')
BEGIN
    CREATE TABLE [dbo].[DatabaseLog](
        Id INT IDENTITY(1,1) PRIMARY KEY,
        Message NVARCHAR(MAX),
        CreatedDate DATETIME DEFAULT GETDATE()
    )
END
GO