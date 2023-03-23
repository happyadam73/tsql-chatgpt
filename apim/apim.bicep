@description('The name of the API Management service instance')
param apiManagementServiceName string = 'apiservice${uniqueString(resourceGroup().id)}'

@description('The email address of the owner of the service')
@minLength(1)
param publisherEmail string

@description('The name of the owner of the service')
@minLength(1)
param publisherName string

@description('The pricing tier of this API Management service')
@allowed([
  'Developer'
  'Standard'
  'Premium'
])
param sku string = 'Developer'

@description('The instance size of this API Management service.')
@allowed([
  1
  2
])
param skuCount int = 1

@description('Location for all resources.')
param location string = resourceGroup().location

@description('Name of the OpenAI API')
param apiName string = 'OpenAI'

@description('URL for OpenAPI YAML definition of the OpenAI API')
param openApiUrl string = 'https://raw.githubusercontent.com/happyadam73/tsql-chatgpt/main/apim/openapi.yaml'


resource apiManagementService  'Microsoft.ApiManagement/service@2021-08-01' = {
  name: apiManagementServiceName
  location: location
  sku: {
    name: sku
    capacity: skuCount
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource openaiApi 'Microsoft.ApiManagement/service/apis@2022-08-01' = {
  parent: apiManagementService 
  name: apiName
  properties: {
    format: 'openapi-link'
    value: openApiUrl
    path: ''
  }
}

resource openaiApiSubscription 'Microsoft.ApiManagement/service/subscriptions@2022-08-01' = {
  parent: apiManagementService
  name: 'OpenAISubscription'
  properties: {
    displayName: 'OpenAI API subscription'
    state: 'active'
    scope: '/apis/${openaiApi.name}'
  }
}
