--/	
--/ Product:			TSqlChatGPT
--/ Description:		Call ChatGPT from Azure SQL Database, and describe objects within the database
--/	
--/ Author:				Adam Buckley, Microsoft
--/ Creation Date:		March 2023
--/	
--/ Revision History:	1.4 (Error handling improved, and no longer need to find/replace APIM URL)
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
--/ The APIM URL Paramater needs to match the API Manager Service URL (e.g. https://myapimanagerresourcename.azure-api.net)
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
--/		EXEC [dbo].[usp_DescribeTableColumns] '[SalesLT].[SalesOrderDetail]';
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

-- We need to reference the APIM URL in various procs, so rather create 'global' APIM URL default that other procs/functions can use if not provided
-- Do this by creating a UDF based on the @apim_url parameter above
SET @sql_cmd = N'
CREATE OR ALTER FUNCTION dbo.ApiManagementInstanceUrl()
RETURNS NVARCHAR(255) AS
BEGIN
	RETURN N''' + @apim_url + ''';
END
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
	@apim_url		NVARCHAR(255)	= NULL,  -- If not provided, then default value retrieved using dbo.ApiManagementInstanceUrl()
	@timeout		INT				= 60,
	@print_response	BIT				= 1
AS
BEGIN
	SET NOCOUNT ON;

	BEGIN TRY
		DECLARE @request				NVARCHAR(MAX),
				@apim_openai_endpoint	NVARCHAR(1000),
				@sql_cmd				NVARCHAR(MAX),
				@status_code			INT,
				@status_description		NVARCHAR(4000);

		-- If no APIM URL provided, then set to default
		SELECT @apim_url = ISNULL(@apim_url, dbo.ApiManagementInstanceUrl())

		-- Configure APIM API endpoint
		SET @apim_openai_endpoint = @apim_url + N'/chat/completions';

		-- Now make sure the message is a single line; escape characters such as tab, newline and quote, and escape characters to ensure valid JSON
		SET @message = STRING_ESCAPE(REPLACE(REPLACE(REPLACE(REPLACE(@message, N'''', N''''''), CHAR(9), N'\t'), CHAR(10), N'\n'), CHAR(13), N'\r'), 'json');

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

		-- Check for a JSON response
		IF (@response IS NULL) OR ISNULL(ISJSON(@response),0) = 0
			THROW 50000, 'Calling the API Management service did not return a valid JSON response', 1;

		-- See if an Error Message has been returned
		SELECT @status_description = JSON_VALUE(@response, '$.result.error.message');
		IF @status_description IS NOT NULL
			THROW 50000, @status_description, 1;

		-- Get the Response Status Code
		SELECT @status_code = JSON_VALUE(@response, '$.response.status.http.code');

		-- Check Status Code and Description are found in the response
		IF (@status_code IS NULL)
			THROW 50000, 'The API Management service failed to return an HTTP Status Code in the response', 1;
			
		-- Check if Status Code is 200 (OK) - if not then throw error
		IF @status_code <> 200
		BEGIN
			SET @status_description = JSON_VALUE(@response, '$.result.message');
			THROW 50000, @status_description, 1;
		END

		-- Extract the message from the JSON response
		SELECT @response = JSON_VALUE(@response, '$.result.choices[0].message.content');
		IF @response IS NULL
			THROW 50000, 'It was not possible to extract a message response from the OpenAI Chat API', 1;

		-- Print response if required
		IF @print_response = 1
			EXEC [dbo].[usp_PrintMax] @response;
	END TRY
	BEGIN CATCH

		DECLARE @error_message	NVARCHAR(4000)	= ERROR_MESSAGE(),
				@error_severity	INT				= ERROR_SEVERITY(),
				@error_state	INT				= ERROR_STATE();

		-- Check the URL is valid; likely to be invalid if someone has forgotten to configure the API management instance properly
		IF ERROR_NUMBER() = 31614
			SET @error_message = N'The API Management Instance URL is invalid - it should look something like: https://apimanagementresourcename.azure-api.net'

		RAISERROR (@error_message, @error_severity, @error_state);

	END CATCH
END;
GO

-- Drop/Create Proc to send request to ChatGPT API to explain code for specified function/proc/view within this database
IF EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND OBJECT_ID = OBJECT_ID('dbo.usp_ExplainObject'))
    DROP PROCEDURE [dbo].[usp_ExplainObject];
GO

CREATE PROCEDURE [dbo].[usp_ExplainObject]
	@object			NVARCHAR(512),
	@response		NVARCHAR(MAX)   = NULL OUTPUT,
	@apim_url		NVARCHAR(255)	= NULL,  -- If not provided, then default value retrieved using dbo.ApiManagementInstanceUrl()
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
	@apim_url		NVARCHAR(255)	= NULL,  -- If not provided, then default value retrieved using dbo.ApiManagementInstanceUrl()
	@timeout		INT				= 180,   -- longer default timeout for test data generation
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
	@apim_url		NVARCHAR(255)	= NULL,  -- If not provided, then default value retrieved using dbo.ApiManagementInstanceUrl()
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


-- Drop/Create Proc to send request to ChatGPT API to generate column level descriptions for a specified table
IF EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND OBJECT_ID = OBJECT_ID('dbo.usp_DescribeTableColumns'))
    DROP PROCEDURE [dbo].[usp_DescribeTableColumns];
GO

CREATE PROCEDURE [dbo].[usp_DescribeTableColumns]
	@object			NVARCHAR(512),
	@response		NVARCHAR(MAX)   = NULL OUTPUT,
	@apim_url		NVARCHAR(255)	= NULL,  -- If not provided, then default value retrieved using dbo.ApiManagementInstanceUrl()
	@timeout		INT				= 120,
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
	SET @message = N'Describe each column in the following table: ' + @create_table_sql;

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
IF EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND OBJECT_ID = OBJECT_ID('dbo.usp_ExplainAllStoredProcsInDB'))
    DROP PROCEDURE [dbo].[usp_ExplainAllStoredProcsInDB];
GO

/* Explained by ChatGPT3
This is a stored procedure in SQL Server named usp_ExplainAllStoredProcsInDB that retrieves the definitions of all stored procedures in the database and excludes certain procedures.
The stored procedure declares several variables, including @ProcName to hold the name of each stored procedure, @ProcDef to hold the definition of each stored procedure, and @ProcGPT to hold the definition of each stored procedure annotated by ChatGPT.
The stored procedure opens a cursor named procCursor to loop through each stored procedure's name and definition. Inside the loop, it checks whether the stored procedure definition is already annotated by ChatGPT using the LIKE operator, which returns a TRUE value if the string being searched for exists in the @ProcDef variable.
If the stored procedure definition is not already annotated by ChatGPT, the stored procedure calls another stored procedure named usp_ExplainObject to generate the annotated definition in the @ProcGPT variable. Then, the stored procedure updates the definition by adding the ChatGPT annotation to the beginning and end of the @ProcGPT variable and replaces "CREATE PROCEDURE" with "ALTER PROCEDURE" to create an update statement instead.
The stored procedure then checks whether the @UpdateProcedures parameter is set to 1 (true), which means it will automatically update the stored procedures with the annotated definition. If it is set to 0 (false), the stored procedure will just return the annotated definition along with the original definition.
If the stored procedure definition is already annotated by ChatGPT, it skips it and moves to the next stored procedure.
Finally, the stored procedure returns a list of stored procedures with their original definition and either the updated or annotated definition, depending on whether the @UpdateProcedures parameter is set to 1 or 0.
*/

CREATE PROCEDURE [dbo].[usp_ExplainAllStoredProcsInDB]

	@UpdateProcedures bit = 1 -- Switch to automatically update stored procedures

AS
BEGIN
	DECLARE @ProcName	nvarchar(max);
	DECLARE @ProcDef	nvarchar(max);
	DECLARE @ProcGPT	nvarchar(max);
	DECLARE @ProcSuffix	varchar(3) = 'gpt';

	-- Get all stored procedures and exclude chatgpt code
	DECLARE procCursor CURSOR FOR
		select name, object_definition(object_id) from sys.objects
		where type = 'P'
		and name not in ('usp_Generate_Create_Table_Sql', 'usp_AskChatGPT', 'usp_ExplainObject', 
		'usp_PrintMax', 'usp_GenerateTestDataForTable', 'usp_GenerateUnitTestForObject', 'usp_DescribeTableColumns');

	OPEN procCursor;

	FETCH NEXT FROM procCursor INTO @ProcName, @ProcDef;
	WHILE @@FETCH_STATUS = 0
	BEGIN

		IF NOT LEFT(@ProcDef , LEN('/* Explained by ChatGPT3')) LIKE '/* Explained by ChatGPT3'
		BEGIN
			EXEC [dbo].[usp_ExplainObject] @object = @ProcName, @response = @ProcGPT OUTPUT;
			SELECT @ProcGPT = '/* Explained by ChatGPT3' + CHAR(13) + @ProcGPT + CHAR(13) + '*/' + REPLACE(@ProcDef, 'CREATE PROCEDURE', 'ALTER PROCEDURE')
		
			IF @UpdateProcedures = 1  
			BEGIN
				EXEC sp_executeSQL @ProcGPT;
				SELECT 'Stored Procedure Altered : ' + @ProcName as Status, @ProcDef as Original, @ProcGPT as Updatedto;
			END;
			ELSE
			BEGIN
				SELECT 'Stored Procedure Explain: ' + @ProcName as Status, @ProcDef as Original, @ProcGPT as WithExplain;
			END;
		END;
		ELSE
		BEGIN
				SELECT 'Stored Procedure skipped (already explained): ' + @ProcName as Status, @ProcDef as Original, @ProcDef as WithExplain;
		
		END;

		FETCH NEXT FROM procCursor INTO @procName, @procDef;
	END;
	CLOSE procCursor;
	DEALLOCATE procCursor;
END;
GO
