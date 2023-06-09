--/	
--/ Product:			TSqlChatGPTForAOAI
--/ Description:		Call ChatGPT from Azure SQL Database, and describe objects within the database
--/	
--/ Author:				Adam Buckley, Microsoft
--/ Creation Date:		June 2023
--/	
--/ Revision History:	1.0 
--/	
--/ 
--/ DISCLAIMER: 
--/ THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A 
--/ PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
--/ TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
--/
--/ IMPORTANT: This will currently only work on Azure SQL Database (not on SQL Server or Azure SQL Managed Instance)
--/
--/ PRE-REQUISITES:
--/ You will need an Azure OpenAI resource deployed, and within that resource a Chat GPT model needs to be deployed (e.g. gpt-35-turbo).
--/
--/ INSTRUCTIONS:
--/ 
--/ STEP 1: Configure the @azure_openai_api_key with either the primary or secondary Azure OpenAI key (you can find these keys in the Azure Portal in the "Keys and Endpoint" menu of the Azure OpenAI resource)
--/ STEP 2: Configure the @azure_openai_endpoint with the Endpoint URL (endpoint is found in the same place as the API keys)
--/ STEP 3: Configure the @chatgpt_deployment_name with the name of the deployment of the ChatGPT model to use, i.e. gpt-35-turbo - note this is DEPLOYMENT name, not model name (you can configure this in the Azure AI Studio)
--/ STEP 4: Optional step - customise the @system_message parameter to guide the behaviour of the ChatGPT agent.
--/
--/ Usage Examples:
--/ 
--/		EXEC [dbo].[usp_AskChatGPT] 'Generate a product table for a fashion retailer';
--/		EXEC [dbo].[usp_AskChatGPT] 'Generate a function to calculate how many days until a specified date';
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

DECLARE @azure_openai_api_key		VARCHAR(50)  = 'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
		@azure_openai_endpoint		VARCHAR(255) = 'https://<your Azure OpenAI resource name>.openai.azure.com/',
		@chatgpt_deployment_name	VARCHAR(255) = 'gpt-35-turbo',
		@sql_cmd					NVARCHAR(MAX);

-- (OPTIONAL): Customise your chat agent here
DECLARE @system_message NVARCHAR(MAX) = N'
You are a helpful database administrator and developer.  
Your responses should always be for Transact SQL (or T-SQL).  
When asked to generate a database object, you should generate the T-SQL script required to do this.  
All T-SQL scripts should be formatted in the same way including data types are capitalised, column names are enclosed in square brackets.  
For scripts containing a CREATE statement, make sure the script includes a check to see if that object already exists.  
Only create the object if it doesn''t exist.  
Scripts should only use dynamic SQL if required.  
Try to avoid using sp_executesql.
';

-- Create Database Master Key; it's Azure SQL DB, so no password required
IF NOT EXISTS(SELECT * FROM sys.symmetric_keys WHERE [name] = '##MS_DatabaseMasterKey##') 
    CREATE MASTER KEY;

-- Trim any trailing / character from the Azure OpenAI endpoint
SELECT @azure_openai_endpoint = RTRIM(@azure_openai_endpoint,'/');

-- Now drop any existing scoped credential (so we can refresh credentials if required)
IF EXISTS(SELECT * FROM sys.database_scoped_credentials WHERE [name] = @azure_openai_endpoint) 
BEGIN
	SET @sql_cmd = N'DROP DATABASE SCOPED CREDENTIAL [' + @azure_openai_endpoint + '];'
    EXEC sp_executesql @sql_cmd;
END

-- Now (re)create the Database Scoped Credential for the Azure OpenAI Service
SET @sql_cmd = N'
CREATE DATABASE SCOPED CREDENTIAL [' + @azure_openai_endpoint + ']
WITH 
	IDENTITY = ''HTTPEndpointHeaders'', 
	SECRET = ''{"api-key": "' + @azure_openai_api_key + '"}'';
';
EXEC sp_executesql @sql_cmd;

-- We need to reference the Azure OpenAI scoped credential in various procs, so create a 'global' default that other procs/functions can use if not provided
-- Do this by creating a UDF based on the @azure_openai_endpoint parameter above
SET @sql_cmd = N'
CREATE OR ALTER FUNCTION dbo.AzureOpenAICredential()
RETURNS SYSNAME AS
BEGIN
	RETURN N''' + @azure_openai_endpoint + ''';
END
';
EXEC sp_executesql @sql_cmd;

-- We need to reference the Azure OpenAI chat completion endpoint URL in various procs, so create a 'global' endpoint default that other procs/functions can use if not provided
-- Do this by creating a UDF based on the @azure_openai_endpoint and chat deployment parameters above
SET @sql_cmd = N'
CREATE OR ALTER FUNCTION dbo.AzureOpenAIChatEndpointUrl()
RETURNS NVARCHAR(255) AS
BEGIN
	RETURN N''' + @azure_openai_endpoint + '/openai/deployments/' + @chatgpt_deployment_name + '/chat/completions?api-version=2023-03-15-preview'';
END
';
EXEC sp_executesql @sql_cmd;

-- System Message function so that this can be referenced from other procs/functions
SET @sql_cmd = N'
CREATE OR ALTER FUNCTION dbo.AzureOpenAIChatSystemMessage()
RETURNS NVARCHAR(MAX) AS
BEGIN
	RETURN N''' + STRING_ESCAPE(REPLACE(REPLACE(REPLACE(REPLACE(@system_message, N'''', N''''''), CHAR(9), N'\t'), CHAR(10), N'\n'), CHAR(13), N'\r'), 'json') + ''';
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
	@chat_endpoint	NVARCHAR(255)	= NULL,  -- If not provided, then default value retrieved using dbo.AzureOpenAIChatEndpointUrl()
	@timeout		INT				= 60,
	@print_response	BIT				= 1
AS
BEGIN
	SET NOCOUNT ON;

	BEGIN TRY
		DECLARE @request				NVARCHAR(MAX),
				@credential				SYSNAME,
				@sql_cmd				NVARCHAR(MAX),
				@status_code			INT,
				@system_message			NVARCHAR(MAX),
				@status_description		NVARCHAR(4000);

		-- If no Chat endpoint URL provided, then set to default
		SELECT @chat_endpoint = ISNULL(@chat_endpoint, dbo.AzureOpenAIChatEndpointUrl());

		-- Get scoped credential name
		SELECT @credential = dbo.AzureOpenAICredential();

		-- Get System Message 
		SELECT @system_message = ISNULL(dbo.AzureOpenAIChatSystemMessage(),'You are an AI assistant that helps people find information.');

		-- Now make sure the message is a single line; escape characters such as tab, newline and quote, and escape characters to ensure valid JSON
		SET @message = STRING_ESCAPE(REPLACE(REPLACE(REPLACE(REPLACE(@message, N'''', N''''''), CHAR(9), N'\t'), CHAR(10), N'\n'), CHAR(13), N'\r'), 'json');

		-- Inject the message into the request payload using the gpt-3.5 model
		SET @request = N'{"messages": [{"role": "system", "content": "' + @system_message + '"},{"role": "user", "content": "' + @message + '"}]}';

		-- Invoke AOAI Chat Completion endpoint 
		EXEC sp_invoke_external_rest_endpoint
			@url		= @chat_endpoint
		  , @payload	= @request
		  , @method		= 'POST'
		  , @timeout	= @timeout
		  , @credential	= @credential
		  , @response	= @response OUTPUT

		-- Check for a JSON response
		IF (@response IS NULL) OR ISNULL(ISJSON(@response),0) = 0
			THROW 50000, 'Calling the Azure OpenAI service did not return a valid JSON response', 1;

		-- See if an Error Message has been returned
		SELECT @status_description = JSON_VALUE(@response, '$.result.error.message');
		IF @status_description IS NOT NULL
			THROW 50000, @status_description, 1;

		-- Get the Response Status Code
		SELECT @status_code = JSON_VALUE(@response, '$.response.status.http.code');

		-- Check Status Code and Description are found in the response
		IF (@status_code IS NULL)
			THROW 50000, 'The Azure OpenAI service failed to return an HTTP Status Code in the response', 1;
			
		-- Check if Status Code is 200 (OK) - if not then throw error
		IF @status_code <> 200
		BEGIN
			SET @status_description = JSON_VALUE(@response, '$.result.message');
			THROW 50000, @status_description, 1;
		END

		-- Extract the message from the JSON response
		SELECT @response = JSON_VALUE(@response, '$.result.choices[0].message.content');
		IF @response IS NULL
			THROW 50000, 'It was not possible to extract a message response from the Azure OpenAI Chat API', 1;

		-- Print response if required
		IF @print_response = 1
			EXEC [dbo].[usp_PrintMax] @response;

	END TRY
	BEGIN CATCH

		DECLARE @error_message	NVARCHAR(4000)	= ERROR_MESSAGE(),
				@error_severity	INT				= ERROR_SEVERITY(),
				@error_state	INT				= ERROR_STATE();

		RAISERROR (@error_message, @error_severity, @error_state);

	END CATCH

END;
GO

-- Drop/Create Proc to validate an object exists in the database
IF EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND OBJECT_ID = OBJECT_ID('dbo.usp_ValidateObjectExists'))
    DROP PROCEDURE [dbo].[usp_ValidateObjectExists];
GO

CREATE PROCEDURE [dbo].[usp_ValidateObjectExists]
	@object NVARCHAR(512)
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @object_id	INT = OBJECT_ID(@object),
			@message	NVARCHAR(500);

	IF @object_id IS NULL
	BEGIN
		IF @object IS NULL 
			SET @message = N'No object has been specified';
		ELSE
			SET @message = N'The object ' + @object + ' either does not exist or you do not have permissions to retrieve the definition';

		THROW 50000, @message, 1;
	END
END;
GO

-- Drop/Create Proc to validate an object exists in the database
IF EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND OBJECT_ID = OBJECT_ID('dbo.usp_ValidateObjectHasDefinition'))
    DROP PROCEDURE [dbo].[usp_ValidateObjectHasDefinition];
GO

CREATE PROCEDURE [dbo].[usp_ValidateObjectHasDefinition]
	@object NVARCHAR(512)
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @object_definition	NVARCHAR(MAX),
			@message			NVARCHAR(MAX);

	-- Validate object exists 
	EXEC [dbo].[usp_ValidateObjectExists] @object;

	-- Get Object definition
    SELECT @object_definition = [definition]
    FROM sys.sql_modules
    WHERE object_id = OBJECT_ID(@object);

	IF @object_definition IS NULL
	BEGIN
		SET @message = N'The object ' + @object + ' definition cannot be found - object should be function, stored procedure or view, but not table';
		THROW 50000, @message, 1;
	END
END;
GO

-- Drop/Create Proc to send request to ChatGPT API to explain code for specified function/proc/view within this database
IF EXISTS (SELECT * FROM sys.objects WHERE type = 'P' AND OBJECT_ID = OBJECT_ID('dbo.usp_ExplainObject'))
    DROP PROCEDURE [dbo].[usp_ExplainObject];
GO

CREATE PROCEDURE [dbo].[usp_ExplainObject]
	@object			NVARCHAR(512),
	@response		NVARCHAR(MAX)   = NULL OUTPUT,
	@aoai_endpoint	NVARCHAR(255)	= NULL,  -- If not provided, then default value retrieved using dbo.AzureOpenAIChatEndpointUrl()
	@timeout		INT				= 60,
	@print_response	BIT				= 1
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @object_definition	NVARCHAR(MAX),
			@message			NVARCHAR(MAX);

	-- Validate object definition exists 
	EXEC [dbo].[usp_ValidateObjectHasDefinition] @object;

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
	  ,@chat_endpoint	= @aoai_endpoint
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

	-- Validate object exists 
	EXEC [dbo].[usp_ValidateObjectExists] @object_name;

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
	@aoai_endpoint	NVARCHAR(255)	= NULL,  -- If not provided, then default value retrieved using dbo.AzureOpenAIChatEndpointUrl()
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
	  ,@chat_endpoint	= @aoai_endpoint
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
	@aoai_endpoint	NVARCHAR(255)	= NULL,  -- If not provided, then default value retrieved using dbo.AzureOpenAIChatEndpointUrl()
	@timeout		INT				= 90,
	@print_response	BIT				= 1
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @object_definition	NVARCHAR(MAX),
			@message			NVARCHAR(MAX);

	-- Validate object definition exists 
	EXEC [dbo].[usp_ValidateObjectHasDefinition] @object;
	
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
	  ,@chat_endpoint	= @aoai_endpoint
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
	@aoai_endpoint	NVARCHAR(255)	= NULL,  -- If not provided, then default value retrieved using dbo.AzureOpenAIChatEndpointUrl()
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
	  ,@chat_endpoint	= @aoai_endpoint
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
