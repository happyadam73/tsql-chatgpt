# Step-by-Step Guide to Deploying TSqlChatGPT

> ChatGPT integration relies on `sp_invoke_external_rest_endpoint` which is currently only available for Azure SQL Database (Public Preview)

TSqlChatGPT requires a Chat-based Large Language Model (LLM) - this guide provides two different options to do this:
- Use an **Azure** OpenAI Service - this is the simplest and cheapest method for trying TSqlChatGPT
- Use the OpenAI Service (non-Azure) - this is a more involved setup requiring API Manager, and will incur additional cost as detailed below.


# Option 1: Deploying TSqlChatGPT with Azure OpenAI

> **Note**
> Expected costs for running this demonstration are around $1/day:
> - Azure SQL Database (Standard S0): ~ $20/month
> - Azure OpenAI Service (> 100K tokens/day): ~$10/month

## Pre-requisites

- If you haven't done so already, you will need to sign up for the Azure OpenAI Service: https://learn.microsoft.com/en-us/azure/ai-services/openai/overview#how-do-i-get-access-to-azure-openai.  
- You will also need an Azure SQL Database to run the SQL script and to test the ChatGPT integration.  If you don't already have an existing Azure SQL DB or you wish to create a sample Database for this exercise, then follow the optional step below and click on the "Deploy to Azure" button.

### OPTIONAL: Deploy the AdventureWorksLT Sample Database
Click on the button below to deploy a new Azure SQL database using the AdventureWorksLT sample data.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fhappyadam73%2Ftsql-chatgpt%2Fmain%2Fazuresqldb%2Fazuredeploy.json)

## 1. Create a Model Deployment in Azure OpenAI
If you haven't done so already, create an Azure OpenAI resource from the Azure Portal.  Be aware that different versions of models are available in different regions - check the following documentation to see which regions support the GPT 3.5 models used to support TSqlChatGPT: https://learn.microsoft.com/en-us/azure/ai-services/openai/concepts/models#gpt-35-models

If you haven't already deployed a GPT model, then navigate to Azure AI Studio (https://oai.azure.com/), select Models from the left menu, select one of the base models (for example gpt-3.5-turbo) and click on the Deploy button.  Provide the deployment a name (you'll need to make a note of this for the T-SQL script later) - typically use the model name as the deployment name and click on the Create button as shown below:

![Azure AI Studio](./assets/aistudio.png)

## 2. Get the Azure OpenAI API Key and Endpoint
Navigate to the Azure OpenAI resource in the Azure Portal and click on the "Keys and Endpoint" menu as shown below.

Make a note of either of the API Keys somewhere safe (do not share) as well as the Endpoint - you will need to add these to the SQL script in the next step.

![Azure OpenAI Service API Keys and Endpoint](./assets/aoaikeys.png)

## 3. Run the TSqlChatGPTForAOAI SQL Script

> Use either [SQL Management Studio](https://learn.microsoft.com/en-us/sql/ssms/download-sql-server-management-studio-ssms) or [Azure Data Studio](https://learn.microsoft.com/en-us/sql/azure-data-studio/download-azure-data-studio) to run the ChatGPT SQL commands - most responses will be displayed in the Messages tab and this may not work correctly in other client applications (such as the Query Preview feature in the Azure Portal)

Open SSMS or Azure Data Studio and connect to your Azure SQL Database - either download and open the TSqlChatGPTForAOAI.sql file (from the sql folder) or copy the contents to a new query window.

At the top of the script, replace the following:

- Paste your Azure OpenAI API Key in the `@azure_openai_api_key` variable
- Paste your Azure OpenAI Endpoint in the `@azure_openai_endpoint` variable
- Paste the deployment (not model) name for your ChatGPT model in the `@chatgpt_deployment_name` variable
- OPTIONAL: Modify or enhance the system message in `@system_message` variable to fine-tune the model responses

The SQL Script should look similar to the screenshot below - once you've pasted in the parameter values, run the script.

![SSMS SQL Script for Azure OpenAI Deployment](./assets/ssms2.png)


# Option 2: Deploying TSqlChatGPT using common OpenAI Service (non-Azure)

> **Note**
> Expected costs for running this demonstration are around $2.30/day:
> - Azure SQL Database (Standard S0): ~ $20/month
> - Azure API Management (Developer SKU): ~ $50/month
> - OpenAI Costs not included (but may be covered by Free/ChatGPT Plus subscriptions)


## Pre-requisites

- If you haven't done so already, you will need to sign up for a free OpenAI account in order to generate the required API key: https://platform.openai.com/signup.  Once registered, select "View API Keys" from the Account menu and create a new secret key.  Keep a copy somewhere safe (don't share) - you will need to use this in the provided SQL script.
- You will also need an Azure SQL Database to run the SQL script and to test the ChatGPT integration.  If you don't already have an existing Azure SQL DB or you wish to create a sample Database for this exercise, then follow the optional step below and click on the "Deploy to Azure" button.

### OPTIONAL: Deploy the AdventureWorksLT Sample Database
Click on the button below to deploy a new Azure SQL database using the AdventureWorksLT sample data.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fhappyadam73%2Ftsql-chatgpt%2Fmain%2Fazuresqldb%2Fazuredeploy.json)


## 1. Setup the Azure API Management Service and OpenAI API

> The `sp_invoke_external_rest_endpoint` can only make calls to certain safe-listed Azure Services.  In order to call the OpenAI APIs, we need to create a wrapper API within an Azure API Management Instance.

To deploy a new Azure API Management Instance with an OpenAI API, click on the button below.

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fhappyadam73%2Ftsql-chatgpt%2Fmain%2Fapim%2Fazuredeploy.json)

Make a note of the name of the Azure API Management Service - this will need to be copied into the SQL script described below and is the basis for both the Database Credentials object and any API URL endpoints.

**Note:** The API Management Service can take up to an hour to provision.

## 2. Get the API Management API Subscription Key

Once the API Management Service deployment has completed, navigate to the API Management resource and click on the Subscriptions menu option.

The deployment has created a subscription key for the OpenAI API - click on the three dots to the right of this subscription and click on Show/Hide keys as shown below.  

Make a note of this subscription key somewhere safe (do not share) - you will need to add this to the SQL script.

![Get Subscription Key](./assets/apimsubscription.png)

## 3. Run the TSqlChatGPT SQL Script

> Use either [SQL Management Studio](https://learn.microsoft.com/en-us/sql/ssms/download-sql-server-management-studio-ssms) or [Azure Data Studio](https://learn.microsoft.com/en-us/sql/azure-data-studio/download-azure-data-studio) to run the ChatGPT SQL commands - most responses will be displayed in the Messages tab and this may not work correctly in other client applications (such as the Query Preview feature in the Azure Portal)

Open SSMS or Azure Data Studio and connect to your Azure SQL Database - either download and open the TSqlChatGPT.sql file (from the sql folder) or copy the contents to a new query window.

At the top of the script, replace the following:

- Paste your OpenAI API Key in the `@openai_api_key` variable
- Paste your API Management Subscription Key in the `@apim_subscription_key` variable
- Paste the name of your API Management Service in the `@apim_url` variable

The SQL Script should look similar to the screenshot below - once you've pasted in the correct keys, run the script.

![SSMS SQL Script](./assets/ssms.png)

# How to use TSqlChatGPT

Currently there are 6 stored procedures to try:
- `dbo.usp_AskChatGPT` - send any message to ChatGPT and get a response (remember ChatGPT does not have any context with regards to your database objects)
- `dbo.usp_ExecuteNaturalQuery` - query your database using natural language rather than SQL (Warning! AI Generated SQL should not be run unchecked on Production databases!)
- `dbo.usp_ExplainObject` - sends the object definition of any function/procedure/view and returns an explanation of the code (or view)
- `dbo.usp_GenerateTestDataForTable` - sends ChatGPT a CREATE table script based on the table you specify, and asks for an INSERT statement to be generated with test data records
- `dbo.usp_GenerateUnitTestForObject` - sends the object definition of any function/procedure/view and generates a tSQLt Unit Test Stored Procedure for testing the object
- `dbo.usp_DescribeTableColumns` - sends ChatGPT a CREATE table script based on the table you specify, and asks for a description of each column

> **Warning**
> It is recommended to avoid use of these procedures on production systems, or any database containing sensitive or private data.  In the case of the last 4 procedures, the definition of your tables or code for your objects is sent to the OpenAI API (via your API Management Instance).  Only Code and table schemas are sent to ChatGPT - no data is ever sent to ChatGPT.

## Examples with sample outputs
The following are some simple examples you can try with TSqlChatGPT.  It can useful sometimes to ask for a T-SQL script to avoid statements that aren't supported by SQL Server.

### `dbo.usp_AskChatGPT` Examples
```sql
EXEC [dbo].[usp_AskChatGPT] 'Generate a CREATE TABLE script for Customer data';

EXEC [dbo].[usp_AskChatGPT] 'Generate a SQL function to calculate how many days until a specified date';

EXEC [dbo].[usp_AskChatGPT] 'Explain this code: SELECT DATEDIFF(DAY,GETDATE(),DATEFROMPARTS(2023,12,25))';
```
![Example 1](./assets/example1.png)

### `dbo.usp_ExecuteNaturalQuery` Examples
```sql
EXEC [dbo].[usp_ExecuteNaturalQuery] 'Return a 7-day rolling average number of sales grouped by territory, product and date ordered by date for any sales in 2012';

EXEC [dbo].[usp_ExecuteNaturalQuery] 'Which promotions, excluding "No Discount", had the largest total sales in the second quarter of 2012';

EXEC [dbo].[usp_ExecuteNaturalQuery] 'Who were the top 10 performing resellers in 2011';
```
![Example 6](./assets/example6.png)

### `dbo.usp_ExplainObject` Examples
```sql
EXEC [dbo].[usp_ExplainObject] 'dbo.uspLogError';

EXEC [dbo].[usp_ExplainObject] '[SalesLT].[vProductAndDescription]';
```
![Example 2](./assets/example2.png)

### `dbo.usp_GenerateTestDataForTable` Examples
```sql
EXEC [dbo].[usp_GenerateTestDataForTable] 'SalesLT.ProductCategory';

EXEC [dbo].[usp_GenerateTestDataForTable] '[SalesLT].[Address]';
```

![Example 3](./assets/example3.png)

### `dbo.usp_GenerateUnitTestForObject` Examples
```sql
EXEC [dbo].[usp_GenerateUnitTestForObject] 'dbo.uspLogError';

EXEC [dbo].[usp_GenerateUnitTestForObject] 'dbo.ufnGetSalesOrderStatusText';
```

![Example 4](./assets/example4.png)

### `dbo.usp_DescribeTableColumns` Examples
```sql
EXEC [dbo].[usp_DescribeTableColumns] 'SalesLT.SalesOrderDetail';

EXEC [dbo].[usp_DescribeTableColumns] '[SalesLT].[Address]';
```

![Example 5](./assets/example5.png)

### `dbo.usp_ExplainAllStoredProcsInDB` Examples
```sql
EXEC [dbo].[usp_ExplainAllStoredProcsInDB] 1; -- Replace all stored procs with explaine dversions
EXEC [dbo].[usp_ExplainAllStoredProcsInDB] 0; -- Get all stored procedures and present samples of explain for each
```

## Is TSqlChatGPT self-aware?  
Not really, but it can explain itself!  
Try the following and see what you get:

```sql
EXEC [dbo].[usp_ExplainObject] '[dbo].[usp_AskChatGPT]';
```

Hopefully, it looks something like below:

![SSMS SQL Script](./assets/selfaware.png)
