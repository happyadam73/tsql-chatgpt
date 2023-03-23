@description('The name of the SQL logical server.')
param serverName string = uniqueString('sql', resourceGroup().id)

@description('The name of the SQL Database.')
param sqlDBName string = 'AdventureWorksLT'

@description('Location for all resources.')
param location string = resourceGroup().location

@description('The administrator username of the SQL logical server.')
param administratorLogin string

@description('The administrator password of the SQL logical server.')
@secure()
param administratorLoginPassword string

@description('Sample SQL Database')
@allowed([
  'AdventureWorksLT'
  'WideWorldImportersFull'
  'WideWorldImportersStd'
])
param sampleDatabase string = 'AdventureWorksLT'

@description('Allow Azure services to access server.')
param allowAzureIPs bool = true

@description('Client IP Address')
param clientIpAddress string = ''

resource sqlServer 'Microsoft.Sql/servers@2022-05-01-preview' = {
  name: serverName
  location: location
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
  }
}

resource allowAzureServicesFirewallRule 'Microsoft.Sql/servers/firewallRules@2022-05-01-preview' = if (allowAzureIPs) {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    endIpAddress: '0.0.0.0'
    startIpAddress: '0.0.0.0'
  }
}

resource allowClientIpFirewallRule 'Microsoft.Sql/servers/firewallRules@2022-05-01-preview' = if (length(clientIpAddress) > 0) {
  parent: sqlServer
  name: 'AllowClientIp'
  properties: {
    endIpAddress: clientIpAddress
    startIpAddress: clientIpAddress
  }
}

resource sqlDB 'Microsoft.Sql/servers/databases@2022-05-01-preview' = {
  parent: sqlServer
  name: sqlDBName
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    sampleName: sampleDatabase
  }  
}
