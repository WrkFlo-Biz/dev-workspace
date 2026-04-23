// Bicep describing the existing dev-workspace-vm.
// This file DOCUMENTS the current resource; we do not redeploy from it today.
// If you ever need to rebuild the VM, `az deployment group create -g DEV-WS-WESTUS2
// -f infra/dev-workspace-vm.bicep` will reproduce the shape (SSH key left as param).

targetScope = 'resourceGroup'

@description('Admin username on the VM')
param adminUsername string = 'moses'

@description('SSH public key contents for the admin user')
@secure()
param adminSshPublicKey string

@description('Azure region')
param location string = 'westus2'

@description('VM size. Current: Standard_D2s_v5 (2 vCPU / 8 GB).')
param vmSize string = 'Standard_D2s_v5'

@description('Hostname / resource name')
param vmName string = 'dev-workspace-vm'

var nicName    = '${vmName}-nic'
var pipName    = '${vmName}-pip'
var nsgName    = '${vmName}-nsg'
var vnetName   = '${vmName}-vnet'
var subnetName = 'default'

resource vnet 'Microsoft.Network/virtualNetworks@2024-03-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.0.0.0/16' ] }
    subnets: [
      {
        name: subnetName
        properties: { addressPrefix: '10.0.0.0/24' }
      }
    ]
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-03-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        // Public SSH open today. Once Tailscale is fully adopted across devices,
        // this can be locked down to specific source IPs or removed entirely
        // in favor of Tailscale SSH.
        name: 'AllowSSH'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2024-03-01' = {
  name: pipName
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-03-01' = {
  name: nicName
  location: location
  properties: {
    networkSecurityGroup: { id: nsg.id }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.0.0.4'
          subnet: { id: '${vnet.id}/subnets/${subnetName}' }
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [ { id: nic.id } ]
    }
  }
}

output publicIp string = pip.properties.ipAddress
output vmId string = vm.id
