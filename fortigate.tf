variable instance_count {
  description = "Defines the number of VMs to be provisioned."
  default     = "2"
}

variable prefix {
  description = "Defines the number of VMs to be provisioned."
  default     = "FGCAC"
}

resource "random_string" "password" {
  length = 16
  special = false
  min_lower = 2
  min_upper = 2
  min_numeric = 2

  #override_special = "/@\"
}


data "azurerm_resource_group" "fgrg" {
  name = "FGCAC-PROD-RG"
}

data "azurerm_resource_group" "netrg" {
  name = "Network-PROD-RG"
}


data "azurerm_virtual_network" "vnet" {
  name                = "MGMT-CAC-VNET"
	resource_group_name = "Network-PROD-RG"
}

data "azurerm_subnet" "subnet-front" {
  name                 = "MGMT-CAC-FRONT"
	virtual_network_name = "${data.azurerm_virtual_network.vnet.name}"
	resource_group_name  = "${data.azurerm_resource_group.netrg.name}"
}
data "azurerm_subnet" "subnet-back" {
  name                 = "MGMT-CAC-BACK"
	virtual_network_name = "${data.azurerm_virtual_network.vnet.name}"
	resource_group_name  = "${data.azurerm_resource_group.netrg.name}"
}



data "azurerm_public_ip" "pip" {
  name                = "${var.prefix}-${count.index+1}-pip"
  resource_group_name = "${data.azurerm_resource_group.fgrg.name}"
  count               = "${var.instance_count}"
}

resource "azurerm_network_interface" "vnic-front" {
  count               = "${var.instance_count}"
  name                = "${var.prefix}-VM${count.index+1}-front-nic"
  location            = "${data.azurerm_resource_group.fgrg.location}"
  resource_group_name = "${data.azurerm_resource_group.fgrg.name}"

  ip_configuration {
    name                          = "${var.prefix}-VM${count.index+1}-front-nic"
    subnet_id                     = "${data.azurerm_subnet.subnet-front.id}"
    private_ip_address_allocation = "dynamic"
  }
}

resource "azurerm_network_interface" "vnic-back" {
  count               = "${var.instance_count}"
  name                = "${var.prefix}-VM${count.index+1}-back-nic"
  location            = "${data.azurerm_resource_group.fgrg.location}"
  resource_group_name = "${data.azurerm_resource_group.fgrg.name}"

  ip_configuration {
    name                          = "${var.prefix}-VM${count.index+1}-back-nic"
    subnet_id                     = "${data.azurerm_subnet.subnet-back.id}"
    private_ip_address_allocation = "dynamic"
  }
}

resource "azurerm_availability_set" "avset" {
  name                         = "${var.prefix}-avset"
  location                     = "${data.azurerm_resource_group.fgrg.location}"
  resource_group_name          = "${data.azurerm_resource_group.fgrg.name}"
  platform_fault_domain_count  = 2
  platform_update_domain_count = 2
  managed                      = true
}


resource "azurerm_virtual_machine" "vm" {
  count                         = "${var.instance_count}"
  name                          = "${var.prefix}-VM${count.index+1}"
  location                      = "${data.azurerm_resource_group.fgrg.location}"
  availability_set_id           = "${azurerm_availability_set.avset.id}"
  resource_group_name           = "${data.azurerm_resource_group.fgrg.name}"
  primary_network_interface_id  = "${element(azurerm_network_interface.vnic-front.*.id, count.index)}"
  network_interface_ids         = ["${element(azurerm_network_interface.vnic-front.*.id, count.index)}", "${element(azurerm_network_interface.vnic-back.*.id, count.index)}"]
  vm_size                       = "Standard_F1"
  depends_on                    = ["azurerm_availability_set.avset"]

  # Uncomment this line to delete the OS disk automatically when deleting the VM
  delete_os_disk_on_termination = true

  storage_image_reference {
    publisher = "fortinet"
    offer     = "fortinet_fortigate-vm_v5"
    sku       = "fortinet_fg-vm"
    version   = "6.0.4"
  }

  storage_os_disk {
    name              = "${var.prefix}-VM${count.index+1}-osdisk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "StandardSSD_LRS"
  }

  os_profile {
    computer_name  = "${var.prefix}-VM${count.index+1}"
    admin_username = "fgroot"
		admin_password = "${random_string.password.result}"
  }
  os_profile_linux_config {
    disable_password_authentication = "false"
  }

  plan {
    name      = "fortinet_fg-vm"
    publisher = "fortinet"
    product     = "fortinet_fortigate-vm_v5"

  }
}

resource "azurerm_lb" "lb-front" {
  name                = "${var.prefix}-FRONT-lb"
  location            = "${data.azurerm_resource_group.fgrg.location}"
  resource_group_name = "${data.azurerm_resource_group.fgrg.name}"
	sku									= "Standard"
  depends_on            = ["azurerm_virtual_machine.vm"]
	# Unfortunately you can't dynamically assign the public IP addresses

  frontend_ip_configuration {
    name                 = "${var.prefix}-VM${count.index+1}"
    public_ip_address_id = "${element(data.azurerm_public_ip.pip.*.id, count.index)}"
  }

  frontend_ip_configuration {
    name                 = "${var.prefix}-VM${count.index+2}"
    public_ip_address_id = "${element(data.azurerm_public_ip.pip.*.id, count.index+1)}"
  }
  
  
}

resource "azurerm_lb_nat_rule" "test" {
	count													 = "${var.instance_count}"
  resource_group_name 					 = "${data.azurerm_resource_group.fgrg.name}"
  loadbalancer_id                = "${azurerm_lb.lb-front.id}"
  name                           = "${var.prefix}-VM${count.index+1}"
  protocol                       = "TCP"
  frontend_port                  = 443
  backend_port                   = 8443
  frontend_ip_configuration_name = "${var.prefix}-VM${count.index+1}"
  enable_floating_ip             = "true"
  
}



resource "azurerm_lb" "lb-back" {
  name                = "${var.prefix}-BACK-lb"
  location            = "${data.azurerm_resource_group.fgrg.location}"
  resource_group_name = "${data.azurerm_resource_group.fgrg.name}"
	sku									= "Standard"
  depends_on            = ["azurerm_virtual_machine.vm"]

	frontend_ip_configuration
	{
		name								= "${var.prefix}-BACK-ip"
		subnet_id						=	"${data.azurerm_subnet.subnet-back.id}"
	}
}








output "password" {
  value = "${random_string.password.result}"
}
