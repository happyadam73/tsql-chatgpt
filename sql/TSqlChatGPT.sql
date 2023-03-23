--/	
--/ Product:			TSqlChatGPT
--/ Description:		Call ChatGPT from Azure SQL Database, and describe objects within the database
--/	
--/ Author:				Adam Buckley, Microsoft
--/ Creation Date:		March 2023
--/	
--/ Revision History:	1.2 (Generate tSQLt Unit Test proc added)
--/	
--/ 
--/ DISCLAIMER: 
--/ THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A 
--/ PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
--/ TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--/
--/ IMPORTANT: This will currently only work on Azure SQL Database (not on SQL Server or Azure SQL Managed Instance)
--/
--/ Provide your API key for OpenAI service (this is for OpenAI, not Azure OpenAI service)
--/ And also the subscription key for the Azure API Manager API
--/ The APIM URL Paramater needs to match the API Manager Service URL (e.g. https://<your APIM resource>.azure-api.net)
--/ Do a find/replace on <your APIM resource> and replace with the name of your APIM Service (this will then update the default parameters for the stored procs)
--/
--/ Usage Examples:
--/ 
--/		EXEC [dbo].[usp_AskChatGPT] 'Generate a CREATE TABLE script for Customer data';
--/		EXEC [dbo].[usp_AskChatGPT] 'Generate a SQL function to calculate how many days until a specified date';
--/		EXEC [dbo].[usp_AskChatGPT] 'Explain this code: SELECT DATEDIFF(DAY,GETDATE(),DATEFROMPARTS(2023,12,25))';
--/
--/		EXEC [dbo].[usp_ExplainObject] 'dbo.uspLogError';
--/		EXEC [dbo].[usp_ExplainObject] '[SalesLT].[vProductAndDescription]';
--/
--/		EXEC [dbo].[usp_GenerateTestDataForTable] '[SalesLT].[Address]'
--/
--/		EXEC [dbo].[usp_GenerateUnitTestForObject] 'dbo.ufnGetSalesOrderStatusText';
--/

DECLARE @openai_api_key			NVARCHAR(255) = 'sk-XXXXXXXXXXXXXXXXXXXXXXXXXXXX',
		@apim_subscription_key	NVARCHAR(255) = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
		@apim_url				NVARCHAR(255) = 'https://<your APIM resource name>.azure-api.net',
		@sql_cmd				NVARCHAR(MAX);

-- Create Database Master Key; it's Azure SQL DB, so no password required
IF NOT EXISTS(SELECT * FROM sys.symmetric_keys WHERE [name] = '##MS_DatabaseMasterKey##') 
    CREATE MASTER KEY;

-- Now drop any existing scoped credential (so we can refresh credentials if required)
IF EXISTS(SELECT * FROM sys.database_scoped_credentials WHERE [name] = @apim_url) 
BEGIN
	SET @sql_cmd = N'DROP DATABASE SCOPED CREDENTIAL [' + @apim_url + '];'
    EXEC sp_executesql @sql_cmd;
END

-- Now (re)create the Database Scoped Credential for the APIM Service
-- The OpenAI API hosted by this APIM wrapper needs a subscription key for access, as well as providing the 
-- OpenAI API key to be passed in as a bearer token for authorising the OpenAI request 
SET @sql_cmd = N'
CREATE DATABASE SCOPED CREDENTIAL [' + @apim_url + ']
WITH 
	IDENTITY = ''HTTPEndpointHeaders'', 
	SECRET = ''{"Authorization":"Bearer ' + @openai_api_key + '", "Ocp-Apim-Subscription-Key":"' + @apim_subscription_key + '"}'';
';
EXEC sp_executesql @sql_cmd;

-- Drop/Create proc to Print long strings (useful given size of response from ChatGPT)
IF EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND OBJECT_ID = OBJECT_ID('dbo.usp_PrintMax'))
    DROP PROCEDURE [dbo].[usp_PrintMax];
GO

CREATE PROCEDURE [dbo].[usp_PrintMax] 
    @message NVARCHAR(MAX)
AS 
-- Credit: https://stackoverflow.com/questions/7850477/how-to-print-varcharmax-using-print-statement
BEGIN
	DECLARE @severity			INT = 0,
			@start_pos			INT = 1,
			@end_pos			INT,
			@length				INT = LEN(@message),
			@sub_message		NVARCHAR(MAX),
			@cleaned_message	NVARCHAR(MAX) = REPLACE(@message,'%','%%');
 
	WHILE (@start_pos <= @length)
	BEGIN
		SET @end_pos = CHARINDEX(CHAR(13) + CHAR(10), @cleaned_message + CHAR(13) + CHAR(10), @start_pos);
		SET @sub_message = SUBSTRING(@cleaned_message, @start_pos, @end_pos - @start_pos);
		EXEC sp_executesql N'RAISERROR(@msg, @severity, 10) WITH NOWAIT;', N'@msg NVARCHAR(MAX), @severity INT', @sub_message, @severity;
		SELECT @start_pos = @end_pos + 2, @severity = 0; 
	END

	RETURN 0;
END;
GO

-- Drop/Create Proc to send request to ChatGPT API and extracts message from JSON response
IF EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND OBJECT_ID = OBJECT_ID('dbo.usp_AskChatGPT'))
    DROP PROCEDURE [dbo].[usp_AskChatGPT];
GO

CREATE PROCEDURE [dbo].[usp_AskChatGPT]
	@message		NVARCHAR(MAX),
	@response		NVARCHAR(MAX)   = NULL OUTPUT,
	@apim_url		NVARCHAR(255)	= N'https://<your APIM resource name>.azure-api.net',
	@timeout		INT				= 60,
	@print_response	BIT				= 1
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @request				NVARCHAR(MAX),
			@apim_openai_endpoint	NVARCHAR(1000),
			@sql_cmd				NVARCHAR(MAX);

	-- Configure APIM API endpoint
	SET @apim_openai_endpoint = @apim_url + N'/chat/completions';

	-- Now make sure the message is a single line; escape characters such as tab, newline and quote
	SET @message = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@message, N'"', N'\"'), N'''', N''''''), CHAR(9), N'\t'), CHAR(10), N'\n'), CHAR(13), N'\r')

	-- Inject the message into the request payload using the gpt-3.5 model
	SET @request = N'{"model": "gpt-3.5-turbo","messages": [{"role": "user", "content": "' + @message + '"}]}'

	-- Invoke APIM endpoint which wraps the OpenAI chat completion API 
	EXEC sp_invoke_external_rest_endpoint
		@url		= @apim_openai_endpoint
	  , @payload	= @request
	  , @method		= 'POST'
	  , @timeout	= @timeout
	  , @credential	= @apim_url
	  , @response	= @response OUTPUT

	-- Extract the message from the JSON response
	-- TODO: need error handling here to handle non-200 responses
	SELECT @response = JSON_VALUE(@response, '$.result.choices[0].message.content');

	-- Print response if required
	IF @print_response = 1
		EXEC [dbo].[usp_PrintMax] @response;

END;
GO

-- Drop/Create Proc to send request to ChatGPT API to explain code for specified function/proc/view within this database
IF EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND OBJECT_ID = OBJECT_ID('dbo.usp_ExplainObject'))
    DROP PROCEDURE [dbo].[usp_ExplainObject];
GO

CREATE PROCEDURE [dbo].[usp_ExplainObject]
	@object			NVARCHAR(512),
	@response		NVARCHAR(MAX)   = NULL OUTPUT,
	@apim_url		NVARCHAR(255)	= N'https://<your APIM resource name>.azure-api.net',
	@timeout		INT				= 60,
	@print_response	BIT				= 1
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @object_definition	NVARCHAR(MAX),
			@message			NVARCHAR(MAX);

	-- Get Object definition
    SELECT @object_definition = [definition]
    FROM sys.sql_modules
    WHERE object_id = OBJECT_ID(@object);

	-- Cleanup up object definition so it's single line and compliant for message request
	SET @object_definition = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@object_definition, N'"', N'\"'), N'''', N''''''), CHAR(9), N'\t'), CHAR(10), N'\n'), CHAR(13), N'\r')

	-- Generate message for ChatGPT
	SET @message = N'Explain this code:\n' + @object_definition

	-- Now Call the ChatGPT proc
	EXEC [dbo].[usp_AskChatGPT] 
	   @message			= @message
	  ,@response		= @response OUTPUT
	  ,@apim_url		= @apim_url
	  ,@timeout			= @timeout
	  ,@print_response	= @print_response;

END;
GO

-- Drop/Create Proc to generate a CREATE TABLE script based on the object name - this will include whether the column
-- is an identity column.  We need this CREATE TABLE script to help prompt ChatGPT for generating test data
IF EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND OBJECT_ID = OBJECT_ID('dbo.usp_Generate_Create_Table_Sql'))
    DROP PROCEDURE [dbo].[usp_Generate_Create_Table_Sql];
GO

CREATE PROCEDURE [dbo].[usp_Generate_Create_Table_Sql]
	@object_name		NVARCHAR(512),
	@create_table_sql	NVARCHAR(MAX)   = NULL OUTPUT
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @schema_name SYSNAME,
			@table_name SYSNAME,
			@columns_sql NVARCHAR(MAX);

	SELECT @schema_name = PARSENAME(@object_name, 2), @table_name = PARSENAME(@object_name, 1);

	SELECT @columns_sql = STRING_AGG(
	  '[' + c.name + '] ' + 
	  t.name + ' ' + 
	  CASE WHEN c.is_nullable = 1 THEN 'NULL' ELSE 'NOT NULL' END +
	  CASE WHEN c.is_identity = 1 THEN ' IDENTITY(1,1)' ELSE '' END
	  ,',') 
	FROM 
		sys.tables AS t
		INNER JOIN sys.columns AS c 
			ON t.object_id = c.object_id
	WHERE 
		t.name = @table_name AND 
		SCHEMA_NAME(t.schema_id) = @schema_name
	GROUP BY t.object_id;

	SET @create_table_sql = 'CREATE TABLE [' + @schema_name + '].[' + @table_name + '] (' + @columns_sql + ')';

END;
GO

-- Drop/Create Proc to send request to ChatGPT API to generate test data inserts for a specified table
IF EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND OBJECT_ID = OBJECT_ID('dbo.usp_GenerateTestDataForTable'))
    DROP PROCEDURE [dbo].[usp_GenerateTestDataForTable];
GO

CREATE PROCEDURE [dbo].[usp_GenerateTestDataForTable]
	@object			NVARCHAR(512),
	@response		NVARCHAR(MAX)   = NULL OUTPUT,
	@apim_url		NVARCHAR(255)	= N'https://<your APIM resource name>.azure-api.net',
	@timeout		INT				= 180,  -- longer default timeout for test data generation
	@num_records	INT				= 10,
	@print_response	BIT				= 1
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @create_table_sql	NVARCHAR(MAX),
			@message			NVARCHAR(MAX);

	-- Get CREATE TABLE script
	EXEC [dbo].[usp_Generate_Create_Table_Sql] 
	   @object_name = @object
	  ,@create_table_sql = @create_table_sql OUTPUT;

	-- Cleanup up script so it's single line and compliant for message request
	SET @create_table_sql = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@create_table_sql, N'"', N'\"'), N'''', N''''''), CHAR(9), N'\t'), CHAR(10), N'\n'), CHAR(13), N'\r')

	-- Generate message for ChatGPT
	SET @message = N'Generate a single SQL INSERT statement with ' + CAST(@num_records AS VARCHAR(10)) + ' test data records based on the following table script: ' + @create_table_sql;

	-- Now Call the ChatGPT proc
	EXEC [dbo].[usp_AskChatGPT] 
	   @message			= @message
	  ,@response		= @response OUTPUT
	  ,@apim_url		= @apim_url
	  ,@timeout			= @timeout
	  ,@print_response	= @print_response;

END;
GO

-- Drop/Create Proc to send request to ChatGPT API to generate a tSQLt Unit Test Proc for a specified function/proc/view within this database
IF EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND OBJECT_ID = OBJECT_ID('dbo.usp_GenerateUnitTestForObject'))
    DROP PROCEDURE [dbo].[usp_GenerateUnitTestForObject];
GO

CREATE PROCEDURE [dbo].[usp_GenerateUnitTestForObject]
	@object			NVARCHAR(512),
	@response		NVARCHAR(MAX)   = NULL OUTPUT,
	@apim_url		NVARCHAR(255)	= N'https://<your APIM resource name>.azure-api.net',
	@timeout		INT				= 90,
	@print_response	BIT				= 1
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @object_definition	NVARCHAR(MAX),
			@message			NVARCHAR(MAX);

	-- Get Object definition
    SELECT @object_definition = [definition]
    FROM sys.sql_modules
    WHERE object_id = OBJECT_ID(@object);

	-- Cleanup up object definition so it's single line and compliant for message request
	SET @object_definition = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(@object_definition, N'"', N'\"'), N'''', N''''''), CHAR(9), N'\t'), CHAR(10), N'\n'), CHAR(13), N'\r')

	-- Generate message for ChatGPT
	SET @message = N'Write a tSQLt Unit test stored procedure for the following:\n' + @object_definition

	-- Now Call the ChatGPT proc
	EXEC [dbo].[usp_AskChatGPT] 
	   @message			= @message
	  ,@response		= @response OUTPUT
	  ,@apim_url		= @apim_url
	  ,@timeout			= @timeout
	  ,@print_response	= @print_response;

END;
GO
