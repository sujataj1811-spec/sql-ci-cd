/****** Object:  Table [dbo].[tblTransaction]    Script Date: 18-04-2026 01:28:38 ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[tblTransaction](
	[Amount] [smallmoney] NOT NULL,
	[DateOfTransaction] [smalldatetime] NOT NULL,
	[EmployeeNumber] [int] NOT NULL
) ON [PRIMARY]
GO

