# main.tf -- providers first, then all the resources
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100" # allow 3.100.x patches, no major jumps
    }
  }
}

provider "azurerm" {
  features {} # required empty block; enables default Azure behaviors
}

# Resource group: holds every lab resource; destroyed all at once
resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.prefix}"
  location = var.location
  tags     = { CostCenter = "Training" } # the tag value Azure Policy requires
}

# Virtual network + subnet: the private address space the VM lives in
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-${var.prefix}"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "subnet" {
  name                 = "snet-${var.prefix}"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"] # smaller slice for this workload
}

# Network interface: connects the VM to the subnet with a private IP
resource "azurerm_network_interface" "nic" {
  name                = "nic-${var.prefix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet.id
    private_ip_address_allocation = "Dynamic" # Azure assigns the IP
  }
  tags = local.common_tags
}

# The VM itself -- the resource RBAC, Policy, and the budget all govern
resource "azurerm_linux_virtual_machine" "vm" {
  name                  = "vm-${var.prefix}"
  resource_group_name   = azurerm_resource_group.rg.name
  location              = azurerm_resource_group.rg.location
  size                  = "Standard_E2s_v3" # smallest burstable size; cheap ***edit*** switched to E as subscription didn't allow B,D
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.nic.id]
  tags                  = local.common_tags
  admin_ssh_key {
    username   = "azureuser"
    public_key = file(pathexpand("~/.ssh/id_rsa.pub")) # your local public key
  }
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS" # locally redundant managed disk
  }
  source_image_reference { # which OS image to boot
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }
}

# Custom role: LEAST privilege -- can read and restart this VM, nothing else
resource "azurerm_role_definition" "vm_restart" {
  name        = "VM Restart Operator (${var.prefix})"
  scope       = azurerm_linux_virtual_machine.vm.id # role exists only at the VM
  description = "Read and restart this VM only"
  permissions {
    actions = [ # the only operations allowed
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.Compute/virtualMachines/restart/action"
    ]
    not_actions = []
  }
  assignable_scopes = [azurerm_linux_virtual_machine.vm.id]
}

# Role assignment: binds the role to a user, scoped only to this VM
resource "azurerm_role_assignment" "vm_restart" {
  scope              = azurerm_linux_virtual_machine.vm.id
  role_definition_id = azurerm_role_definition.vm_restart.role_definition_resource_id
  principal_id       = var.operator_object_id # who receives the access
}

# Look up the built-in policy that requires a tag on resources
data "azurerm_policy_definition" "require_tag" {
  display_name = "Require a tag on resources"
}

# Assign it to the resource group: untagged resources get denied
resource "azurerm_resource_group_policy_assignment" "tags" {
  name                 = "require-costcenter"
  resource_group_id    = azurerm_resource_group.rg.id
  policy_definition_id = data.azurerm_policy_definition.require_tag.id
  parameters           = jsonencode({ tagName = { value = "CostCenter" } }) # tag to enforce
}

# Budget + alert: WARNS (does not enforce) when spend crosses the threshold
resource "azurerm_consumption_budget_resource_group" "budget" {
  name              = "budget-${var.prefix}"
  resource_group_id = azurerm_resource_group.rg.id
  amount            = 10 # USD per month for this resource group
  time_grain        = "Monthly"
  time_period { start_date = "2026-07-01T00:00:00Z" } # 1st of a month, UTC
  notification {
    enabled        = true
    threshold      = 80 # email at 80% of the $10 budget
    operator       = "GreaterThanOrEqualTo"
    contact_emails = [var.alert_email]
  }
}
