# outputs.tf -- handy values printed after apply
output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.vm.name
}

output "vm_id" {
  value = azurerm_linux_virtual_machine.vm.id
}

output "custom_role_name" {
  value = azurerm_role_definition.vm_restart.name
}
