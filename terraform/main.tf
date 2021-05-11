terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=2.46.0"
    }
  }
}

provider "azurerm" {
  features {}
  skip_provider_registration = true
}

resource "azurerm_resource_group" "rg-aulainfra" {
  name     = "example-resources"
  location = "eastus"
}

resource "azurerm_virtual_network" "vnet-test" {
  name                = "Virtual-Network-test"
  location            = azurerm_resource_group.rg-aulainfra.location
  resource_group_name = azurerm_resource_group.rg-aulainfra.name
  address_space       = ["10.0.0.0/16"]

  tags = {
    enviroment = "Production"
  }
}

resource "azurerm_subnet" "subnet-aulainfra" {
  name                 = "subnet1"
  resource_group_name  = azurerm_resource_group.rg-aulainfra.name
  virtual_network_name = azurerm_virtual_network.vnet-test.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "public-ip-aula" {
  name                = "public-aulainfra"
  resource_group_name = azurerm_resource_group.rg-aulainfra.name
  location            = azurerm_resource_group.rg-aulainfra.location
  allocation_method   = "Static"
}

resource "azurerm_network_security_group" "security-net" {
  name                = "security-aulainfra"
  resource_group_name = azurerm_resource_group.rg-aulainfra.name
  location            = azurerm_resource_group.rg-aulainfra.location

  security_rule {
    name                       = "mysql"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3306"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "SSH"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "board-net" {
  name                = "network-interface-aulainfra"
  location            = azurerm_resource_group.rg-aulainfra.location
  resource_group_name = azurerm_resource_group.rg-aulainfra.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.subnet-aulainfra.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.public-ip-aula.id
  }
}

resource "azurerm_network_interface_security_group_association" "vnet-security" {
  network_interface_id      = azurerm_network_interface.board-net.id
  network_security_group_id = azurerm_network_security_group.security-net.id
}

data "azurerm_public_ip" "ip_aula_data_db" {
  name                = azurerm_public_ip.public-ip-aula.name
  resource_group_name = azurerm_resource_group.rg-aulainfra.name
}

resource "azurerm_linux_virtual_machine" "vm-test" {
  name                            = "vm-aulainfra"
  location                        = azurerm_resource_group.rg-aulainfra.location
  resource_group_name             = azurerm_resource_group.rg-aulainfra.name
  size                            = "Standard_F2"
  admin_username                  = "adminuser"
  admin_password                  = "aulainfra@02"
  disable_password_authentication = false
  network_interface_ids = [
    azurerm_network_interface.board-net.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "16.04-LTS"
    version   = "latest"
  }
}

output "public-ip" {
  value = azurerm_public_ip.public-ip-aula.ip_address
}

resource "time_sleep" "wait_30_seconds_db" {
  depends_on = [azurerm_linux_virtual_machine.vm-test]
  create_duration = "30s"
}

resource "null_resource" "upload_db" {
  provisioner "file" {
    connection {
      type     = "ssh"
      user     = "adminuser"
      password = "aulainfra@02"
      host     = data.azurerm_public_ip.ip_aula_data_db.ip_address
    }
    source      = "config"
    destination = "/home/azureuser"
  }

  depends_on = [time_sleep.wait_30_seconds_db]
}

resource "null_resource" "deploy_db" {
  triggers = {
    order = null_resource.upload_db.id
  }
  provisioner "remote-exec" {
    connection {
      type     = "ssh"
      user     = "adminuser"
      password = "aulainfra@02"
      host     = data.azurerm_public_ip.ip_aula_data_db.ip_address
    }
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y mysql-server-5.7",
      "sudo mysql < /home/azureuser/config/user.sql",
      "sudo cp -f /home/azureuser/config/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf",
      "sudo service mysql restart",
      "sleep 20",
    ]
  }
}
